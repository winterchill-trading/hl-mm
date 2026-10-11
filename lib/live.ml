open! Core
open! Async
open Hl_protocol

let now_ms () = Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000

module Instrument = struct
  type t =
    { coin : Coin.t
    ; asset : Asset.t
    ; tick : Price.t
    ; lot : Size.t
    ; mid : Price.t
    }
  [@@deriving sexp_of]

  let pow10 n = Int.pow 10 n

  let tick_of_mid ~sz_decimals mid =
    let integer_part = Price.to_units mid / Price.units_per_one in
    if integer_part >= 10_000
    then Price.one
    else (
      (* exponent of the leading digit *)
      let leading =
        if integer_part > 0
        then String.length (Int.to_string integer_part) - 1
        else Float.iround_down_exn (Float.log10 (Price.to_float mid))
      in
      let max_decimals = Int.max 0 (6 - sz_decimals) in
      let exponent = Int.max (leading - 4) (-max_decimals) |> Int.max (-Price.decimals) in
      if exponent >= 0
      then Price.of_int (pow10 exponent)
      else Price.of_units (pow10 (Price.decimals + exponent)))
  ;;

  let fetch client coin =
    let open Deferred.Or_error.Let_syntax in
    let%bind meta = Hl_client.Info.meta client
    and book = Hl_client.Info.l2_book client coin in
    let%bind asset, asset_meta =
      match Meta.asset_of_coin meta coin, Meta.find meta coin with
      | Some asset, Some asset_meta -> return (asset, asset_meta)
      | _ -> Deferred.Or_error.error_s [%message "unknown coin" (coin : Coin.t)]
    in
    let%map mid =
      match L2_book.best_bid book, L2_book.best_ask book with
      | Some bid, Some ask -> return (Price.div_int Price.(bid.px + ask.px) 2)
      | _ -> Deferred.Or_error.error_s [%message "empty book" (coin : Coin.t)]
    in
    let sz_decimals = asset_meta.sz_decimals in
    { coin
    ; asset
    ; tick = tick_of_mid ~sz_decimals mid
    ; lot = Size.of_units (pow10 (Size.decimals - sz_decimals))
    ; mid
    }
  ;;
end

module Report = struct
  type t =
    { elapsed : Time_ns.Span.t
    ; fills : int
    ; maker_fills : int
    ; volume : Usd.t
    ; realized_pnl : Usd.t
    ; unrealized_pnl : Usd.t
    ; fees : Usd.t
    ; total_pnl : Usd.t
    ; position : Size.t
    ; mid : Price.t option
    ; account_value : Usd.t option
    ; plans : int
    ; orders_placed : int
    ; orders_rejected : int
    ; rejections : (string * int) list
    ; orders_cancelled : int
    ; ws_reconnects : int
    ; mode : Strategy.Mode.t
    }
  [@@deriving sexp_of]

  let usd x = Usd.to_string (Usd.round_nearest x ~decimals:4)

  let to_string_hum t =
    let opt f = Option.value_map ~default:"-" ~f in
    let lines =
      [ sprintf "elapsed          %.1fs" (Time_ns.Span.to_sec t.elapsed)
      ; sprintf "fills            %d (%d maker)" t.fills t.maker_fills
      ; sprintf "volume           %s USD" (usd t.volume)
      ; sprintf "realized pnl     %s USD" (usd t.realized_pnl)
      ; sprintf "unrealized pnl   %s USD" (usd t.unrealized_pnl)
      ; sprintf "fees             %s USD" (usd t.fees)
      ; sprintf "total pnl        %s USD" (usd t.total_pnl)
      ; sprintf "final position   %s" (Size.to_string t.position)
      ; sprintf "last mid         %s" (opt Price.to_string t.mid)
      ; sprintf "account value    %s USD" (opt usd t.account_value)
      ; sprintf "plans            %d" t.plans
      ; sprintf
          "orders           %d placed, %d rejected, %d cancelled"
          t.orders_placed
          t.orders_rejected
          t.orders_cancelled
      ]
      @ List.map t.rejections ~f:(fun (msg, n) -> sprintf "  rejected %4d x %s" n msg)
      @ [ sprintf "ws reconnects    %d" t.ws_reconnects
        ; sprintf "mode             %s" (Sexp.to_string (Strategy.Mode.sexp_of_t t.mode))
        ]
    in
    String.concat ~sep:"\n" lines
  ;;
