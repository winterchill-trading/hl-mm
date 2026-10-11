open! Core
open Hl_protocol
open Hl_mm
open Helpers

(* A minimal venue: rests ALO orders with fresh oids, drops cancelled ones, ignores IOCs. *)
module Venue = struct
  type t =
    { mutable orders : Open_order.t list
    ; mutable next_oid : int
    }

  let create () = { orders = []; next_oid = 100 }

  let apply t ~now actions =
    List.iter actions ~f:(function
      | Action.Keep _ -> ()
      | Cancel oid ->
        t.orders <- List.filter t.orders ~f:(fun o -> not (Order_id.equal o.oid oid))
      | Place (r : Order_request.t) ->
        (match r.order_type with
         | Limit { tif = Alo } ->
           t.next_oid <- t.next_oid + 1;
           t.orders
           <- t.orders
              @ [ { coin = Coin.of_string "BTC"
                  ; side = Order_request.side r
                  ; limit_px = r.limit_px
                  ; sz = r.sz
                  ; oid = Order_id.of_int t.next_oid
                  ; timestamp = now
                  ; orig_sz = Some r.sz
                  ; cloid = r.cloid
                  }
                ]
         | _ -> ()))
  ;;
end

let summarize actions =
  let count f = List.count actions ~f in
  printf
    "keep=%d cancel=%d place=%d\n"
    (count (function
      | Action.Keep _ -> true
      | _ -> false))
    (count (function
      | Action.Cancel _ -> true
      | _ -> false))
    (count (function
      | Action.Place _ -> true
      | _ -> false))
;;

let print_places actions =
  List.iter actions ~f:(function
    | Action.Place r ->
      printf
        "  %s %s @ %s%s\n"
        (if r.is_buy then "buy " else "sell")
        (Size.to_string r.sz)
        (Price.to_string r.limit_px)
        (if r.reduce_only then " reduce-only IOC" else "")
    | Keep _ | Cancel _ -> ())
;;

(* Tick, send the plan to the venue and acknowledge it with a snapshot. *)
let step venue t ~now =
  let t, actions = Strategy.tick t ~now in
  Venue.apply venue ~now actions;
  let t = Strategy.on_open_orders t venue.orders in
  summarize actions;
  print_places actions;
  print_s [%sexp (Strategy.mode t : Strategy.Mode.t)];
  t
;;

let%expect_test "lifecycle" =
  let venue = Venue.create () in
  let t = Strategy.create Params.btc in
  let t = step venue t ~now:0 in
  [%expect {|
    keep=0 cancel=0 place=0
    (Pulled No_market_data)
    |}];
  let t = Strategy.on_book t (book ~time:100 ~bid:"99990" ~ask:"100010" ()) in
  let t = step venue t ~now:100 in
  [%expect
    {|
    keep=0 cancel=0 place=6
      buy  0.001 @ 99970
      buy  0.001 @ 99950
      buy  0.001 @ 99930
      sell 0.001 @ 100030
      sell 0.001 @ 100050
      sell 0.001 @ 100070
    Running
    |}];
  (* Same book: nothing to do, even after the requote interval. *)
  let t = Strategy.on_book t (book ~time:1_200 ~bid:"99990" ~ask:"100010" ()) in
  let t = step venue t ~now:1_200 in
  [%expect {|
    keep=0 cancel=0 place=0
    Running
    |}];
  (* Best bid quote fills: the ladder skews down and refills the bid at a lower price. *)
  let t =
    Strategy.on_fill t (fill ~time:1_300 ~tid:1 ~side:Buy ~px:"99970" ~sz:"0.001" ())
  in
  let venue_orders =
    List.filter venue.orders ~f:(fun o ->
      not (Side.equal o.side Buy && Price.equal o.limit_px (px "99970")))
  in
  venue.orders <- venue_orders;
  let t = Strategy.on_open_orders t venue.orders in
  let t = step venue t ~now:1_300 in
  [%expect {|
    keep=5 cancel=0 place=1
      buy  0.001 @ 99966
    Running
    |}];
  (* Data goes stale: quotes are pulled, then restored on a fresh book. *)
  let t = step venue t ~now:7_000 in
  [%expect
    {|
    keep=0 cancel=6 place=0
    (Pulled (Stale_market_data (age_ms 5800)))
    |}];
  let t = Strategy.on_book t (book ~time:7_100 ~bid:"99990" ~ask:"100010" ()) in
  let t = step venue t ~now:7_100 in
  [%expect
    {|
    keep=0 cancel=0 place=6
      buy  0.001 @ 99966
      buy  0.001 @ 99946
      buy  0.001 @ 99926
      sell 0.001 @ 100026
      sell 0.001 @ 100046
      sell 0.001 @ 100066
    Running
    |}];
  ignore (t : Strategy.t)
;;

let%expect_test "waits for an acknowledgement before replanning" =
  let t = Strategy.create Params.btc in
  let t = Strategy.on_book t (book ~time:0 ~bid:"99990" ~ask:"100010" ()) in
  let t, first = Strategy.tick t ~now:0 in
  summarize first;
  let t = Strategy.on_book t (book ~time:500 ~bid:"100990" ~ask:"101010" ()) in
  let t, second = Strategy.tick t ~now:500 in
  summarize second;
  (* No snapshot arrived: after the interval it may cancel, but never re-places blind. *)
  let _t, third = Strategy.tick t ~now:1_000 in
  summarize third;
  [%expect
    {|
    keep=0 cancel=0 place=6
    keep=0 cancel=0 place=0
    keep=0 cancel=0 place=0
    |}]
;;

let%expect_test "drawdown halts permanently and flattens" =
  let venue = Venue.create () in
  let t = Strategy.create Params.btc in
  let t = Strategy.on_book t (book ~time:0 ~bid:"99990" ~ask:"100010" ()) in
  let t = step venue t ~now:0 in
  [%expect
    {|
    keep=0 cancel=0 place=6
      buy  0.001 @ 99970
      buy  0.001 @ 99950
      buy  0.001 @ 99930
      sell 0.001 @ 100030
      sell 0.001 @ 100050
      sell 0.001 @ 100070
    Running
    |}];
  let t =
    Strategy.on_fill t (fill ~time:10 ~tid:1 ~side:Buy ~px:"100000" ~sz:"0.01" ())
  in
  let t = Strategy.on_book t (book ~time:2_000 ~bid:"93990" ~ask:"94010" ()) in
  let t = step venue t ~now:2_000 in
  [%expect
    {|
    keep=0 cancel=6 place=1
      sell 0.01 @ 93530 reduce-only IOC
    (Halted (Max_drawdown (pnl -60) (peak 0)))
    |}];
  (* Still long (the IOC did not fill here): flatten again after the interval. *)
  let t = Strategy.on_book t (book ~time:3_000 ~bid:"99990" ~ask:"100010" ()) in
  let t = step venue t ~now:3_000 in
  [%expect
    {|
    keep=0 cancel=0 place=1
      sell 0.01 @ 99500 reduce-only IOC
    (Halted (Max_drawdown (pnl -60) (peak 0)))
    |}];
  let t =
    Strategy.on_fill t (fill ~time:3_010 ~tid:2 ~side:Sell ~px:"99950" ~sz:"0.01" ())
  in
  let t = step venue t ~now:4_000 in
  [%expect
    {|
    keep=0 cancel=0 place=0
    (Halted (Max_drawdown (pnl -60) (peak 0)))
    |}];
  ignore (t : Strategy.t)
;;
