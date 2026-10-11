# hl-mm

Market maker for hl-sim

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core, Async).

The strategy core is pure: no networking, no clocks, no randomness. Every function takes
the current time and exchange data as arguments, so the same code runs under tests and
under the live event loop (`Live`), which connects it to an exchange through
[hl-client](https://github.com/winterchill-trading/hl-client). The `hl-mm` executable
runs it against [hl-sim](https://github.com/winterchill-trading/hl-sim) or any
Hyperliquid-compatible API that accepts unsigned requests.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add -n fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git
opam pin add -n hl-protocol https://github.com/winterchill-trading/hl-protocol.git
opam pin add -n hl-client https://github.com/winterchill-trading/hl-client.git
opam pin add -n order-book https://github.com/winterchill-trading/order-book.git   # tests only
opam pin add -n hl-sim https://github.com/winterchill-trading/hl-sim.git           # tests only
opam install . --deps-only --with-test
dune build && dune test
```

## Running

```sh
dune exec hl-sim -- -port 3000 -seed 42      # in the hl-sim checkout
dune exec hl-mm -- -base-url http://localhost:3000 -run-for 60
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `-base-url` | `http://localhost:3000` | HTTP root; the websocket is `<url>/ws` |
| `-address` | `0x0000000000000000000000000000000000006d6d` | account to trade as (sent as `X-Address`) |
| `-coin` | `BTC` | coin to quote; asset index, tick and lot come from `meta` and the book |
| `-levels` | 3 | quote levels per side |
| `-size` | about 100 USD (0.001 BTC) | order size per level |
| `-half-spread-bps` | 3 | first level's distance from the reservation price |
| `-skew-bps` | 4 | reservation price shift at full inventory |
| `-max-position` | 10 x size | absolute position limit (max notional is 1.5x that at the mid) |
| `-requote-ms` | 1000 | requote and open-orders poll interval |
| `-run-for` | none | stop after N seconds, cancel all, print the report |
| `-summary-secs` | 10 | interval of the position/PnL/quotes summary log |
| `-log-level` | info | `debug`, `info`, `warn` or `error` |

Logs go to stderr: every plan and fill (with running PnL) at `info`, a summary of mode,
book, position, PnL and resting quotes every `-summary-secs`, order updates at `debug`.
On SIGINT or SIGTERM (or after `-run-for`) it cancels every resting order on the coin and
prints the report to stdout; a second SIGINT exits at once. The position is not
flattened on exit.

### Live loop

- Websocket subscriptions `l2Book(coin)`, `orderUpdates(address)` and
  `userFills(address)` feed `Strategy.on_book` and `Strategy.on_fill`. Fill snapshots
  (sent on every (re)subscription) are applied only for fills since start; fills are
  de-duplicated by trade id.
- `openOrders` and `clearinghouseState` are polled over HTTP every `-requote-ms`, after
  every executed plan (the strategy waits for that snapshot before placing again), when
  an order update reports an order leaving the book, and after a websocket reconnect
  (hl-client reconnects and resubscribes by itself).
- `Strategy.tick` runs after every book update, fill and poll. A plan becomes at most two
  requests: one `cancel` action with all cancels, then one `order` action with all
  places.
- Ticks, plan execution and polls run one at a time on an Async sequencer, so a snapshot
  never predates a plan the strategy already sent. Requests are coalesced: at most one
  tick and one poll wait in the queue.

### End to end

`scripts/e2e.sh` builds hl-sim and hl-mm, starts the simulator (seed 42) on a free port,
runs hl-mm with `-run-for 60`, prints the report and stops the simulator. It assumes
hl-mm is checked out inside a dune workspace next to `hl-sim`, `hl-client`,
`hl-protocol`, `fixed-decimal` and `order-book` (a parent directory holding a
`dune-workspace` file with `(lang dune 3.17)`), so everything builds from source without
opam pins. `OPAM_SWITCH`, `DUNE_BUILD_DIR`, `SEED`, `RUN_FOR`, `PORT` and `LOG_DIR`
override the defaults; extra arguments go to hl-mm.

### Example run

```
$ scripts/e2e.sh
--- hl-mm report ---
elapsed          60.3s
fills            72 (72 maker)
volume           6956.3115 USD
realized pnl     -0.3024 USD
unrealized pnl   -0.0063 USD
fees             0.6956 USD
total pnl        -1.0043 USD
final position   0.00152
last mid         99886.5
account value    999999.0299 USD
plans            151
orders           434 placed, 1 rejected, 366 cancelled
  rejected    1 x Post only order would have immediately matched, bbo was 99941@99950. asset=0
ws reconnects    0
mode             Running
```

Without hl-mm the noise traders leave a book 25 to 35 bps wide, so the 3 bps quotes
sit at the top of the book and are taken by their market orders and by their resting
orders that the random walk leaves crossed. The PnL is mostly the 1 bp maker fee plus
adverse selection against that walk. Account value moves by about the total PnL; the
difference is the simulator marking positions at its reference price rather than the book
mid. Runs are not bit-for-bit reproducible: the seed fixes the noise flow, but the timing
of hl-mm's requests changes the matching.

## Tests

`dune test` runs the strategy's expect and quickcheck tests and an integration test
(`test/test_live.ml`) that starts `Hl_sim.Server` on a free port with a static book from
a second account, runs `Live` until it quotes the expected ladder, sends a taker order
into the best bid, checks the maker fill reaches the inventory, then stops and checks
that no orders are left resting.

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
| `Live` | Async event loop over hl-client: websocket feeds, HTTP polls, plan execution, shutdown and the run report |

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
