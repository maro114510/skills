#!/usr/bin/env bash
# oe attempt
#
# Records an Owner attempt on this host before the Owner starts, and refuses once max_attempts are used.
# It counts attempts as oe ready does, so the Owner it admits is one that oe ready still allows.
#
# Usage
#
#   oe attempt <owner/repo> <issue-number>
#
# Counting
#
# - Records come from the record store that oe-store.sh defines.
# - Only attempt records after the latest claim record count.
# - Every attempt record counts when there is no claim record.
#
# Output
#
# - On success, one line holding attempt, its number, and max_attempts, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | The attempt record was written | The attempt record |
# | 1 | The record store could not be read or written | Nothing |
# | 2 | The arguments are invalid | Nothing |
# | 4 | max_attempts attempts are already used | Nothing |
#
# Two sessions never write for one Epic at once, because oe lock admits one, so reading and then writing does not race.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe attempt <owner/repo> <issue-number>" >&2
  exit 2
}

fail() {
  echo "oe attempt: $1" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <issue-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

at="$(record_now 2>"${err}")" || usage "$(head -n1 "${err}")"
records="$(records_read "${repo}" "${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
used="$(jq -r '(map(.kind == "claim") | rindex(true)) as $claim
  | [.[($claim // -1) + 1:][] | select(.kind == "attempt")] | length' <<<"${records}")" ||
  fail "cannot count the attempts of Issue #${n}"

if ((used >= max_attempts)); then
  echo "oe attempt: Issue #${n} already used ${used} of ${max_attempts} attempts since its claim" >&2
  exit 4
fi

records_add "${repo}" "${n}" '{"kind":"attempt","at":"'"${at}"'"}' 2>"${err}" ||
  fail "recording the attempt of Issue #${n} failed: $(head -n1 "${err}")"
printf 'attempt\t%s\t%s\n' "$((used + 1))" "${max_attempts}"
