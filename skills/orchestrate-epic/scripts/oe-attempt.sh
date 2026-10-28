#!/usr/bin/env bash
# oe attempt
#
# Writes an attempt record on an Issue before an Owner starts, and refuses once max_attempts are used.
# It counts attempts as oe ready does, so the Owner it admits is one that oe ready still allows.
#
# Usage
#
#   oe attempt <owner/repo> <issue-number>
#
# Counting
#
# - Records follow oe-records.jq: a trusted author and the record's marker.
# - Only attempt records after the latest claim record count.
# - Every attempt record counts when there is no claim record.
#
# Output
#
# - On success, one line holding attempt, its number, and max_attempts, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The attempt record was written | The attempt record |
# | 1 | A GitHub read or write failed | Nothing |
# | 2 | The arguments are invalid | Nothing |
# | 4 | max_attempts attempts are already used | Nothing |
#
# Two sessions never write for one Epic at once, because oe lock admits one, so reading and then writing does not race.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${dir}/oe-config.sh"

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

records="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

# Every comment, oldest first, reduced to the record it is: claim, attempt, or other.
kinds="$(gh api "repos/${repo}/issues/${n}/comments?per_page=100" --paginate --jq "${records}"'
  .[] | {authorAssociation: .author_association, body}
  | if record("claim") then "claim" elif record("attempt") then "attempt" else "other" end' 2>"${err}")" ||
  fail "comment read on Issue #${n} failed: $(head -n1 "${err}")"

used=0
while read -r kind; do
  case "${kind}" in
  claim) used=0 ;;
  attempt) used=$((used + 1)) ;;
  other | "") ;;
  *) fail "comment read on Issue #${n} unreadable" ;;
  esac
done <<<"${kinds}"

# shellcheck disable=SC2154 # oe-config.sh assigns max_attempts.
if ((used >= max_attempts)); then
  echo "oe attempt: Issue #${n} already used ${used} of ${max_attempts} attempts since its claim" >&2
  exit 4
fi

next=$((used + 1))
body="$(record_marker attempt)"$'\n'"Owner attempt ${next} of ${max_attempts}."
gh api -X POST "repos/${repo}/issues/${n}/comments" -f body="${body}" --jq '.html_url' >/dev/null 2>"${err}" ||
  fail "writing the attempt record on Issue #${n} failed: $(head -n1 "${err}")"
printf 'attempt\t%s\t%s\n' "${next}" "${max_attempts}"
