open! Core
open Hl_protocol

type t =
  { coin : Coin.t
  ; asset : Asset.t
  ; tick : Price.t
  ; lot : Size.t
  ; order_size : Size.t
  ; levels : int
  ; base_half_spread_bps : float
  ; level_spacing_bps : float
  ; skew_bps : float
  ; max_position : Size.t
  ; max_notional : Usd.t
  ; inventory_target : Size.t
  ; requote_threshold_bps : float
  ; requote_interval_ms : int
  ; order_ttl_ms : int
  ; gamma : float
  ; vol_window : int
  ; max_vol_bps : float
  ; max_drawdown : Usd.t
  ; max_data_age_ms : int
  ; flatten_slippage_bps : float
  }
[@@deriving sexp, compare, equal]

let btc =
  { coin = Coin.of_string "BTC"
  ; asset = Asset.of_int 0
  ; tick = Price.of_string "1"
  ; lot = Size.of_string "0.00001"
  ; order_size = Size.of_string "0.001"
  ; levels = 3
  ; base_half_spread_bps = 3.
  ; level_spacing_bps = 2.
  ; skew_bps = 4.
  ; max_position = Size.of_string "0.01"
  ; max_notional = Usd.of_string "1500"
  ; inventory_target = Size.zero
  ; requote_threshold_bps = 1.
  ; requote_interval_ms = 1_000
  ; order_ttl_ms = 60_000
  ; gamma = 0.5
  ; vol_window = 100
  ; max_vol_bps = 10.
  ; max_drawdown = Usd.of_string "50"
  ; max_data_age_ms = 5_000
  ; flatten_slippage_bps = 50.
  }
;;

let validate t =
  let checks =
    [ Price.is_positive t.tick, "tick must be positive"
    ; Size.is_positive t.lot, "lot must be positive"
    ; Size.(t.order_size >= t.lot), "order_size must be at least one lot"
    ; t.levels >= 1 && t.levels <= 255, "levels must be in [1, 255]"
    ; Float.(t.base_half_spread_bps > 0.), "base_half_spread_bps must be positive"
    ; Float.(t.level_spacing_bps >= 0.), "level_spacing_bps must be non-negative"
    ; Float.(t.skew_bps >= 0.), "skew_bps must be non-negative"
    ; Size.is_positive t.max_position, "max_position must be positive"
    ; Usd.is_positive t.max_notional, "max_notional must be positive"
    ; ( Size.(abs t.inventory_target < t.max_position)
      , "inventory_target must be inside max_position" )
    ; Float.(t.requote_threshold_bps >= 0.), "requote_threshold_bps must be non-negative"
    ; t.requote_interval_ms > 0, "requote_interval_ms must be positive"
    ; t.order_ttl_ms > 0, "order_ttl_ms must be positive"
    ; Float.(t.gamma >= 0.), "gamma must be non-negative"
    ; t.vol_window >= 1, "vol_window must be positive"
    ; Float.(t.max_vol_bps >= 0.), "max_vol_bps must be non-negative"
    ; Usd.is_positive t.max_drawdown, "max_drawdown must be positive"
    ; t.max_data_age_ms > 0, "max_data_age_ms must be positive"
    ; Float.(t.flatten_slippage_bps > 0.), "flatten_slippage_bps must be positive"
    ]
  in
  match List.filter_map checks ~f:(fun (ok, msg) -> Option.some_if (not ok) msg) with
  | [] -> Ok t
  | errors -> Or_error.error_s [%message "invalid params" (errors : string list)]
;;
