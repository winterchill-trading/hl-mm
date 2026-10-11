(** The market maker as a deterministic state machine. Event handlers fold exchange data
    into the state; [tick] decides what to send. The live loop calls [tick] after events
    and on a timer; tests drive it directly.

    On each [tick ~now]:
    + PnL peak is updated at the current mid.
    + While a previous plan awaits an [on_open_orders] snapshot, nothing is sent for
      [requote_interval_ms]: placed orders have no oid yet, so a second plan could
      duplicate them. After that, plans may cancel and flatten but place no quotes until a
      snapshot arrives.
    + [Risk.check] picks the mode. A sticky halt ([Max_position], [Max_drawdown]) is
      permanent ([Halted]): every [requote_interval_ms] the flatten plan is sent until no
      orders rest and the position is flat. Missing or stale data ([Pulled]) cancels all
      resting orders until fresh data arrives.
    + [Running] requotes when the last plan is older than [requote_interval_ms], the mid
      moved at least [requote_threshold_bps] since then, the position changed, or the mode
      just became [Running]. The plan is [Reconciler.reconcile] of [Quoter.quote].

    A returned plan is non-empty only when it contains a [Cancel] or [Place]; it then also
    lists the [Keep]s. Cancelled orders are dropped from the local open orders right away;
    the generation (part of every cloid) increases after each plan that places orders. *)

open! Core
open Hl_protocol

module Mode : sig
  type t =
    | Running
    | Pulled of Risk.Reason.t
    | Halted of Risk.Reason.t
  [@@deriving sexp, compare, equal]
end

type t [@@deriving sexp_of]

(** Raises if [Params.validate] fails. *)
val create : Params.t -> t

(** Events for other coins are ignored. *)
val on_book : t -> L2_book.t -> t

val on_fill : t -> User_fill.t -> t

(** A full snapshot of resting orders (other coins are dropped). Ends the wait for an
    acknowledgement of the last plan. *)
val on_open_orders : t -> Open_order.t list -> t

val on_clearinghouse : t -> Clearinghouse_state.t -> t
val tick : t -> now:int -> t * Action.t list
val params : t -> Params.t
val mode : t -> Mode.t
val market : t -> Market_state.t
val inventory : t -> Inventory.t
val open_orders : t -> Open_order.t list
val generation : t -> int
val peak_pnl : t -> Usd.t
