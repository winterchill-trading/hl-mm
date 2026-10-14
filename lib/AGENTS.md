# lib/ (AGENTS.md)

The `hl_mm` library. `Hl_venue` implements `Mm_core.Venue.S` over `hl-client`; `Hl_venue.Trading`
is the signing handle. The pure `Convert` functions turn reject wording, order statuses and
requests into venue types. `tick_of_mid` rounds to five significant figures and at most
`6 - szDecimals` decimals.

Build from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-mm/all`.

Rules that matter here:

- Conversions are pure and tested on their own; keep them free of I/O.
- Anything that signs goes through `Trading`. The read-only path must not gain a signer.
- Keep the mainnet guard in the adapter's constructor path; do not add a bypass.
