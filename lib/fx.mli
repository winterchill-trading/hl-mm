(** Small arithmetic helpers over the fixed-point types of [hl-protocol].

    TODO: replace [notional] and [bps_of] with the multiplication/division helpers once
    [fixed-decimal] exposes them. Until then products go through [float], which is exact
    to well below a cent for the magnitudes a single market maker deals with. *)

open! Core
open Hl_protocol

(** [price * size] as a USD amount, rounded to the nearest [10^-8]. *)
val notional : Price.t -> Size.t -> Usd.t

(** [usd / price] as a size, truncated toward zero. *)
val size_of_notional : Usd.t -> Price.t -> Size.t

(** [px * (1 + bps / 10_000)], rounded to the nearest [10^-8] (no tick rounding). *)
val shift_bps : Price.t -> float -> Price.t

(** Signed distance from [base] to [px] in basis points of [base]. *)
val bps_between : base:Price.t -> Price.t -> float

(** Largest multiple of [step] that is [<= units]. [step > 0]. *)
val floor_to : int -> step:int -> int

(** Smallest multiple of [step] that is [>= units]. [step > 0]. *)
val ceil_to : int -> step:int -> int

(** Price rounding to a tick. *)
val price_floor : Price.t -> tick:Price.t -> Price.t

val price_ceil : Price.t -> tick:Price.t -> Price.t

(** Size truncated down to a lot multiple (toward zero for positive sizes). *)
val size_floor : Size.t -> lot:Size.t -> Size.t

(** [-1], [0] or [1]. *)
val sign_of_size : Size.t -> int

(** The signed change in position a fill or order on [side] of [size] causes. *)
val signed : Side.t -> Size.t -> Size.t
