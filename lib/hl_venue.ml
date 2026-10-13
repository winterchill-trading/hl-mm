open! Core
open! Async
open Hl_protocol
module Neutral = Exchange_core
module Fill = Mm_core.Fill
module Neutral_update = Mm_core.Order_update

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

module Convert = struct
  let ns_of_ms ms = ms * 1_000_000
  let level ({ px; sz; n } : L2_book.Level.t) : Neutral.L2.Level.t = { px; sz; n }

  let l2 (book : L2_book.t) : Neutral.L2.t =
    { symbol = book.coin
    ; time = ns_of_ms book.time
    ; bids = List.map book.bids ~f:level
    ; asks = List.map book.asks ~f:level
    }
  ;;

  let fill (f : User_fill.t) : Fill.t =
    { trade_id = Neutral.Trade_id.of_int f.tid
    ; order_id = f.oid
    ; client_order_id = f.cloid
    ; symbol = f.coin
    ; side = f.side
    ; px = f.px
    ; size = f.sz
    ; fee = f.fee
    ; is_maker = not f.crossed
    ; time = ns_of_ms f.time
    ; closed_pnl = Some f.closed_pnl
    }
  ;;

  let open_order (o : Open_order.t) : Neutral.Open_order.t =
    { symbol = o.coin
    ; side = o.side
    ; px = o.limit_px
    ; size = o.sz
    ; orig_size = o.orig_sz
    ; order_id = o.oid
    ; client_order_id = o.cloid
    ; timestamp = ns_of_ms o.timestamp
    }
  ;;

  let order_update ({ order = o; status; status_timestamp } : Order_update.t)
    : Neutral_update.t
    =
    let filled =
      match o.orig_sz with
      | Some orig -> Size.(max zero (orig - o.sz))
      | None -> Size.zero
    in
    let status : Neutral_update.Status.t =
      match status with
      | Open | Triggered -> if Size.is_zero filled then New else Partially_filled
      | Filled -> Filled
      | Rejected -> Rejected
      | Canceled | Margin_canceled -> Cancelled
      | Other s ->
        (* e.g. "badAloPxRejected", "selfTradeCanceled", "reduceOnlyCanceled" *)
        if String.is_suffix s ~suffix:"Rejected" then Rejected else Cancelled
    in
    { order_id = o.oid
    ; client_order_id = o.cloid
    ; symbol = o.coin
    ; side = o.side
    ; px = o.limit_px
    ; status
    ; filled
    ; remaining = (if Neutral_update.Status.is_final status then Size.zero else o.sz)
    ; time = ns_of_ms status_timestamp
    }
  ;;

  let account address (c : Clearinghouse_state.t) : Neutral.Account_view.t =
    let positions =
      List.map
        c.positions
        ~f:(fun (p : Clearinghouse_state.Position.t) : Neutral.Position_view.t ->
          { symbol = p.coin
          ; size = p.szi
          ; entry_px = Option.value p.entry_px ~default:Price.zero
          ; notional = p.position_value
          ; unrealized_pnl = p.unrealized_pnl
          ; realized_pnl = Usd.zero
          ; cum_funding = Usd.zero
          ; liquidation_px = p.liquidation_px
          ; leverage = Clearinghouse_state.Leverage.value p.leverage
          ; max_leverage = p.max_leverage
          ; margin_used = p.margin_used
          })
      |> List.sort ~compare:(fun (a : Neutral.Position_view.t) b ->
        Neutral.Symbol.compare a.symbol b.symbol)
    in
    let equity = c.margin_summary.account_value in
    let unrealized =
      Usd.sum
        (List.map positions ~f:(fun (p : Neutral.Position_view.t) -> p.unrealized_pnl))
    in
    { account = address
    ; balance = Usd.(equity - unrealized)
    ; equity
    ; total_notional = c.margin_summary.total_ntl_pos
    ; margin_used = c.margin_summary.total_margin_used
    ; maintenance_margin = c.cross_maintenance_margin_used
    ; available = c.withdrawable
    ; positions
    ; time = ns_of_ms c.time
    }
  ;;

  (* Hyperliquid appends " asset=N" to many messages. *)
  let strip_asset msg =
    match String.substr_index msg ~pattern:" asset=" with
    | Some i -> String.prefix msg i
    | None -> msg
  ;;

  let parse_bbo msg =
    (* "... bbo was 99941@99950." *)
    let price s = if String.equal s "none" then None else Price.of_string_opt s in
    match String.substr_index msg ~pattern:"bbo was " with
    | None -> None, None
    | Some i ->
      let rest = String.drop_prefix msg (i + String.length "bbo was ") in
      let rest = String.chop_suffix_if_exists rest ~suffix:"." in
      (match String.lsplit2 rest ~on:'@' with
       | Some (bid, ask) -> price bid, price ask
       | None -> None, None)
  ;;

  let reject_reason msg : Neutral.Reject_reason.t =
    let m = strip_asset msg in
    let starts prefix = String.is_prefix m ~prefix in
    if starts "Post only order would have immediately matched"
    then (
      let best_bid, best_ask = parse_bbo m in
      Post_only_would_cross { best_bid; best_ask })
    else if starts "Order has invalid size"
    then Invalid_size
    else if starts "Price must be divisible by tick size"
            || starts "Order has invalid price"
    then Invalid_price
    else if starts "Duplicate cloid"
    then Duplicate_client_order_id
    else if starts "Reduce only order would increase position"
    then Reduce_only_would_increase
    else if starts "Order must have minimum value of $"
    then (
      let amount =
        String.drop_prefix m (String.length "Order must have minimum value of $")
        |> String.chop_suffix_if_exists ~suffix:"."
      in
      match Usd.of_string_opt amount with
      | Some min -> Below_min_value { min }
      | None -> Unsupported msg)
    else if starts "Insufficient margin"
    then Insufficient_margin
    else if starts "Order could not immediately match"
            || starts "No liquidity available for market order"
    then No_liquidity
    else if starts "Order would have matched against own"
    then Self_trade
    else if starts "Unknown coin" || String.is_suffix m ~suffix:"does not exist."
    then Unknown_symbol
    else if starts "Cannot modify canceled or filled order"
            || starts "Order was never placed, already canceled, or filled"
    then Order_not_found
    else Unsupported msg
  ;;

  let order_status (status : Order_status.t) : Neutral.Order_status.t =
    match status with
    | Resting { oid; cloid } -> Resting { order_id = oid; client_order_id = cloid }
    | Filled { oid; total_sz; avg_px; cloid } ->
      Filled { order_id = oid; total = total_sz; avg_px; client_order_id = cloid }
    | Error msg -> Rejected (reject_reason msg)
    | Waiting_for_fill -> Rejected (Unsupported "waitingForFill")
    | Waiting_for_trigger -> Rejected (Unsupported "waitingForTrigger")
  ;;

  let order_request meta (r : Neutral.Order_request.t)
    : (Order_request.t, Neutral.Reject_reason.t) Result.t
    =
    let open Result.Let_syntax in
    let%bind asset =
      Result.of_option
        (Meta.asset_of_coin meta r.symbol)
        ~error:Neutral.Reject_reason.Unknown_symbol
    in
    let%bind tif, limit_px =
      match r.order_type, r.px with
      | Market _, _ ->
        Error (Neutral.Reject_reason.Unsupported "market orders: send an IOC limit order")
      | Limit _, None -> Error Neutral.Reject_reason.Invalid_price
      | Limit tif, Some px -> Ok (tif, px)
    in
    let%map cloid =
      match r.client_order_id with
      | None -> Ok None
      | Some id ->
        (match Cloid.of_string_opt (Neutral.Client_order_id.to_string id) with
         | Some cloid -> Ok (Some cloid)
         | None ->
           Error
             (Neutral.Reject_reason.Unsupported
                "client order id must be 0x followed by 32 hex digits"))
    in
    { Order_request.asset
    ; is_buy = Side.is_buy r.side
    ; limit_px
    ; sz = r.size
    ; reduce_only = r.reduce_only
    ; order_type = Limit { tif }
    ; cloid
    }
  ;;