end

module Config = struct
  type t =
    { client : Hl_client.Config.t
    ; params : Params.t
    ; summary_interval : Time_ns.Span.t
    }
  [@@deriving sexp_of]
end

type t =
  { config : Config.t
  ; ws : Hl_client.Ws.t
  ; sequencer : unit Throttle.Sequencer.t
  ; started_at : Time_ns.t
  ; started_at_ms : int
  ; seen_tids : Int.Hash_set.t
  ; timers_stop : unit Ivar.t
  ; stopped : Report.t Ivar.t
  ; mutable strategy : Strategy.t
  ; mutable clearinghouse : Clearinghouse_state.t option
  ; mutable stopping : bool
  ; mutable step_queued : bool
  ; mutable sync_queued : bool
  ; mutable volume : Usd.t
  ; mutable maker_fills : int
  ; mutable plans : int
  ; mutable orders_placed : int
  ; mutable orders_rejected : int
  ; mutable rejections : int String.Map.t
  ; mutable orders_cancelled : int
  ; mutable ws_reconnects : int
  }

let params t = t.config.params
let strategy t = t.strategy
let usd = Report.usd

let report t =
  let inventory = Strategy.inventory t.strategy in
  let mid = Market_state.mid (Strategy.market t.strategy) in
  let unrealized_pnl =
    Option.value_map mid ~default:Usd.zero ~f:(fun mark ->
      Inventory.unrealized_pnl inventory ~mark)
  in
  let realized_pnl = Inventory.realized_pnl inventory in
  let fees = Inventory.fees inventory in
  { Report.elapsed = Time_ns.diff (Time_ns.now ()) t.started_at
  ; fills = Hash_set.length t.seen_tids
  ; maker_fills = t.maker_fills
  ; volume = t.volume
  ; realized_pnl
  ; unrealized_pnl
  ; fees
  ; total_pnl = Usd.(realized_pnl + unrealized_pnl - fees)
  ; position = Inventory.position inventory
  ; mid
  ; account_value =
      Option.map t.clearinghouse ~f:(fun (c : Clearinghouse_state.t) ->
        c.margin_summary.account_value)
  ; plans = t.plans
  ; orders_placed = t.orders_placed
  ; orders_rejected = t.orders_rejected
  ; rejections =
      Map.to_alist t.rejections
      |> List.sort ~compare:(fun (_, a) (_, b) -> Int.descending a b)
  ; orders_cancelled = t.orders_cancelled
  ; ws_reconnects = t.ws_reconnects
  ; mode = Strategy.mode t.strategy
  }
;;

(* Runs [f] on the sequencer, logging (not raising) its failures. *)
let enqueue t ~name f =
  Throttle.enqueue t.sequencer (fun () ->
    match%map Monitor.try_with ~extract_exn:true f with
    | Ok () -> ()
    | Error exn -> Log.Global.error_s [%message "live loop job failed" name (exn : exn)])
;;

(* {2 Snapshots} *)

let sync t =
  let client = t.config.client in
  let%map open_orders = Hl_client.Info.open_orders client
  and clearinghouse = Hl_client.Info.clearinghouse_state client in
  (match clearinghouse with
   | Ok state ->
     t.clearinghouse <- Some state;
     t.strategy <- Strategy.on_clearinghouse t.strategy state
   | Error error -> Log.Global.error_s [%message "clearinghouseState" (error : Error.t)]);
  match open_orders with
  | Ok orders -> t.strategy <- Strategy.on_open_orders t.strategy orders
  | Error error -> Log.Global.error_s [%message "openOrders" (error : Error.t)]
;;

(* {2 Plan execution} *)

