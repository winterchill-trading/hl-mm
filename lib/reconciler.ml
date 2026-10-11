open! Core
open Hl_protocol

let flatten_level = 255

let cloid ~coin ~(side : Side.t) ~level ~generation =
  if level < 0 || level > 255
  then raise_s [%message "Reconciler.cloid: level out of range" (level : int)];
  let name = Coin.to_string coin in
  let coin_hex =
    String.init 8 ~f:(fun i -> if i < String.length name then name.[i] else '\000')
    |> String.concat_map ~f:(fun c -> sprintf "%02x" (Char.to_int c))
  in
  let side_byte =
    match side with
    | Buy -> 0
    | Sell -> 1
  in
  Cloid.of_string
    (sprintf
       "0x%s%02x%02x%012x"
       coin_hex
       side_byte
       level
       (generation land 0xffff_ffff_ffff))
;;

let within_tolerance (p : Params.t) ~current ~desired =
  Float.(abs (Fx.bps_between ~base:desired current) <= p.requote_threshold_bps +. 1e-9)
;;

let order_request (p : Params.t) ~generation (q : Quote.t) : Order_request.t =
  { asset = p.asset
  ; is_buy = Side.is_buy q.side
  ; limit_px = q.px
  ; sz = q.sz
  ; reduce_only = false
  ; order_type = Order_type.alo
  ; cloid = Some (cloid ~coin:p.coin ~side:q.side ~level:q.level ~generation)
  }
;;

let reconcile (p : Params.t) ~now ~generation ~open_orders ~desired =
  let ours =
    List.filter open_orders ~f:(fun (o : Open_order.t) -> Coin.equal o.coin p.coin)
  in
  let keepable (o : Open_order.t) = now - o.timestamp < p.order_ttl_ms in
  let matches (q : Quote.t) (o : Open_order.t) =
    Side.equal o.side q.side
    && Size.equal o.sz q.sz
    && keepable o
    && within_tolerance p ~current:o.limit_px ~desired:q.px
  in
  let used, assignments =
    List.fold_map desired ~init:Order_id.Set.empty ~f:(fun used q ->
      let best =
        List.filter ours ~f:(fun o -> (not (Set.mem used o.oid)) && matches q o)
        |> List.min_elt ~compare:(fun (a : Open_order.t) (b : Open_order.t) ->
          let dist (o : Open_order.t) =
            abs (Price.to_units o.limit_px - Price.to_units q.px)
          in
          match Int.compare (dist a) (dist b) with
          | 0 -> Order_id.compare a.oid b.oid
          | c -> c)
      in
      match best with
      | Some o -> Set.add used o.oid, `Keep o.oid
      | None -> used, `Place q)
  in
  let cancels =
    List.filter_map ours ~f:(fun o ->
      Option.some_if (not (Set.mem used o.oid)) (Action.Cancel o.oid))
  in
  let places =
    List.filter_map assignments ~f:(function
      | `Place q -> Some (Action.Place (order_request p ~generation q))
      | `Keep _ -> None)
  in
  let keeps =
    List.filter_map assignments ~f:(function
      | `Keep oid -> Some (Action.Keep oid)
      | `Place _ -> None)
  in
  cancels @ places @ keeps
;;
