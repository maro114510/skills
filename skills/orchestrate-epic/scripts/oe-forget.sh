#!/usr/bin/env bash
# oe forget
#
# Drops an Epic's records from this host once every child Issue is closed.
# It refuses while one is open, because dropping its records would reset its attempt cap.
#
# Usage
#
#   oe forget <owner/repo> <epic-number>
#
# - Only the records of child Issues in <owner/repo> are dropped, because records are keyed by repository and Issue.
#
# Output
#
# - On success, forgot and the number of child Issues dropped, separated by a tab.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | Every child Issue is closed, and its records are gone | The records of the child Issues |
# | 1 | The GitHub read or the record store failed | Nothing, or the records dropped before stderr's failure |
# | 2 | The arguments are invalid | Nothing |
# | 4 | A child Issue is still open | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe forget <owner/repo> <epic-number>" >&2
  exit 2
}

fail() {
  echo "oe forget: $1" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
repo="$1"
epic="$2"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

# One line per child Issue: its number, its state, and whether it lives in this repository.
children="$(gh api "repos/${repo}/issues/${epic}/sub_issues?per_page=100" --paginate --jq '.[]
  | "\(.number)\t\(.state)\t\((.repository_url // "" | ascii_downcase) == ("https://api.github.com/repos/'"${repo}"'" | ascii_downcase))"' \
  2>"${err}")" || fail "child Issue read of Epic #${epic} failed: $(head -n1 "${err}")"

mine=()
open=()
while IFS=$'\t' read -r n state here; do
  [[ -n "${n}" ]] || continue
  [[ "${n}" =~ ^[1-9][0-9]*$ && "${state}" =~ ^(open|closed)$ && "${here}" =~ ^(true|false)$ ]] ||
    fail "child Issue read of Epic #${epic} unreadable"
  [[ "${state}" == closed ]] || open+=("#${n}")
  [[ "${here}" == false ]] || mine+=("${n}")
done <<<"${children}"

if [[ ${#open[@]} -gt 0 ]]; then
  echo "oe forget: ${open[*]} of Epic #${epic} still open, so nothing was dropped" >&2
  exit 4
fi

for n in ${mine[@]+"${mine[@]}"}; do
  records_drop "${repo}" "${n}" 2>"${err}" || fail "dropping the records of Issue #${n} failed: $(head -n1 "${err}")"
done
printf 'forgot\t%s\n' "${#mine[@]}"
