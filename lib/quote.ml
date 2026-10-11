open! Core
open Hl_protocol

type t =
  { side : Side.t
  ; level : int
  ; px : Price.t
  ; sz : Size.t
  }
[@@deriving sexp, compare, equal]
