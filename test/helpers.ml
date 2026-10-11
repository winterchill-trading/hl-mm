open! Core
open Hl_protocol

let px = Price.of_string
let sz = Size.of_string
let usd = Usd.of_string
let btc = Coin.of_string "BTC"

let book ?(time = 0) ?(bid_sz = "1") ?(ask_sz = "1") ~bid ~ask () : L2_book.t =
  { coin = btc
  ; time
  ; bids = [ { px = px bid; sz = sz bid_sz; n = 1 } ]
  ; asks = [ { px = px ask; sz = sz ask_sz; n = 1 } ]
  }
;;

let fill ?(time = 0) ?(fee = "0") ?(closed_pnl = "0") ~tid ~side ~px:p ~sz:s ()
  : User_fill.t
  =
  { coin = btc
  ; px = px p
  ; sz = sz s
  ; side
  ; time
  ; start_position = Size.zero
  ; dir = ""
  ; closed_pnl = usd closed_pnl
  ; hash = "0x0"
  ; oid = Order_id.of_int tid
  ; crossed = false
  ; fee = usd fee
  ; tid
  ; fee_token = None
  ; cloid = None
  }
;;

let open_order ?(timestamp = 0) ?cloid ~oid ~side ~px:p ~sz:s () : Open_order.t =
  { coin = btc
  ; side
  ; limit_px = px p
  ; sz = sz s
  ; oid = Order_id.of_int oid
  ; timestamp
  ; orig_sz = None
  ; cloid
  }
;;
