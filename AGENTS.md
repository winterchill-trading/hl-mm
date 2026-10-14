# AGENTS.md (hl-mm)

## Purpose

The Hyperliquid side of the market maker: an adapter that implements the venue interface of
`mm-core` over `hl-client`, and the `hl-mm` executable that runs the quoting loop against
`hl-sim` or the Hyperliquid testnet. It refuses mainnet.

Workspace-wide rules, the repository map and the CI model are in
`../oxcaml-claude-skills/AGENTS.md`. Read that first.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `hl_mm` library: `Hl_venue` (the `Mm_core.Venue.S` adapter, unsigned and signed trading handles), conversions, tick rules ([lib/AGENTS.md](lib/AGENTS.md)) |
| `bin/` | The `hl-mm` executable: flags for the quoting loop, params file, run length ([bin/AGENTS.md](bin/AGENTS.md)) |
| `test/` | Integration tests against `hl-sim`, fault injection, the params file, and `must_fail/` compile-error pins ([test/AGENTS.md](test/AGENTS.md)) |
| `scripts/` | `e2e.sh`, the end-to-end run against a simulator |
| `.github/` | CI workflow ([.github/AGENTS.md](.github/AGENTS.md)) |
| `README.md` | Build, running, testnet, the adapter, end-to-end and example runs |

## Build and test

From this repository, inside the workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @hl-mm/all @hl-mm/runtest
```

For parallel work give the build its own directory, relative to the workspace root:
`DUNE_BUILD_DIR=_build-hl-mm` in front of the same command.

Standalone, with the published dependencies:

```sh
opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git
opam install . --deps-only --with-test
dune build && dune test
```

Format only this repository, after the tests pass:
`dune build --root .. @hl-mm/fmt --auto-promote`. Never run `dune fmt` at the workspace root.

## Conventions

- Core style: `open! Core`, an `.mli` for every module, labelled arguments, expect tests.
- The read-only handle and the trading handle are separate types. A call that places
  orders must take the trading handle; `must_fail/` pins that the read-only one is rejected
  at compile time. Keep that pin passing.
- Keep the strategy in `mm-core`. This repository holds only the Hyperliquid adapter and the
  binary.
- Every pinned tolerance or delay carries a comment saying what it protects against.
- Odoc on every public value.

## Dependencies and dependents

- Depends on `mm-core`, `hl-client`, `hl-protocol`, `market-data`, `exchange-core` and
  `fixed-decimal`; `order-book`, `exchange-core-engine` and `hl-sim` are test-only. The
  pin order is in `.github/workflows/ci.yml`.
- Spec: `../specs/repos/hl-mm.md`; the design is in `../specs/design/market-making.md`.

## CI

`.github/workflows/ci.yml` has two jobs. `build` runs the `ox-setup` action (the switch and
the pinned siblings, cached on the pins), then `dune build`, `dune test` and `shellcheck` on
`scripts/*.sh`. `obj-magic` calls the shared reusable workflow from `infra`.

Check a run with one `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- A quoting test must own the simulator's clock: warm the book first, then step the market
  only inside the maker's periodic account check. Otherwise a quote is priced on a stale book.
- "Post-only would cross" with an empty best bid and offer means the venue did not fill the
  BBO in the reject, not that the book is empty.
- Tests that read pushed books skip updates until the expected order shows up; pushes come
  at most every 20 ms.
- An unbounded `gamma * sigma^2` in the quoting formula blows up on one bad book print. The
  volatility estimate is capped; keep the cap when you touch it.
- Parallel agents share the `_build` lock, and an empty output file can mean another build
  held it. Re-run instead of trusting an empty result.

## Where to read more

- `README.md`, `../specs/repos/hl-mm.md`, `../specs/design/market-making.md`
- `../oxcaml-claude-skills/AGENTS.md` and `../oxcaml-claude-skills/GOTCHAS.md`
- Skill: `../oxcaml-claude-skills/skills/janestreet-ocaml-style`

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Point the binary at mainnet, or sign orders with a key that is not a throwaway testnet key.
- Publish, tag or release.
- Commit credentials. The testnet key comes from the environment (`HL_PRIVATE_KEY`) only.
- Print secrets, private keys or signatures.
