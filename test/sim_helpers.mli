(** hl-sim fixtures shared by the live loop tests. *)

open! Core
open! Async
open Hl_protocol

val mm : Address.t
val maker : Address.t
val taker : Address.t

(** A limit order on asset 0 (BTC). *)
val order : is_buy:bool -> px:string -> sz:string -> tif:Tif.t -> Order_request.t

(** Polls [f] every 20ms until it holds; raises after [timeout] (default 10s). *)
val wait_until
  :  ?timeout:Time_ns.Span.t
  -> what:string
  -> (unit -> bool)
  -> unit Deferred.t

(** Prints the account's open orders, best price first: ["A 0.001@100070"]. *)
val print_open_orders : Hl_client.Config.t -> unit Deferred.t

type sim =
  { server : Hl_sim.Server.t
  ; http : (Socket.Address.Inet.t, int) Cohttp_async.Server.t
  ; client : Address.t -> Hl_client.Config.t
  }

(** Starts hl-sim on a free port (logging off) and rests a static book 20 bps wide around
    100000 (0.01 at 99900 and 100100) from [maker]. *)
val start_sim : ?config:Hl_sim.Server.Config.t -> unit -> sim Deferred.t

val stop_sim : sim -> unit Deferred.t