end

module Client = Hl_client.Client

type t =
  { client : Client.trading Client.t
  ; address : Address.t
  ; ws : Hl_client.Ws.t
  ; meta : Meta.t
  ; connected_at : int (** ns *)
  ; seen_tids : Int.Hash_set.t
  ; fills_r : Fill.t Pipe.Reader.t
  ; fills_w : Fill.t Pipe.Writer.t
  ; updates_r : Neutral_update.t Pipe.Reader.t
  ; updates_w : Neutral_update.t Pipe.Writer.t
  ; mutable book_writers : (Coin.t * Neutral.L2.t Pipe.Writer.t) list
  ; reconnect_hooks : (unit -> unit) Queue.t
  ; mutable closed : bool
  }

let on_message t (message : Ws_message.t) =
  match message with
  | L2_book book ->
    t.book_writers <- List.filter t.book_writers ~f:(fun (_, w) -> not (Pipe.is_closed w));
    let neutral = lazy (Convert.l2 book) in
    List.iter t.book_writers ~f:(fun (coin, w) ->
      if Coin.equal coin book.coin then Pipe.write_without_pushback w (force neutral))
  | User_fills { is_snapshot; fills; user = _ } ->
    (* A snapshot (sent on every (re)subscription) replays history: keep only fills since
       connect, each trade id once. *)
    List.iter fills ~f:(fun (fill : User_fill.t) ->
      let fill = Convert.fill fill in
      let tid = Neutral.Trade_id.to_int fill.trade_id in
      if ((not is_snapshot) || fill.time >= t.connected_at)
         && not (Hash_set.mem t.seen_tids tid)
      then (
        Hash_set.add t.seen_tids tid;
        Pipe.write_without_pushback_if_open t.fills_w fill))
  | Order_updates updates ->
    List.iter updates ~f:(fun u ->
      Pipe.write_without_pushback_if_open t.updates_w (Convert.order_update u))
  | Error msg -> Log.Global.error "websocket error: %s" msg
  | Subscription_response _ | Trades _ | All_mids _ | Pong | Unknown _ -> ()
