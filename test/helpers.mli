(** Fixtures shared by the tests. *)

open! Core
open Hl_protocol

val px : string -> Price.t
val sz : string -> Size.t
val usd : string -> Usd.t

(** Two-sided BTC book with one level per side: [book ~time ~bid ~ask ()]. Sizes default
    to 1. *)
val book
  :  ?time:int
  -> ?bid_sz:string
  -> ?ask_sz:string
  -> bid:string
  -> ask:string
  -> unit
  -> L2_book.t

val fill
  :  ?time:int
  -> ?fee:string
  -> ?closed_pnl:string
  -> tid:int
  -> side:Side.t
  -> px:string
  -> sz:string
  -> unit
  -> User_fill.t

val open_order
  :  ?timestamp:int
  -> ?cloid:Cloid.t
  -> oid:int
  -> side:Side.t
  -> px:string
  -> sz:string
  -> unit
  -> Open_order.t
