#!/usr/bin/env bash
# End-to-end run: starts the hl-sim simulator (seeded) on a free port, runs hl-mm against
# it for RUN_FOR seconds, prints hl-mm's final report and stops the simulator.
#
# Assumed layout: hl-mm is checked out next to its sibling repositories inside one dune
# workspace, so dune builds hl-sim and the libraries from source without opam pins:
#
#   <root>/dune-workspace      (lang dune 3.17)
#   <root>/dune-project        (lang dune 3.17)
#   <root>/hl-mm  <root>/hl-sim  <root>/hl-client  <root>/hl-protocol  <root>/venue-net
#   <root>/fixed-decimal  <root>/order-book  <root>/exchange-core  <root>/mm-core
#
# Environment overrides: OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR (<root>/_build-hl-mm),
# SEED (42), RUN_FOR (60), PORT (a free port), LOG_DIR (a temporary directory),
# RESPONSE_DELAY_MS (0: hl-sim's delay of every /exchange ack, to test slow acks).
# Extra arguments are passed to hl-mm, e.g. scripts/e2e.sh -half-spread-bps 2.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cd "$repo/.." && pwd)"
for dep in hl-sim hl-client hl-protocol venue-net fixed-decimal order-book exchange-core mm-core; do
  if [[ ! -d "$root/$dep" ]]; then
    echo "e2e: $root/$dep is missing; clone it next to hl-mm (see the header of $0)" >&2
    exit 1
  fi
done
if [[ ! -f "$root/dune-workspace" && ! -f "$root/dune-project" ]]; then
  echo "e2e: $root is not a dune workspace root; create $root/dune-workspace with" >&2
  echo "     '(lang dune 3.17)' (see the header of $0)" >&2
  exit 1
fi

switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-hl-mm}"
seed="${SEED:-42}"
run_for="${RUN_FOR:-60}"
response_delay_ms="${RESPONSE_DELAY_MS:-0}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hl-mm-e2e.XXXXXX")}"
mkdir -p "$log_dir"

echo "e2e: building hl-sim and hl-mm (switch $switch, build dir $DUNE_BUILD_DIR)" >&2
(cd "$root" && opam exec --switch "$switch" -- \
  dune build --root . hl-sim/bin/main.exe "$(basename "$repo")/bin/main.exe")
build="$DUNE_BUILD_DIR/default"
sim_exe="$build/hl-sim/bin/main.exe"
mm_exe="$build/$(basename "$repo")/bin/main.exe"

port="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"

sim_pid=""
cleanup() {
  if [[ -n "$sim_pid" ]] && kill -0 "$sim_pid" 2>/dev/null; then
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "e2e: starting hl-sim on port $port (seed $seed, ack delay ${response_delay_ms}ms)," \
  "log $log_dir/sim.log" >&2
"$sim_exe" -port "$port" -seed "$seed" -response-delay-ms "$response_delay_ms" \
  >"$log_dir/sim.log" 2>&1 &
sim_pid=$!

for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$port/info" -d '{"type":"meta"}' >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$sim_pid" 2>/dev/null; then
    echo "e2e: hl-sim exited early:" >&2
    cat "$log_dir/sim.log" >&2
    exit 1
  fi
  sleep 0.2
done
# Let the noise traders build a two-sided book.
sleep 2

echo "e2e: running hl-mm for ${run_for}s, log $log_dir/mm.log" >&2
"$mm_exe" -base-url "http://127.0.0.1:$port" -run-for "$run_for" "$@" 2>"$log_dir/mm.log"
echo "e2e: hl-mm log: $(grep -c ' fill ' "$log_dir/mm.log" || true) fill lines," \
  "$(grep -c 'plan #' "$log_dir/mm.log" || true) plans; logs in $log_dir" >&2