let reject t msg =
  t.orders_rejected <- t.orders_rejected + 1;
  t.rejections <- Map.update t.rejections msg ~f:(fun n -> 1 + Option.value n ~default:0)
;;

let describe_order (o : Order_request.t) =
  sprintf
    "%s %s@%s%s"
    (Side.to_wire (Order_request.side o))
    (Size.to_string o.sz)
    (Price.to_string o.limit_px)
    (if o.reduce_only then " (reduce-only)" else "")
;;

let send_cancels t oids =
  let params = params t in
  let cancels =
    List.map oids ~f:(fun oid -> { Cancel_request.asset = params.asset; oid })
  in
  match%map Hl_client.Exchange.cancel t.config.client cancels with
  | Ok (Ok (Cancel statuses)) ->
    List.iter statuses ~f:(function
      | Success -> t.orders_cancelled <- t.orders_cancelled + 1
      | Error msg -> Log.Global.debug "cancel failed: %s" msg)
  | Ok response -> Log.Global.error_s [%message "cancel" (response : Exchange_response.t)]
  | Error error -> Log.Global.error_s [%message "cancel" (error : Error.t)]
;;

let send_places t orders =
  match%map Hl_client.Exchange.place_orders t.config.client orders with
  | Ok (Ok (Order statuses)) ->
    List.iter2_exn orders statuses ~f:(fun order status ->
      match status with
      | Resting _ -> t.orders_placed <- t.orders_placed + 1
      | Filled { total_sz; avg_px; _ } ->
        t.orders_placed <- t.orders_placed + 1;
        Log.Global.info
          "order %s filled immediately: %s@%s"
          (describe_order order)
          (Size.to_string total_sz)
          (Price.to_string avg_px)
      | Error msg ->
        reject t msg;
        Log.Global.info "order %s rejected: %s" (describe_order order) msg
      | Waiting_for_fill | Waiting_for_trigger -> ())
  | Ok response -> Log.Global.error_s [%message "order" (response : Exchange_response.t)]
  | Error error -> Log.Global.error_s [%message "order" (error : Error.t)]
;;

let execute t plan =
  let cancels =
    List.filter_map plan ~f:(function
      | Action.Cancel oid -> Some oid
      | Keep _ | Place _ -> None)
  in
  let places =
    List.filter_map plan ~f:(function
      | Action.Place order -> Some order
      | Keep _ | Cancel _ -> None)
  in
  let keeps = List.length plan - List.length cancels - List.length places in
  t.plans <- t.plans + 1;
  Log.Global.info
    "plan #%d gen %d: cancel %d, keep %d, place [%s]"
    t.plans
    (Strategy.generation t.strategy)
    (List.length cancels)
    keeps
    (String.concat ~sep:" " (List.map places ~f:describe_order));
  let%bind () = if List.is_empty cancels then return () else send_cancels t cancels in
  if List.is_empty places then return () else send_places t places
;;

(* {2 Steps} *)

let tick_and_execute t =
  if t.stopping
  then return ()
  else (
    let mode_before = Strategy.mode t.strategy in
    let strategy, plan = Strategy.tick t.strategy ~now:(now_ms ()) in
    t.strategy <- strategy;
    let mode = Strategy.mode strategy in
    if not (Strategy.Mode.equal mode mode_before)
    then
      Log.Global.info_s
        [%message
          "mode" ~from:(mode_before : Strategy.Mode.t) ~to_:(mode : Strategy.Mode.t)];
    if List.is_empty plan
    then return ()
    else (
      let%bind () = execute t plan in
      sync t))
;;

(* Coalesces requests: at most one tick waits on the sequencer at a time. *)
let step t =
  if (not t.stopping) && not t.step_queued
  then (
    t.step_queued <- true;
    don't_wait_for
      (enqueue t ~name:"tick" (fun () ->
         t.step_queued <- false;
         tick_and_execute t)))
;;

let request_sync t =
  if (not t.stopping) && not t.sync_queued
  then (
    t.sync_queued <- true;
    don't_wait_for
      (enqueue t ~name:"sync" (fun () ->
         t.sync_queued <- false;
         if t.stopping then return () else sync t));
    step t)
