#!/usr/bin/env bash
# A stand-in for gh that answers oe ready's reads from a test's GitHub state.
#
# - OE_GITHUB names the state file that the test writes.
# - fake-github.jq turns the state into the response GitHub would send.
# - The --jq filter is then applied to that response, as gh applies it.
# - A call whose arguments contain GH_FAIL fails as if GitHub were down.
#
# | gh call | Answered as |
# |---|---|
# | api graphql with the Epic query | epic |
# | api graphql with num=N | issue N |
# | api repos/o/r/pulls | pulls |
# | api repos/o/r/commits/SHA/statuses | statuses SHA |
# | api repos/o/r/activity with ref=refs/heads/BRANCH | activity BRANCH |
set -uo pipefail

args="$*"
if [[ -n "${GH_FAIL:-}" && "${args}" == *"${GH_FAIL}"* ]]; then
  echo "gh: HTTP 502" >&2
  exit 1
fi

filter="." path="" query="" num=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  api) path="$2" && shift ;;
  --jq) filter="$2" && shift ;;
  -f | -F)
    case "$2" in
    query=*) query="${2#query=}" ;;
    num=*) num="${2#num=}" ;;
    *) ;;
    esac
    shift
    ;;
  *) ;;
  esac
  shift
done

case "${path}" in
graphql)
  if [[ "${query}" == *subIssues* ]]; then
    call=epic arg=""
  else
    call=issue arg="${num}"
  fi
  ;;
*/pulls\?*) call=pulls arg="" ;;
*/statuses*)
  sha="${path#*/commits/}"
  call=statuses arg="${sha%%/*}"
  ;;
*/activity\?*)
  ref="${path#*ref=refs/heads/}"
  call=activity arg="${ref%%&*}"
  ;;
*)
  echo "fake gh: unexpected call: ${args}" >&2
  exit 99
  ;;
esac

jq -n --argjson state "$(cat "${OE_GITHUB}")" --arg call "${call}" --arg arg "${arg}" \
  -f "$(dirname "${BASH_SOURCE[0]}")/fake-github.jq" | jq -r "${filter}"
