(** Turns the desired ladder and the resting orders into a minimal plan.

    Each desired quote, in order, keeps the closest unused resting order of the same coin
    and side that has exactly the desired size, is within [requote_threshold_bps] of the
    desired price and is younger than [order_ttl_ms]. Resting orders left over are
    cancelled; desired quotes left over are placed as post-only (ALO) limit orders.

    The plan lists cancels (in open-order order), then places (in desired order), then
    keeps. Resting orders on other coins are ignored. *)

open! Core
open Hl_protocol

(** Deterministic client order id: 8 bytes of the coin name (zero padded), 1 byte side (0
    buy, 1 sell), 1 byte level and the low 48 bits of the generation, hex encoded. [level]
    must be in [[0, 255]]. *)
val cloid : coin:Coin.t -> side:Side.t -> level:int -> generation:int -> Cloid.t

(** Level reserved for the reduce-only flatten order. *)
val flatten_level : int

(** [|current - desired| <= requote_threshold_bps] of [desired]. *)
val within_tolerance : Params.t -> current:Price.t -> desired:Price.t -> bool

(** The post-only order request for a desired quote. *)
val order_request : Params.t -> generation:int -> Quote.t -> Order_request.t

val reconcile
  :  Params.t
  -> now:int
  -> generation:int
  -> open_orders:Open_order.t list
  -> desired:Quote.t list
  -> Action.t list
