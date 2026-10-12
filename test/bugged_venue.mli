(** Fault injection over any {!Mm_core.Venue.S}, for testing a real adapter (here
    {!Hl_mm.Hl_venue} against hl-sim) the way mm-core's memory venue tests the loop. Bugs
    are driven by a seeded random state, so a run is repeatable for a given sequence of
    calls; pair it with hl-sim's [response_delay] for late acks. *)

open! Core
open! Async

module Bugs : sig
  type t =
    { seed : int
    ; reject_percent : int
    (** each order is rejected locally, without reaching the venue, with this probability *)
    ; timeout_places : int
    (** the first [timeout_places] calls to [place] that take longer than [place_timeout]
        fail with a timeout, although the request still reaches the venue and its orders
        rest *)
    ; place_timeout : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  val none : t
end

module Injected : sig
  type t =
    { rejects : int
    ; timeouts : int
    }
  [@@deriving sexp_of]
end

module Make (V : Mm_core.Venue.S) : sig
  include Mm_core.Venue.S with type config = Bugs.t * V.config

  val injected : t -> Injected.t
  val inner : t -> V.t
end
