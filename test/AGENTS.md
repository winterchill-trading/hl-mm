# test/ (AGENTS.md)

Integration tests run the loop against `Hl_sim.Server` on a free port with a static book, a
fault-injecting venue (`Bugged_venue`), signed trading against a request journal, and the
params file. `must_fail/` holds a compile-error pin: `read_only_venue.ml` must fail with the
output in `read_only_venue.expected`.

- Promote expect output with `dune promote` only after reading each diff.
- Do not delete a `must_fail` case to make a build pass; fix the interface it guards.
- Run from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-mm/runtest`.