;;

let connect_trading (client : Client.trading Client.t) =
  match (Client.config client).address with
  | None -> Deferred.Or_error.error_string "Hl_venue.connect: the config has no address"
  | Some address ->
    let open Deferred.Or_error.Let_syntax in
    let%bind meta = Client.meta client in
    let reconnect_hooks = Queue.create () in
    let on_reconnect () = Queue.iter reconnect_hooks ~f:(fun f -> f ()) in
    let%bind ws = Hl_client.Ws.connect ~on_reconnect (Client.config client) in
    let fills_r, fills_w = Pipe.create () in
    let updates_r, updates_w = Pipe.create () in
    let t =
      { client
      ; address
      ; ws
      ; meta
      ; connected_at = Time_ns.to_int_ns_since_epoch (Time_ns.now ())
      ; seen_tids = Int.Hash_set.create ()
      ; fills_r
      ; fills_w
      ; updates_r
      ; updates_w
      ; book_writers = []
      ; reconnect_hooks
      ; closed = false
      }
    in
    don't_wait_for
      (Pipe.iter_without_pushback (Hl_client.Ws.messages ws) ~f:(on_message t));
    let%map () =
      Deferred.List.iter
        ~how:`Sequential
        [ Subscription.Order_updates { user = address }; User_fills { user = address } ]
        ~f:(Hl_client.Ws.subscribe ws)
      |> Deferred.ok
    in
    t
;;

let instrument t coin =
  let open Deferred.Or_error.Let_syntax in
  let%bind asset_meta =
    match Meta.find t.meta coin with
    | Some asset_meta -> return asset_meta
    | None -> Deferred.Or_error.error_s [%message "unknown coin" (coin : Coin.t)]
  in
  let%bind book = Client.l2_book t.client coin in
  let%map mid =
    match L2_book.best_bid book, L2_book.best_ask book with
    | Some bid, Some ask -> return (Price.div_int Price.(bid.px + ask.px) 2)
    | _ -> Deferred.Or_error.error_s [%message "empty book" (coin : Coin.t)]
  in
  let sz_decimals = asset_meta.sz_decimals in
  Neutral.Instrument.create
    coin
    ~size_decimals:sz_decimals
    ~price_tick:(tick_of_mid ~sz_decimals mid)
    ~max_significant_figures:5
    ~max_leverage:asset_meta.max_leverage
;;

let books t coin =
  let r, w = Pipe.create () in
  t.book_writers <- (coin, w) :: t.book_writers;
  let%map () = Hl_client.Ws.subscribe t.ws (L2_book { coin }) in
  r
;;

let fills t = t.fills_r
let order_updates t = t.updates_r

let open_orders t coin =
  let%map.Deferred.Or_error orders = Client.open_orders t.client in
  List.filter_map orders ~f:(fun (o : Open_order.t) ->
    Option.some_if (Coin.equal o.coin coin) (Convert.open_order o))
;;

let account t =
  Client.clearinghouse_state t.client
  |> Deferred.Or_error.map ~f:(Convert.account t.address)
;;

let place t requests =
  let converted = List.map requests ~f:(Convert.order_request t.meta) in
  let to_send = List.filter_map converted ~f:Result.ok in
  let%map.Deferred.Or_error statuses =
    if List.is_empty to_send
    then Deferred.Or_error.return []
    else (
      match%map Client.place_orders t.client to_send with
      | Error _ as error -> error
      | Ok (Ok (Order statuses)) when List.length statuses = List.length to_send ->
        Ok (List.map statuses ~f:Convert.order_status)
      | Ok (Err msg) -> Or_error.error_s [%message "order" msg]
      | Ok response ->
        Or_error.error_s
          [%message "order: unexpected response" (response : Exchange_response.t)])
  in
  (* Merge the local rejections back in request order. *)
  let rec merge converted statuses =
    match converted, statuses with
    | [], _ -> []
    | Error reason :: rest, statuses ->
      Neutral.Order_status.Rejected reason :: merge rest statuses
    | Ok _ :: rest, status :: statuses -> status :: merge rest statuses
    | Ok _ :: _, [] -> assert false
  in
  merge converted statuses
;;

let cancel t coin oids =
  match Meta.asset_of_coin t.meta coin, oids with
  | _, [] -> Deferred.Or_error.ok_unit
  | None, _ -> Deferred.Or_error.error_s [%message "unknown coin" (coin : Coin.t)]
  | Some asset, oids ->
    let cancels = List.map oids ~f:(fun oid -> { Cancel_request.asset; oid }) in
    (match%map Client.cancel t.client cancels with
     | Error _ as error -> error
     | Ok (Ok (Cancel statuses)) ->
       (* Already filled or cancelled orders are not an error. *)
       List.iter statuses ~f:(function
         | Success -> ()
         | Error msg -> Log.Global.debug "cancel failed: %s" msg);
       Ok ()
     | Ok (Err msg) -> Or_error.error_s [%message "cancel" msg]
     | Ok response ->
       Or_error.error_s
         [%message "cancel: unexpected response" (response : Exchange_response.t)])
;;

let cancel_all t coin =
  let%bind.Deferred.Or_error orders = open_orders t coin in
  cancel t coin (List.map orders ~f:(fun (o : Neutral.Open_order.t) -> o.order_id))
;;

let on_reconnect t ~f = Queue.enqueue t.reconnect_hooks f

let close t =
  if t.closed
  then return ()
  else (
    t.closed <- true;
    let%map () = Hl_client.Ws.close t.ws in
    Pipe.close t.fills_w;
    Pipe.close t.updates_w;
    List.iter t.book_writers ~f:(fun (_, w) -> Pipe.close w))
;;

type config = Hl_client.Config.t

(* Unsigned: hl-sim takes the account from the X-Address header. *)
let connect config = connect_trading (Client.trading config)

module Trading = struct
  type nonrec t = t
  type config = Client.trading Client.t

  let connect = connect_trading
  let instrument = instrument
  let books = books
  let fills = fills
  let order_updates = order_updates
  let open_orders = open_orders
  let account = account
  let place = place
  let cancel = cancel
  let cancel_all = cancel_all
  let on_reconnect = on_reconnect
  let close = close
end
