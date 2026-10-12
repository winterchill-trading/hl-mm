(** {!Mm_core.Venue.S} over [hl-client]: Hyperliquid's HTTP and websocket API (or the
    [hl-sim] simulator), converted to [exchange-core] types.

    - [connect] needs [Hl_client.Config.address]: it fetches [meta] (asset indices), opens
      the websocket and subscribes to [orderUpdates] and [userFills] for the address.
      Exchange requests carry the [X-Address] header (the simulator's convention); they
      are signed only through {!Trading}.
    - Timestamps are converted from milliseconds to nanoseconds.
    - Fills are de-duplicated by trade id; fills from the [userFills] snapshot that
      happened before [connect] are dropped.
    - [instrument] reports as [price_tick] the tick valid at the current mid
      ({!tick_of_mid}), with Hyperliquid's 5 significant figure limit.
    - Rejection messages are mapped back to [Reject_reason.t] by their wording; messages
      it does not recognise become [Unsupported msg].
    - Market orders are rejected ([Unsupported]): Hyperliquid has none; send an IOC limit. *)

open! Core
open! Async
open Hl_protocol
(** Over a bare config, requests are unsigned (the simulator's convention). *)
include Mm_core.Venue.S with type config = Hl_client.Config.t

(** The same venue over a [Hl_client.Client.trading] handle, which signs exchange requests
    when it holds a key: the way to trade on the real exchange
    ([Hl_client.Client.trading_of_env (Hl_client.Config.testnet ())] reads
    [HL_PRIVATE_KEY]). The handle's address (the key's, unless the config names one) is
    the account. A [read_only] handle does not type-check as a [config]. *)
module Trading :
  Mm_core.Venue.S
  with type t = t
   and type config = Hl_client.Client.trading Hl_client.Client.t

(** [tick_of_mid ~sz_decimals mid] is the price increment Hyperliquid accepts at [mid]
    (integers or 5 significant figures, at most [6 - sz_decimals] decimals). *)
val tick_of_mid : sz_decimals:int -> Price.t -> Price.t

(** Pure conversions from Hyperliquid's wire types, exposed for testing. *)
module Convert : sig
  val ns_of_ms : int -> int
  val l2 : L2_book.t -> Exchange_core.L2.t
  val fill : User_fill.t -> Mm_core.Fill.t
  val open_order : Open_order.t -> Exchange_core.Open_order.t
  val order_update : Order_update.t -> Mm_core.Order_update.t
  val account : Address.t -> Clearinghouse_state.t -> Exchange_core.Account_view.t
  val reject_reason : string -> Exchange_core.Reject_reason.t
  val order_status : Order_status.t -> Exchange_core.Order_status.t

  (** [Error] for market orders and client ids that are not 128-bit hex. *)
  val order_request
    :  Meta.t
    -> Exchange_core.Order_request.t
    -> (Order_request.t, Exchange_core.Reject_reason.t) Result.t
end
