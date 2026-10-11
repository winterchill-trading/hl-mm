open! Core
open Hl_protocol
open Hl_mm
open Helpers

let params = Params.btc

let desired =
  [ { Quote.side = Buy; level = 0; px = px "99970"; sz = sz "0.001" }
  ; { Quote.side = Buy; level = 1; px = px "99950"; sz = sz "0.001" }
  ; { Quote.side = Sell; level = 0; px = px "100030"; sz = sz "0.001" }
  ]
;;

(* Resting orders exactly as the desired ladder. *)
let resting =
  [ open_order ~oid:1 ~side:Buy ~px:"99970" ~sz:"0.001" ()
  ; open_order ~oid:2 ~side:Buy ~px:"99950" ~sz:"0.001" ()
  ; open_order ~oid:3 ~side:Sell ~px:"100030" ~sz:"0.001" ()
  ]
;;

let show ?(now = 1_000) ?(params = params) open_orders desired =
  Reconciler.reconcile params ~now ~generation:7 ~open_orders ~desired
  |> List.iter ~f:(fun a -> print_s [%sexp (a : Action.t)])
;;

let%expect_test "cloid layout" =
  List.iter
    [ Side.Buy, 0, 0; Sell, 2, 7; Buy, Reconciler.flatten_level, 1 lsl 40 ]
    ~f:(fun (side, level, generation) ->
      print_endline
        (Cloid.to_string
           (Reconciler.cloid ~coin:(Coin.of_string "BTC") ~side ~level ~generation)));
  [%expect
    {|
    0x42544300000000000000000000000000
    0x42544300000000000102000000000007
    0x425443000000000000ff010000000000
    |}]
;;

let%expect_test "empty book of orders: place the ladder" =
  show [] desired;
  [%expect
    {|
    (Place
     ((asset 0) (is_buy true) (limit_px 99970) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000000000000000007))))
    (Place
     ((asset 0) (is_buy true) (limit_px 99950) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000001000000000007))))
    (Place
     ((asset 0) (is_buy false) (limit_px 100030) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000100000000000007))))
    |}]
;;

let%expect_test "no churn when quotes are unchanged" =
  show resting desired;
  [%expect {|
    (Keep 1)
    (Keep 2)
    (Keep 3)
    |}]
;;

let%expect_test "drift inside the threshold keeps orders" =
  (* 1 bps of 100000 is 10. *)
  let shifted = List.map desired ~f:(fun q -> { q with px = Price.(q.px + px "9") }) in
  show resting shifted;
  [%expect {|
    (Keep 1)
    (Keep 2)
    (Keep 3)
    |}]
;;

let%expect_test "drift beyond the threshold cancels and replaces" =
  let shifted = List.map desired ~f:(fun q -> { q with px = Price.(q.px + px "11") }) in
  show resting shifted;
  [%expect
    {|
    (Cancel 2)
    (Cancel 3)
    (Place
     ((asset 0) (is_buy true) (limit_px 99981) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000000000000000007))))
    (Place
     ((asset 0) (is_buy false) (limit_px 100041) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000100000000000007))))
    (Keep 1)
    |}]
;;

let%expect_test "ladder shift by one level reuses the overlapping order" =
  let shifted =
    [ { Quote.side = Buy; level = 0; px = px "99950"; sz = sz "0.001" }
    ; { Quote.side = Buy; level = 1; px = px "99930"; sz = sz "0.001" }
    ; { Quote.side = Sell; level = 0; px = px "100030"; sz = sz "0.001" }
    ]
  in
  show resting shifted;
  [%expect
    {|
    (Cancel 1)
    (Place
     ((asset 0) (is_buy true) (limit_px 99930) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000001000000000007))))
    (Keep 2)
    (Keep 3)
    |}]
;;

let%expect_test "partially filled, expired and foreign orders" =
  let open_orders =
    [ open_order ~oid:1 ~side:Buy ~px:"99970" ~sz:"0.0004" ()
    ; open_order ~oid:2 ~side:Buy ~px:"99950" ~sz:"0.001" ~timestamp:(-60_000) ()
    ; open_order ~oid:3 ~side:Sell ~px:"100030" ~sz:"0.001" ()
    ; { (open_order ~oid:4 ~side:Sell ~px:"3000" ~sz:"1" ()) with
        coin = Coin.of_string "ETH"
      }
    ]
  in
  show open_orders desired;
  [%expect
    {|
    (Cancel 1)
    (Cancel 2)
    (Place
     ((asset 0) (is_buy true) (limit_px 99970) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000000000000000007))))
    (Place
     ((asset 0) (is_buy true) (limit_px 99950) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000001000000000007))))
    (Keep 3)
    |}]
;;

let%expect_test "duplicates: only one resting order per quote is kept" =
  show (resting @ [ open_order ~oid:9 ~side:Sell ~px:"100031" ~sz:"0.001" () ]) desired;
  [%expect {|
    (Cancel 9)
    (Keep 1)
    (Keep 2)
    (Keep 3)
    |}]
;;
