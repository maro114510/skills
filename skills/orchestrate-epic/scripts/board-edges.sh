#!/usr/bin/env bash
# Reads the open blockedBy edges of every open Tn of an Epic and of every open Tn.m under a
# container Tn, commands §1 call 2. gh fetches the raw board and jq filters it as a separate
# process, since `gh --jq` takes one expression and rejects jq flags such as --argjson.
# Usage: board-edges.sh <owner/repo> <epic> [containers]       query GitHub, then filter
#        board-edges.sh --snapshot <file|-> <epic> [containers] filter a saved `gh issue list` response
# containers is a JSON array of container Tn numbers, from call 1; it defaults to [].
# BOARD_EDGES_LIMIT overrides gh's --limit, 200 by default, when the cross-check finds a truncated page.
# Output: one JSON array, [{n:<issue>, b:[<open blocker>...]}...], on stdout.
# Exit: 0 read, 1 the board could not be read (nothing on stdout; never classify), 2 usage error.
set -uo pipefail

LIMIT="${BOARD_EDGES_LIMIT:-200}"

usage() {
  echo "$1" >&2
  echo "Usage: board-edges.sh <owner/repo> <epic> [containers] | --snapshot <file|-> <epic> [containers]" >&2
  exit 2
}

fail() {
  echo "board-edges: $1 — stop and report, do not classify" >&2
  exit 1
}

SNAPSHOT=""
if [[ "${1:-}" == "--snapshot" ]]; then
  [[ $# -ge 3 && $# -le 4 ]] || usage "--snapshot needs <file|-> <epic> [containers]"
  SNAPSHOT="$2"
  REPO=""
  shift 2
else
  [[ $# -ge 2 && $# -le 3 ]] || usage "expected <owner/repo> <epic> [containers]"
  REPO="$1"
  [[ "${REPO}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage "repo must be owner/repo: ${REPO}"
  shift
fi
EPIC="$1"
CONTAINERS="${2:-[]}"
command -v jq >/dev/null || fail "jq not found"
[[ "${EPIC}" =~ ^[1-9][0-9]*$ ]] || usage "epic must be a positive integer: ${EPIC}"
[[ "${LIMIT}" =~ ^[1-9][0-9]*$ ]] || usage "BOARD_EDGES_LIMIT must be a positive integer: ${LIMIT}"
jq -e 'type == "array" and all(.[]; type == "number")' <<<"${CONTAINERS}" >/dev/null 2>&1 ||
  usage "containers must be a JSON array of numbers: ${CONTAINERS}"

if [[ -n "${SNAPSHOT}" ]]; then
  if [[ "${SNAPSHOT}" == "-" ]]; then
    BOARD=$(cat) || fail "snapshot read failed"
  else
    BOARD=$(cat -- "${SNAPSHOT}") || fail "snapshot read failed"
  fi
else
  BOARD=$(gh issue list --repo "${REPO}" --state open --limit "${LIMIT}" \
    --json number,blockedBy,parent) || fail "gh issue list failed"
fi

# A missing or truncated blockedBy connection is unreadable, never "no dependencies".
# shellcheck disable=SC2016 # jq program, not shell expansion.
FILTER='
  if type != "array" then error("board is not an array") else . end
  | [.[]
     | (.parent.number // null) as $p
     | select($p != null and ($p == $epic or any($containers[]; . == $p)))
     | if (.blockedBy.nodes | type) != "array" then error("#\(.number) blockedBy missing")
       elif (.blockedBy.totalCount // 0) > (.blockedBy.nodes | length) then error("#\(.number) blockedBy truncated")
       else . end
     | {n: .number, b: [.blockedBy.nodes[] | select(.state == "OPEN") | .number]}]'
# -e fails an empty response, which yields no JSON value, instead of printing a blank line.
EDGES=$(jq -ce --argjson epic "${EPIC}" --argjson containers "${CONTAINERS}" "${FILTER}" <<<"${BOARD}") ||
  fail "board filter failed"
printf '%s\n' "${EDGES}"
