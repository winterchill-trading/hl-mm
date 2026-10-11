(** A desired resting order: one rung of the ladder. [level] 0 is closest to the
    reservation price. *)

open! Core
open Hl_protocol

type t =
  { side : Side.t
  ; level : int
  ; px : Price.t
  ; sz : Size.t
  }
[@@deriving sexp, compare, equal]
