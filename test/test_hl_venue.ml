open! Core
open Hl_protocol
open Hl_mm
module Convert = Hl_venue.Convert

let%expect_test "reject messages map back to reasons" =
  List.iter
    [ "Post only order would have immediately matched, bbo was 99941@99950. asset=0"
    ; "Post only order would have immediately matched, bbo was none@99950. asset=0"
    ; "Order must have minimum value of $10. asset=0"
    ; "Insufficient margin to place order. asset=0"
    ; "Order has invalid price. asset=0"
    ; "Reduce only order would increase position. asset=0"
    ; "Order could not immediately match against any resting orders. asset=0"
    ; "Asset 7 does not exist."
    ; "Something new."
    ]
    ~f:(fun msg ->
      print_s [%sexp (Convert.reject_reason msg : Exchange_core.Reject_reason.t)]);
  [%expect
    {|
    (Post_only_would_cross (best_bid (99941)) (best_ask (99950)))
    (Post_only_would_cross (best_bid ()) (best_ask (99950)))
    (Below_min_value (min 10))
    Insufficient_margin
    Invalid_price
    Reduce_only_would_increase
    No_liquidity
    Unknown_symbol
    (Unsupported "Something new.")
    |}]
;;

let%expect_test "order updates" =
  let order sz : Open_order.t =
    { coin = Coin.of_string "BTC"
    ; side = Buy
    ; limit_px = Price.of_string "99970"
    ; sz = Size.of_string sz
    ; oid = Order_id.of_int 5
    ; timestamp = 1_000
    ; orig_sz = Some (Size.of_string "0.003")
    ; cloid = None
    }
  in
  List.iter
    [ "0.003", Order_update.Status.Open
    ; "0.001", Open
    ; "0", Filled
    ; "0.001", Canceled
    ; "0.003", Other "badAloPxRejected"
    ; "0.003", Other "selfTradeCanceled"
    ]
    ~f:(fun (sz, status) ->
      let u = Convert.order_update { order = order sz; status; status_timestamp = 2 } in
      print_s
        [%message
          ""
            ~_:(u.status : Mm_core.Order_update.Status.t)
            ~filled:(u.filled : Size.t)
            ~remaining:(u.remaining : Size.t)
            ~time:(u.time : int)]);
  [%expect
    {|
    (New (filled 0) (remaining 0.003) (time 2000000))
    (Partially_filled (filled 0.002) (remaining 0.001) (time 2000000))
    (Filled (filled 0.003) (remaining 0) (time 2000000))
    (Cancelled (filled 0.002) (remaining 0) (time 2000000))
    (Rejected (filled 0) (remaining 0) (time 2000000))
    (Cancelled (filled 0) (remaining 0) (time 2000000))
    |}]
;;

let%expect_test "order requests" =
  let meta : Meta.t =
    { universe =
        [ { name = Coin.of_string "BTC"
          ; sz_decimals = 5
          ; max_leverage = 40
          ; only_isolated = false
          }
        ]
    }
  in
  let btc = Exchange_core.Symbol.of_string "BTC" in
  let show r =
    print_s
      [%sexp
        (Convert.order_request meta r
         : (Order_request.t, Exchange_core.Reject_reason.t) Result.t)]
  in
  show
    (Exchange_core.Order_request.limit
       ~tif:Alo
       ~client_order_id:
         (Exchange_core.Client_order_id.of_string "0x42544300000000000000000000000007")
       btc
       Buy
       ~px:(Price.of_string "99970")
       ~size:(Size.of_string "0.001"));
  show (Exchange_core.Order_request.market btc Sell ~size:(Size.of_string "0.001"));
  show
    (Exchange_core.Order_request.limit
       (Exchange_core.Symbol.of_string "DOGE")
       Sell
       ~px:Price.one
       ~size:Size.one);
  [%expect
    {|
    (Ok
     ((asset 0) (is_buy true) (limit_px 99970) (sz 0.001) (reduce_only false)
      (order_type (Limit (tif Alo)))
      (cloid (0x42544300000000000000000000000007))))
    (Error (Unsupported "market orders: send an IOC limit order"))
    (Error Unknown_symbol)
    |}]
;;
