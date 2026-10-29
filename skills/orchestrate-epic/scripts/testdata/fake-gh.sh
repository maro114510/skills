#!/usr/bin/env bash
# A stand-in for gh that answers oe's reads and writes from a test's GitHub state.
#
# - OE_GITHUB names the state file that the test writes.
# - fake-github.jq turns the state into the response GitHub would send to a read.
# - fake-github-write.jq applies a write to the state, and this script saves the new state.
# - The --jq filter is then applied to that response, as gh applies it.
# - A call whose arguments contain GH_FAIL fails as if GitHub were down, and changes nothing.
# - OE_GITHUB_NEXT, when set, names a state file that replaces the state at the second Epic read.
#   It models GitHub changing between two oe ready runs, at a point the test controls.
#
# | gh call | Answered as |
# |---|---|
# | api graphql with the Epic query | epic |
# | api graphql with num=N | issue N |
# | api repos/o/r/pulls | pulls |
# | api repos/o/r/commits/SHA/statuses | statuses SHA |
# | api repos/o/r/activity with ref=refs/heads/BRANCH | activity BRANCH |
# | api repos/o/r | repo |
# | api repos/o/r/git/ref/heads/BRANCH | ref BRANCH |
# | api repos/o/r/issues/N/comments | comments N |
# | api -X POST repos/o/r/git/refs | the write create_ref |
# | api -X POST repos/o/r/issues/N/comments | the write comment N, where N is an Issue or a pull request |
# | api -X POST repos/o/r/statuses/SHA | the write status SHA |
set -uo pipefail

args="$*"
if [[ -n "${GH_FAIL:-}" && "${args}" == *"${GH_FAIL}"* ]]; then
  echo "gh: HTTP 502" >&2
  exit 1
fi

filter="." path="" query="" num="" method=GET fields="{}"
while [[ $# -gt 0 ]]; do
  case "$1" in
  api) ;;
  --jq) filter="$2" && shift ;;
  -X | --method) method="$2" && shift ;;
  -f | -F)
    case "$2" in
    query=*) query="${2#query=}" ;;
    num=*) num="${2#num=}" ;;
    *) ;;
    esac
    fields="$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '. + {($k): $v}' <<<"${fields}")"
    shift
    ;;
  *) [[ -n "${path}" ]] || path="$1" ;;
  esac
  shift
done

here="$(dirname "${BASH_SOURCE[0]}")"
unexpected() {
  echo "fake gh: unexpected call: ${args}" >&2
  exit 99
}

if [[ "${method}" == POST ]]; then
  case "${path}" in
  */git/refs) call=create_ref arg="" ;;
  */issues/*/comments)
    n="${path#*/issues/}"
    call=comment arg="${n%%/*}"
    ;;
  */statuses/*) call=status arg="${path##*/statuses/}" ;;
  *) unexpected ;;
  esac
  result="$(jq -n --argjson state "$(cat "${OE_GITHUB}")" --arg call "${call}" --arg arg "${arg}" \
    --argjson fields "${fields}" -f "${here}/fake-github-write.jq")" || exit 99
  if [[ "$(jq -r '.error // empty' <<<"${result}")" != "" ]]; then
    echo "gh: $(jq -r .error <<<"${result}")" >&2
    exit 1
  fi
  jq '.state' <<<"${result}" >"${OE_GITHUB}"
  jq '.response' <<<"${result}" | jq -r "${filter}"
  exit
fi
[[ "${method}" == GET ]] || unexpected

case "${path}" in
graphql)
  if [[ "${query}" == *subIssues* ]]; then
    call=epic arg=""
    if [[ -n "${OE_GITHUB_NEXT:-}" ]]; then
      reads=$(($(cat "${OE_GITHUB}.reads" 2>/dev/null || echo 0) + 1))
      echo "${reads}" >"${OE_GITHUB}.reads"
      [[ "${reads}" -ne 2 ]] || cp "${OE_GITHUB_NEXT}" "${OE_GITHUB}"
    fi
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
*/git/ref/heads/*) call=ref arg="${path#*/git/ref/heads/}" ;;
*/issues/*/comments*)
  n="${path#*/issues/}"
  call=comments arg="${n%%/*}"
  ;;
repos/o/r) call=repo arg="" ;;
*) unexpected ;;
esac

jq -n --argjson state "$(cat "${OE_GITHUB}")" --arg call "${call}" --arg arg "${arg}" \
  -f "${here}/fake-github.jq" | jq -r "${filter}"
