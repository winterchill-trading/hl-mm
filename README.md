# hl-mm

Market maker for hl-sim

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core, Async).

This repository holds the pure strategy core: no networking, no clocks, no randomness.
Every function takes the current time and exchange data as arguments, so the same code
runs under tests and under a live event loop.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add -n fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git
opam pin add -n hl-protocol https://github.com/winterchill-trading/hl-protocol.git
opam pin add -n hl-client https://github.com/winterchill-trading/hl-client.git
opam install . --deps-only --with-test
dune build && dune test
```

## Modules

All modules live under `Hl_mm` and use the wire types of
[hl-protocol](https://github.com/winterchill-trading/hl-protocol) (`Price`, `Size`, `Usd`,
`L2_book`, `Open_order`, `User_fill`, `Clearinghouse_state`, `Order_request`, ...).

| Module | Description |
| --- | --- |
| `Params` | Strategy parameters and BTC defaults (`Params.btc`), with `validate` |
| `Market_state` | Last book, mid, microprice and EWMA volatility of mid returns |
| `Inventory` | Position, average entry, realized/unrealized PnL and fees from fills, synced from clearinghouse snapshots |
| `Quote` | One desired order: side, level, price, size |
| `Quoter` | Pure `quote : Params.t -> Market_state.t -> Inventory.t -> Quote.t list` |
| `Action` | `Keep oid \| Cancel oid \| Place Order_request.t` |
| `Reconciler` | Minimal plan from resting orders to the desired ladder; deterministic cloids |
| `Risk` | Kill switch (`Ok \| Halt reason`) and the flatten plan |
| `Strategy` | State machine: `on_book`, `on_fill`, `on_open_orders`, `on_clearinghouse`, `tick ~now` |

## Strategy

The quoter is a simplified Avellaneda-Stoikov market maker. All spreads are in basis
points (bps) of the price.

### Market inputs

```
mid         = (best_bid + best_ask) / 2
microprice  = (best_bid * ask_size + best_ask * bid_size) / (bid_size + ask_size)
r_k         = ln(mid_k / mid_(k-1))                      on each two-sided book
var_k       = (1 - a) * var_(k-1) + a * r_k^2,  a = 2 / (vol_window + 1)
sigma       = min(10_000 * sqrt(var), max_vol_bps)       per-update volatility, bps
```

### Ladder

```
cap   = min(max_position, max_notional / mid)            position capacity, base units
q     = clamp((position - inventory_target) / cap, -1, 1)
v     = gamma * sigma^2                                  risk term, bps
r     = microprice * (1 - q * (skew_bps + v) / 10_000)   reservation price
delta = base_half_spread_bps + v / 2                     half-spread, bps
d_i   = delta + i * level_spacing_bps                    level i = 0 .. levels-1

bid_i = floor_tick(r * (1 - d_i / 10_000))   capped at best_ask - tick and bid_(i-1) - tick
ask_i = ceil_tick (r * (1 + d_i / 10_000))   floored at best_bid + tick and ask_(i-1) + tick
```

When long (`q > 0`) both sides move down: the bid backs away and the ask gets more
aggressive, and vice versa when short. Higher volatility widens the spread and
strengthens the skew.

Sizes are `order_size` per level, truncated to the lot, handed out from level 0 until the
room on that side runs out:

```
room_bid = cap - position
room_ask = cap + position
```

so a side at the limit gets no quotes, and filling every quote never takes the position
beyond `cap <= max_position`. A property test checks that quotes never cross (each other
or the book) and never breach the limit.

### Reconciliation

Each desired quote keeps the closest resting order on the same side with exactly its size,
within `requote_threshold_bps` of its price and younger than `order_ttl_ms`. Unmatched
resting orders are cancelled; unmatched quotes are placed as post-only (`Alo`) limit
orders. Client order ids encode `coin (8 bytes) | side (1) | level (1) | generation (6)`,
so they are reproducible and readable.

### Risk

| Check | Halt | Response |
| --- | --- | --- |
| `abs(position) > max_position` | sticky | cancel all, reduce-only IOC for the whole position at `mid -/+ flatten_slippage_bps` |
| `peak_pnl - pnl > max_drawdown`, `pnl = realized + unrealized(mid) - fees` | sticky | same |
| no two-sided book | until data | cancel all |
| `now - book_time > max_data_age_ms` | until data | cancel all |

### Strategy loop

`tick ~now` folds the above together. It requotes when the last plan is older than
`requote_interval_ms`, the mid moved by `requote_threshold_bps`, or the position changed.
After sending a plan it waits for an open-orders snapshot (up to `requote_interval_ms`)
before planning again, and without one it only cancels, so orders are never placed twice.

### Inventory accounting

Average cost: fills that grow the position move the entry to the size-weighted mean;
fills that reduce it realize `closed * (px - entry) * sign(position)`; a fill that flips
the position reopens the remainder at the fill price. A clearinghouse snapshot overwrites
position and entry; fills at or before the snapshot time then add only their fee and the
exchange's `closedPnl`. Fills are de-duplicated by trade id.

### Defaults (`Params.btc`)

| Parameter | Value |
| --- | --- |
| tick / lot | 1 / 0.00001 |
| order size x levels | 0.001 x 3 |
| base half-spread / level spacing | 3 bps / 2 bps |
| skew / gamma / max vol | 4 bps / 0.5 / 10 bps |
| max position / max notional | 0.01 BTC / 1500 USD |
| requote threshold / interval / order ttl | 1 bps / 1 s / 60 s |
| max drawdown / max data age / flatten slippage | 50 USD / 5 s / 50 bps |