;;

(* {2 Websocket} *)

let on_fill t (fill : User_fill.t) =
  if Coin.equal fill.coin (params t).coin && not (Hash_set.mem t.seen_tids fill.tid)
  then (
    Hash_set.add t.seen_tids fill.tid;
    t.volume <- Usd.(t.volume + Fx.notional fill.px fill.sz);
    if not fill.crossed then t.maker_fills <- t.maker_fills + 1;
    t.strategy <- Strategy.on_fill t.strategy fill;
    let r = report t in
    Log.Global.info
      "fill %s %s@%s %s fee %s | pos %s realized %s unrealized %s fees %s pnl %s"
      (Side.to_wire fill.side)
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (if fill.crossed then "taker" else "maker")
      (Usd.to_string fill.fee)
      (Size.to_string r.position)
      (usd r.realized_pnl)
      (usd r.unrealized_pnl)
      (usd r.fees)
      (usd r.total_pnl);
    step t)
;;

let on_message t (message : Ws_message.t) =
  match message with
  | L2_book book ->
    t.strategy <- Strategy.on_book t.strategy book;
    step t
  | User_fills { is_snapshot; fills; user = _ } ->
    (* A snapshot (sent on every (re)subscription) replays history; only fills since start
       count, and [seen_tids] drops the ones already applied. *)
    List.iter fills ~f:(fun (fill : User_fill.t) ->
      if (not is_snapshot) || fill.time >= t.started_at_ms then on_fill t fill)
  | Order_updates updates ->
    List.iter updates ~f:(fun (u : Order_update.t) ->
      Log.Global.debug_s [%message "order update" (u : Order_update.t)]);
    (* The strategy only takes full snapshots; an order that left the book (fill, cancel,
       rejection) is picked up by the next poll, requested now. *)
    if List.exists updates ~f:(fun u -> not (Order_update.Status.equal u.status Open))
    then request_sync t
  | Error msg -> Log.Global.error "websocket error: %s" msg
  | Subscription_response _ | Trades _ | All_mids _ | Pong | Unknown _ -> ()
;;

(* {2 Summary} *)

let log_summary t =
  let r = report t in
  let quotes side =
    Strategy.open_orders t.strategy
    |> List.filter ~f:(fun (o : Open_order.t) -> Side.equal o.side side)
    |> List.sort ~compare:(fun (a : Open_order.t) b ->
      match side with
      | Buy -> Price.descending a.limit_px b.limit_px
      | Sell -> Price.ascending a.limit_px b.limit_px)
    |> List.map ~f:(fun (o : Open_order.t) ->
      sprintf "%s@%s" (Size.to_string o.sz) (Price.to_string o.limit_px))
    |> String.concat ~sep:" "
  in
  let market = Strategy.market t.strategy in
  let opt = Option.value_map ~default:"-" ~f:Price.to_string in
  Log.Global.info
    "summary: mode %s | mid %s (bid %s ask %s, vol %.2fbps) | pos %s entry %s | fills %d \
     volume %s | realized %s unrealized %s fees %s pnl %s | bids [%s] asks [%s]"
    (Sexp.to_string (Strategy.Mode.sexp_of_t r.mode))
    (opt r.mid)
    (opt (Market_state.best_bid market))
    (opt (Market_state.best_ask market))
    (Market_state.vol_bps market)
    (Size.to_string r.position)
    (opt (Inventory.avg_entry (Strategy.inventory t.strategy)))
    r.fills
    (usd r.volume)
    (usd r.realized_pnl)
    (usd r.unrealized_pnl)
    (usd r.fees)
    (usd r.total_pnl)
    (quotes Buy)
    (quotes Sell)
;;

(* {2 Lifecycle} *)

