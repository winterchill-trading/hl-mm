(** The live event loop: connects {!Strategy} to an exchange through [hl-client].

    - Websocket subscriptions [l2Book(coin)], [orderUpdates(address)] and
      [userFills(address)] feed [Strategy.on_book] and [Strategy.on_fill].
    - [openOrders] and [clearinghouseState] are polled over HTTP every
      [requote_interval_ms], after every executed plan (the strategy waits for that
      snapshot before placing again), after an order leaves the book and after a websocket
      reconnect.
    - [Strategy.tick] runs after every book update, fill and poll. A non-empty plan is
      sent as at most two exchange actions: one [cancel] with every cancel, then one
      [order] with every place.

    Ticks, plan execution and polls run one at a time on a sequencer, so a snapshot always
    reflects the plans sent before it. Market data and fills are applied as they arrive.

    The exchange's acting account is [Hl_client.Config.address], which [hl-client] sends
    as the [X-Address] header (the simulator's convention). *)

open! Core
open! Async
open Hl_protocol

(** Exchange metadata for one coin. *)
module Instrument : sig
  type t =
    { coin : Coin.t
    ; asset : Asset.t
    ; tick : Price.t
    (** 1 at or above 10_000, else the 5th significant figure of the mid, at least
        [10^-(6 - szDecimals)] *)
    ; lot : Size.t (** [10^-szDecimals] *)
    ; mid : Price.t
    }
  [@@deriving sexp_of]

  (** [tick_of_mid ~sz_decimals mid] is the price increment Hyperliquid accepts at [mid]
      (integers or 5 significant figures, at most [6 - sz_decimals] decimals). *)
  val tick_of_mid : sz_decimals:int -> Price.t -> Price.t

  (** Fetches [meta] and the coin's book. Fails for an unknown coin or an empty book. *)
  val fetch : Hl_client.Config.t -> Coin.t -> t Or_error.t Deferred.t
end

module Report : sig
  type t =
    { elapsed : Time_ns.Span.t
    ; fills : int
    ; maker_fills : int
    ; volume : Usd.t (** sum of [px * sz] over our fills *)
    ; realized_pnl : Usd.t
    ; unrealized_pnl : Usd.t (** at the last mid *)
    ; fees : Usd.t
    ; total_pnl : Usd.t (** realized + unrealized - fees *)
    ; position : Size.t
    ; mid : Price.t option
    ; account_value : Usd.t option (** from the last clearinghouse snapshot *)
    ; plans : int
    ; orders_placed : int (** accepted: resting or filled *)
    ; orders_rejected : int
    ; rejections : (string * int) list (** reject message and count *)
    ; orders_cancelled : int
    ; ws_reconnects : int
    ; mode : Strategy.Mode.t
    }
  [@@deriving sexp_of]

  (** A multi-line, human readable summary. *)
  val to_string_hum : t -> string
end

module Config : sig
  type t =
    { client : Hl_client.Config.t (** must have an [address] *)
    ; params : Params.t
    ; summary_interval : Time_ns.Span.t
    (** how often position, PnL and resting quotes are logged *)
    }
  [@@deriving sexp_of]
end

type t

(** Connects, subscribes, takes an initial open orders and clearinghouse snapshot and
    starts quoting. Fails if the config has no address or the first connection fails. *)
val start : Config.t -> t Or_error.t Deferred.t

(** Stops quoting: waits for the step in flight, cancels every resting order on the coin
    (re-reading open orders until none are left, up to a few attempts), takes a final
    clearinghouse snapshot, closes the websocket and returns the report. Idempotent. *)
val stop : t -> Report.t Deferred.t

val report : t -> Report.t
val strategy : t -> Strategy.t

(** [start], wait for [stop] (a deferred), then [stop]. *)
val run : Config.t -> stop:unit Deferred.t -> Report.t Or_error.t Deferred.t
