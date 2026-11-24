#!/usr/bin/env bash
# Runs every bats suite under skills/ and tests/, one bats process per file, and exits 1 naming each failing file.
# Usage: tests/run-bats.sh, with BATS_JOBS files at a time, by default the CPU count.
# Files run through xargs -P, not bats --jobs, because bats --jobs needs GNU parallel.
# Tests within a file stay serial: no single file dominates the run, and splitting further risks order dependence.
set -euo pipefail

cd "$(dirname "$0")/.."
jobs="${BATS_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
logs="$(mktemp -d)"
trap 'rm -rf "${logs}"' EXIT
export BATS_RUN_LOGS="${logs}"

# run_one <file>: runs one suite into its own log, so parallel output never interleaves.
# shellcheck disable=SC2329 # xargs calls it through bash -c.
run_one() {
  local log
  log="${BATS_RUN_LOGS}/$(printf '%s' "$1" | tr / _).log"
  if bats "$1" >"${log}" 2>&1; then
    echo "ok $1"
  else
    echo "$1" >>"${BATS_RUN_LOGS}/failed"
  fi
}
export -f run_one

# shellcheck disable=SC2016 # $1 expands in the bash -c child, not here.
find skills tests -name '*.bats' -print0 | sort -z | xargs -0 -n 1 -P "${jobs}" bash -c 'run_one "$1"' _

[[ -s "${logs}/failed" ]] || exit 0
while IFS= read -r file; do
  cat "${logs}/$(printf '%s' "${file}" | tr / _).log"
done <"${logs}/failed"
sort "${logs}/failed" | sed 's/^/FAIL /'
exit 1
