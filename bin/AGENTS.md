# bin/ (AGENTS.md)

The `hl-mm` executable. Flags (`-base-url`, `-testnet`, `-address`, `-coin`, levels, size,
spread, skew, position limits, action rate, requote interval, run length, log level) and the
params file (`-params`) are in the root `README.md`; keep the two in step.

Build and run from the repository root:
`opam exec --switch 5.2.0+ox -- dune exec hl-mm -- -help`.

Rules that matter here:

- A new flag gets a default, a README line and a validation test in `test/`.
- The run ends by itself with `-run-for`; use it in scripts so no run is left resting.
