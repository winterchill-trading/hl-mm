(** Strategy parameter overrides read from a file ([hl-mm -params FILE]): a sexp listing
    some fields of [Mm_core.Params.t] by name, e.g.

    {v
((levels 5)
 (max_actions_per_sec 50)
 (soft_max_position (0.005)))
    v}

    Fields that are left out keep their value from the base parameters (the instrument
    defaults and command-line flags). [soft_max_position] is an option: write
    [(soft_max_position (0.005))] to set it and [(soft_max_position ())] to clear it. *)

open! Core

(** Replaces the fields named in [overrides] (a list of [(name value)] pairs) and runs
    [Mm_core.Params.validate]. Unknown or repeated fields, a different [symbol] and values
    that fail validation are errors. *)
val apply : Mm_core.Params.t -> overrides:Sexp.t -> Mm_core.Params.t Or_error.t

(** [apply] with the sexp read from [path] (the whole file is one sexp). *)
val load : string -> base:Mm_core.Params.t -> Mm_core.Params.t Or_error.t
