open! Core
open! Async
open Exchange_core

module Bugs = struct
  type t =
    { seed : int
    ; reject_percent : int
    ; timeout_places : int
    ; place_timeout : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  let none =
    { seed = 0
    ; reject_percent = 0
    ; timeout_places = 0
    ; place_timeout = Time_ns.Span.of_int_sec 10
    }
  ;;
end

module Injected = struct
  type t =
    { rejects : int
    ; timeouts : int
    }
  [@@deriving sexp_of]
end

module Make (V : Mm_core.Venue.S) = struct
  type config = Bugs.t * V.config

  type t =
    { venue : V.t
    ; bugs : Bugs.t
    ; random : Random.State.t
    ; mutable rejects : int
    ; mutable timeouts : int
    }

  let connect (bugs, config) =
    let%map.Deferred.Or_error venue = V.connect config in
    { venue
    ; bugs
    ; random = Random.State.make [| bugs.Bugs.seed |]
    ; rejects = 0
    ; timeouts = 0
    }
  ;;

  let injected t = { Injected.rejects = t.rejects; timeouts = t.timeouts }
  let inner t = t.venue
  let instrument t = V.instrument t.venue
  let books t = V.books t.venue
  let fills t = V.fills t.venue
  let order_updates t = V.order_updates t.venue
  let open_orders t = V.open_orders t.venue
  let account t = V.account t.venue
  let cancel t = V.cancel t.venue
  let cancel_all t = V.cancel_all t.venue
  let on_reconnect t = V.on_reconnect t.venue
  let close t = V.close t.venue

  let place t requests =
    let rejected =
      List.map requests ~f:(fun _ ->
        Random.State.int t.random 100 < t.bugs.reject_percent)
    in
    let to_send =
      List.filter_mapi requests ~f:(fun i r ->
        Option.some_if (not (List.nth_exn rejected i)) r)
    in
    let merge statuses =
      let rec go rejected statuses =
        match rejected, statuses with
        | [], _ -> []
        | true :: rest, statuses ->
          t.rejects <- t.rejects + 1;
          Order_status.Rejected (Unsupported "injected reject") :: go rest statuses
        | false :: rest, status :: statuses -> status :: go rest statuses
        | false :: _, [] -> assert false
      in
      go rejected statuses
    in
    let sent =
      if List.is_empty to_send
      then Deferred.Or_error.return []
      else V.place t.venue to_send
    in
    let timed =
      if t.timeouts < t.bugs.timeout_places && not (List.is_empty to_send)
      then (
        let%map (result : _ Clock_ns.Or_timeout.t) =
          Clock_ns.with_timeout t.bugs.place_timeout sent
        in
        match result with
        | `Result result -> result
        | `Timeout ->
          t.timeouts <- t.timeouts + 1;
          Or_error.error_string "injected place timeout")
      else sent
    in
    Deferred.Or_error.map timed ~f:merge
  ;;
end
