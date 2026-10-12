# hl-mm

Market maker for hl-sim

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core,
Async).

The strategy, risk checks and the live event loop live in
[mm-core](https://github.com/winterchill-trading/mm-core), which is venue-neutral. This
repository is the Hyperliquid side: `Hl_venue` implements `Mm_core.Venue.S` over
[hl-client](https://github.com/winterchill-trading/hl-client), and the `hl-mm`
executable runs `Mm_core.Live.Make (Hl_venue.Trading)` against
[hl-sim](https://github.com/winterchill-trading/hl-sim) (unsigned requests) or
Hyperliquid's testnet (requests signed with `HL_PRIVATE_KEY`). It refuses mainnet.

For one binary that runs the same strategy on Hyperliquid, Binance or Bybit, see
[market-maker](https://github.com/winterchill-trading/market-maker); it uses `Hl_venue`
from this repository's `hl-mm` library.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add -n fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git
opam pin add -n exchange-core https://github.com/winterchill-trading/exchange-core.git
opam pin add -n parquet https://github.com/winterchill-trading/parquet.git
opam pin add -n market-data https://github.com/winterchill-trading/market-data.git
opam pin add -n hl-protocol https://github.com/winterchill-trading/hl-protocol.git
opam pin add -n venue-net https://github.com/winterchill-trading/venue-net.git
opam pin add -n hl-client https://github.com/winterchill-trading/hl-client.git
opam pin add -n mm-core https://github.com/winterchill-trading/mm-core.git
opam pin add -n order-book https://github.com/winterchill-trading/order-book.git   # tests only
opam pin add -n exchange-core-engine https://github.com/winterchill-trading/exchange-core.git  # tests only
opam pin add -n hl-sim https://github.com/winterchill-trading/hl-sim.git           # tests only
opam install . --deps-only --with-test
dune build && dune test
```

CI pins the same packages in this order and runs `shellcheck scripts/*.sh`.

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## Running

```sh
dune exec hl-sim -- -port 3000 -seed 42      # in the hl-sim checkout
dune exec hl-mm -- -base-url http://localhost:3000 -run-for 60
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `-base-url` | `http://localhost:3000` | HTTP root; the websocket is `<url>/ws`; mainnet is refused |
| `-testnet` | off | trade on Hyperliquid's testnet, signing with the key in `HL_PRIVATE_KEY` |
| `-address` | `0x0000000000000000000000000000000000006d6d` (the key's with `-testnet`) | account to trade as (sent as `X-Address`) |
| `-coin` | `BTC` | coin to quote; asset index, tick and lot come from `meta` and the book |
| `-levels` | 3 | quote levels per side |
| `-size` | about 100 USD (0.001 BTC) | order size per level |
| `-half-spread-bps` | 3 | first level's distance from the reservation price |
| `-skew-bps` | 4 | reservation price shift at full inventory |
| `-max-position` | 10 x size | absolute position limit (max notional is 1.5x that at the mid) |
| `-requote-ms` | 1000 | requote and open-orders poll interval |
| `-max-actions-per-sec` | 100 | kill switch: more cancels and places than this in a second |
| `-soft-max-position` | none | beyond this position, stop quoting the side that grows it |
| `-params` | none | parameter overrides file, applied after the flags (see below) |
| `-run-for` | none | stop after N seconds, cancel all, print the report |
| `-summary-secs` | 10 | interval of the position/PnL/quotes summary log |
| `-log-level` | info | `debug`, `info`, `warn` or `error` |

`-params FILE` holds a sexp of `(field value)` pairs, any field of `Mm_core.Params.t`;
fields left out keep their value from the defaults and flags. The result goes through
`Params.validate`, so e.g. a `soft_max_position` above `max_position` or a zero
`max_actions_per_sec` stops hl-mm before it quotes:

```
((levels 5)
 (max_actions_per_sec 50)
 (soft_max_position (0.005)))
```

Logs go to stderr: every plan and fill (with running PnL) at `info`, a summary of mode,
book, position, PnL and resting quotes every `-summary-secs`, order updates at `debug`.
On SIGINT or SIGTERM (or after `-run-for`) it cancels every resting order on the coin and
prints the report to stdout, ending with the loop's tick-to-order latency (book update
to plan sent: count, p50, p99, max); a second SIGINT exits at once. The position is not
flattened on exit.

### Testnet

```sh
HL_PRIVATE_KEY=0x... dune exec hl-mm -- -testnet -run-for 60
```

Exchange requests are signed by hl-client's `Signing` (EIP-712 over the msgpack action
hash, testnet domain) and the account is the key's address. A run with a fresh, unfunded
key gets `User or API Wallet 0x... does not exist.` back for its first plan, naming the
key's own address, which shows the exchange recovered the right signer; nothing is placed.
Fund a testnet account from the faucet to quote for real. There is no mainnet switch.

### Hyperliquid adapter (`Hl_venue`)

- `Hl_venue` takes a bare `Hl_client.Config.t` and sends unsigned requests (hl-sim, and
  the `market-maker` binary). `Hl_venue.Trading` is the same venue over an hl-client
  `trading` handle (`Client.trading ?key config`), which signs every order and cancel
  when it holds a key. A `read_only` handle does not type-check as its config.

- `connect` fetches `meta` (asset indices), opens the websocket and subscribes to
  `orderUpdates(address)` and `userFills(address)`; `books` subscribes to `l2Book(coin)`.
  hl-client reconnects and resubscribes by itself and `Hl_venue` then runs the
  `on_reconnect` hooks, so the loop resyncs open orders and the account.
- Fill snapshots (sent on every (re)subscription) contribute only fills since connect,
  and fills are de-duplicated by trade id, as `Venue.S` requires.
- `openOrders` and `clearinghouseState` back `open_orders` and `account`; the
  clearinghouse becomes an `Account_view` (equity = account value). Timestamps go from
  milliseconds to nanoseconds.
- `instrument` returns the tick valid at the current mid (integers or 5 significant
  figures, at most `6 - szDecimals` decimals).
- `place` sends one `order` action; per-order errors are mapped back to `Reject_reason`
  by their wording (unknown wording becomes `Unsupported msg`). Market orders and client
  ids that are not 128-bit hex are rejected locally. `cancel` sends one `cancel` action;
  orders that were already gone are logged at debug, not errors.

The loop itself (polling, sequencing, coalescing, shutdown) is described in the mm-core
README.

### End to end

`scripts/e2e.sh` builds hl-sim and hl-mm, starts the simulator (seed 42) on a free port,
runs hl-mm with `-run-for 60`, prints the report and stops the simulator. It assumes
hl-mm is checked out inside a dune workspace next to `hl-sim`, `hl-client`,
`hl-protocol`, `venue-net`, `mm-core`, `fixed-decimal`, `order-book` and `exchange-core` (a parent
directory holding a `dune-workspace` file with `(lang dune 3.17)`), so everything builds
from source without opam pins. `OPAM_SWITCH`, `DUNE_BUILD_DIR`, `SEED`, `RUN_FOR`, `PORT`, `LOG_DIR` and
`RESPONSE_DELAY_MS` (hl-sim's `-response-delay-ms`, the delay of every `/exchange` ack)
override the defaults; extra arguments go to hl-mm. At the end it prints the most resting
quotes per side seen in a summary line; more than `-levels` would mean an order was placed
twice.

### Example run

```
$ scripts/e2e.sh
--- hl-mm report ---
elapsed          60.3s
fills            61 (61 maker)
volume           5996.9116 USD
realized pnl     0.1003 USD
unrealized pnl   0.0039 USD
fees             0.5997 USD
total pnl        -0.4954 USD
final position   -0.00009
last mid         99903.5
account value    999999.517 USD
plans            146
orders           410 placed, 1 rejected, 351 cancelled
  rejected    1 x post-only order would cross, bbo 99863@99884
reconnects       0
mode             Running
```

Without hl-mm the noise traders leave a book 25 to 35 bps wide, so the 3 bps quotes
sit at the top of the book and are taken by their market orders and by their resting
orders that the random walk leaves crossed. The PnL is mostly the 1 bp maker fee plus
adverse selection against that walk. Account value moves by about the total PnL; the
difference is the simulator marking positions at its reference price rather than the book
mid. Runs are not bit-for-bit reproducible: the seed fixes the noise flow, but the timing
of hl-mm's requests changes the matching.

With slow acks (`RESPONSE_DELAY_MS=300 scripts/e2e.sh -summary-secs 1`) the loop sends
fewer plans, since each one waits for its acks, but never holds more than three quotes a
side:

| ack delay | plans | placed | rejected | cancelled | fills | most resting (bids/asks) |
| --- | --- | --- | --- | --- | --- | --- |
| 0 ms | 147 | 405 | 1 | 343 | 64 | 3 / 3 |
| 300 ms | 81 | 257 | 6 | 218 | 44 | 3 / 3 |

The cancellation count comes from `canceled` order updates, so it also includes IOC
remainders. The account value is from the last clearinghouse snapshot that decoded: with
a tiny position on a large balance the simulator reports a `liquidationPx` with 11
integer digits, which fixed-decimal's parser rejects, and those snapshots are logged as
errors and skipped.

## Tests

`dune test` runs the conversion tests of `Hl_venue` (reject wording, order update
statuses, order requests) and an integration test (`test/test_live.ml`) that starts
`Hl_sim.Server` on a free port with a static book from a second account, runs
`Mm_core.Live.Make (Hl_venue)` until it quotes the expected ladder, sends a taker order
into the best bid, checks the maker fill reaches the inventory, then stops and checks that
no orders are left resting. A second run delays every `/exchange` ack by 500 ms (longer
than the 200 ms requote interval) while the orders rest at once, moves the book to force a
requote, and checks that the ladder still has exactly one order per level.

`test/test_live_bugs.ml` runs the loop through `Bugged_venue.Make (Hl_venue)`, a fault
injecting wrapper in the style of mm-core's memory venue, against hl-sim with slow acks:
seeded local rejects (the rejected levels are placed again, never doubled) and a `place`
that times out while its orders rest (they are adopted from the next snapshot, not placed
again). `test/test_trading.ml` runs the loop over `Hl_venue.Trading` with a throwaway
key against hl-sim with a request journal, and recovers the signer of every journaled
order and cancel from its signature. `test/must_fail` compiles a call of
`Hl_venue.Trading.connect` with a read-only handle and pins the type error.
`test/test_params_file.ml` covers the params file and its validation. The strategy's own tests are in mm-core.

## Modules

| Module | Description |
| --- | --- |
| `Hl_mm.Params_file` | `-params` overrides: apply a `(field value)` sexp to `Mm_core.Params.t` and validate |
| `Hl_mm.Hl_venue` | `Mm_core.Venue.S` over hl-client, with `config = Hl_client.Config.t` (unsigned); `Trading` with `config = Hl_client.Client.trading Hl_client.Client.t` (signed); `tick_of_mid`; pure `Convert` functions |

Strategy, parameters and their defaults: see
[mm-core](https://github.com/winterchill-trading/mm-core).
