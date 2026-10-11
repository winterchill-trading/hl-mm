(** Position and PnL of one coin, tracked from fills and corrected by clearinghouse
    snapshots.

    Average-cost accounting: a fill that grows the position (or opens one) moves the
    average entry to the size-weighted mean of the old entry and the fill price; a fill
    that reduces it realizes [closed * (px - entry) * sign(position)] and leaves the entry
    unchanged; a fill that flips the position closes the old one and opens the remainder
    at the fill price. Fees accumulate separately.

    A clearinghouse snapshot overwrites position and entry. Fills timestamped at or before
    the last snapshot are already reflected in it: they add their fee and the exchange's
    [closed_pnl] but do not move the position. Fills are de-duplicated by [tid]. *)

open! Core
open Hl_protocol

type t [@@deriving sexp_of]

val empty : t

(** Applies a fill. The caller filters by coin. *)
val on_fill : t -> User_fill.t -> t

(** Takes position and entry for [coin] from a clearinghouse snapshot (flat if the coin is
    absent). Realized PnL and fees are kept. *)
val sync : t -> Clearinghouse_state.t -> coin:Coin.t -> t

(** Signed position: positive long, negative short. *)
val position : t -> Size.t

val avg_entry : t -> Price.t option
val realized_pnl : t -> Usd.t
val fees : t -> Usd.t
val fill_count : t -> int

(** [position * (mark - avg_entry)]. *)
val unrealized_pnl : t -> mark:Price.t -> Usd.t

(** [realized + unrealized - fees]. *)
val total_pnl : t -> mark:Price.t -> Usd.t