let start (config : Config.t) =
  match config.client.address with
  | None -> Deferred.Or_error.error_string "Live.start: the client config has no address"
  | Some address ->
    let params = config.params in
    let cell = Set_once.create () in
    let on_reconnect () =
      match Set_once.get cell with
      | None -> ()
      | Some t ->
        t.ws_reconnects <- t.ws_reconnects + 1;
        Log.Global.info "websocket reconnected; resyncing open orders and position";
        request_sync t
    in
    let%bind.Deferred.Or_error ws = Hl_client.Ws.connect ~on_reconnect config.client in
    let started_at = Time_ns.now () in
    let t =
      { config
      ; ws
      ; sequencer = Throttle.Sequencer.create ~continue_on_error:true ()
      ; started_at
      ; started_at_ms = Time_ns.to_int_ns_since_epoch started_at / 1_000_000
      ; seen_tids = Int.Hash_set.create ()
      ; timers_stop = Ivar.create ()
      ; stopped = Ivar.create ()
      ; strategy = Strategy.create params
      ; clearinghouse = None
      ; stopping = false
      ; step_queued = false
      ; sync_queued = false
      ; volume = Usd.zero
      ; maker_fills = 0
      ; plans = 0
      ; orders_placed = 0
      ; orders_rejected = 0
      ; rejections = String.Map.empty
      ; orders_cancelled = 0
      ; ws_reconnects = 0
      }
    in
    Set_once.set_exn cell t;
    Log.Global.info_s
      [%message
        "starting"
          (address : Address.t)
          ~base_url:(Uri.to_string config.client.base_url)
          ~ws_url:(Uri.to_string config.client.ws_url)
          (params : Params.t)];
    (* The first snapshot must be in before quoting, so that resting orders from an
       earlier run are reconciled (cancelled) rather than duplicated. *)
    let%bind () = sync t in
    don't_wait_for
      (Pipe.iter_without_pushback (Hl_client.Ws.messages ws) ~f:(on_message t));
    let%bind () =
      Deferred.List.iter
        ~how:`Sequential
        [ Subscription.L2_book { coin = params.coin }
        ; Order_updates { user = address }
        ; User_fills { user = address }
        ]
        ~f:(Hl_client.Ws.subscribe ws)
    in
    let stop = Ivar.read t.timers_stop in
    Clock_ns.every
      ~stop
      ~continue_on_error:true
      (Time_ns.Span.of_int_ms params.requote_interval_ms)
      (fun () -> request_sync t);
    Clock_ns.every
      ~start:(Clock_ns.after config.summary_interval)
      ~stop
      ~continue_on_error:true
      config.summary_interval
      (fun () -> log_summary t);
    return (Ok t)
;;

let cancel_all t =
  let params = params t in
  let rec attempt n =
    match%bind Hl_client.Info.open_orders t.config.client with
    | Error error ->
      Log.Global.error_s [%message "openOrders at shutdown" (error : Error.t)];
      return ()
    | Ok open_orders ->
      let ours =
        List.filter open_orders ~f:(fun (o : Open_order.t) ->
          Coin.equal o.coin params.coin)
      in
      t.strategy <- Strategy.on_open_orders t.strategy open_orders;
      if List.is_empty ours
      then return ()
      else if n = 0
      then (
        Log.Global.error "%d orders still resting after cancel-all" (List.length ours);
        return ())
      else (
        Log.Global.info "shutdown: cancelling %d resting orders" (List.length ours);
        let%bind () = send_cancels t (List.map ours ~f:(fun o -> o.oid)) in
        attempt (n - 1))
  in
  attempt 3
;;

let stop t =
  if t.stopping
  then Ivar.read t.stopped
  else (
    t.stopping <- true;
    Ivar.fill_if_empty t.timers_stop ();
    Log.Global.info "stopping";
    let%bind () = enqueue t ~name:"shutdown" (fun () -> cancel_all t) in
    let%bind () = sync t in
    (* Let fills for orders that traded during the cancel arrive. *)
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 250) in
    let%bind () = Hl_client.Ws.close t.ws in
    let report = report t in
    Ivar.fill_if_empty t.stopped report;
    return report)
;;

let run config ~stop:stop_signal =
  let%bind.Deferred.Or_error t = start config in
  let%bind () = stop_signal in
  let%map report = stop t in
  Ok report
;;
