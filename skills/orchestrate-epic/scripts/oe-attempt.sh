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
# Bot rounds
#
# - The attempt records the bots whose findings it uses, so the Owner repairs those bots' findings and asks no other.
# - A bot's finding counts when oe-bots.jq says it starts a repair: a listed bot, an unresolved thread it opened,
#   a level it repairs, no trusted approval on the head, an unused round, and a write after the latest attempt.
# - A round is used once an attempt record names its bot, so the same bot never chases the Owner twice per claim.
# - The bots are read from GitHub here, and not passed in, so no caller decides which rounds an attempt spends.
#   A read that fails starts no attempt, because a failed read decides nothing.
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
# | 1 | The record store or a GitHub read failed | Nothing |
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

# Read 1: the Issue and its branch's open pull request, as oe ready reads them.
issue_query="$(<"${dir}/oe-ready-issue.graphql")" || fail "cannot read oe-ready-issue.graphql"
trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
bot_rules="$(<"${dir}/oe-bots.jq")" || fail "cannot read oe-bots.jq"

claimed_at="$(jq -r '(map(.kind == "claim") | rindex(true)) as $claim
  | if $claim == null then "" else .[$claim].at end' <<<"${records}")" ||
  fail "cannot read the claim of Issue #${n}"
since="$(jq -r '(map(.kind == "claim") | rindex(true)) as $claim
  | ([.[($claim // -1) + 1:][] | select(.kind == "attempt") | .at] | last)
    // (if $claim == null then "" else .[$claim].at end)' <<<"${records}")" ||
  fail "cannot order the records of Issue #${n}"
spent="$(jq -c '(map(.kind == "claim") | rindex(true)) as $claim
  | [.[($claim // -1) + 1:][] | select(.kind == "attempt") | (.bots // [])[]] | unique' <<<"${records}")" ||
  fail "cannot read the bot rounds of Issue #${n}"

# The record values enter the jq program as JSON literals, so no record can change the program.
quote() { jq -Rn --arg v "$1" '$v | tojson'; }
values="$(printf 'def claimed_at: %s; def since_at: %s; def used_bots: %s;\n' \
  "$(quote "${claimed_at}")" "$(quote "${since}")" "${spent}")" || fail "cannot build the read of Issue #${n}"

# shellcheck disable=SC2016 # The jq program names jq's own variables, not the shell's.
program="$(printf '%s\n%s\n%s\n%s\n' "${trust}" "${bot_rules}" "${values}" '
.data.repository as $r
| ([($r.pullRequests.nodes // [])[]
    | select(.isCrossRepository == false)
    | select(claimed_at == "" or .createdAt >= claimed_at)] | first) as $pr
| if $pr == null then []
  else ($pr.approvals.nodes // []) as $approvals
    | ($pr.headRefOid) as $head
    | [$pr.reviewThreads.nodes[] | bot_finding((if since_at == "" then null else since_at end); used_bots; bot_approved($approvals; $head)) | .login]
    | unique
  end')"

bots="$(gh api graphql -f query="${issue_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
  -f branch="${branch_prefix}${n}" -f ref="refs/heads/${branch_prefix}${n}" \
  --jq "${program}" 2>"${err}")" || fail "Issue #${n} read failed: $(head -n1 "${err}")"
jq -e 'type == "array" and all(.[]; type == "string")' <<<"${bots}" >/dev/null 2>&1 ||
  fail "the bot list of Issue #${n} is unreadable"

record="$(jq -cn --arg at "${at}" --argjson bots "${bots}" \
  '{kind: "attempt", at: $at} + (if ($bots | length) > 0 then {bots: $bots} else {} end)')" ||
  fail "cannot build the record of Issue #${n}"
records_add "${repo}" "${n}" "${record}" 2>"${err}" ||
  fail "recording the attempt of Issue #${n} failed: $(head -n1 "${err}")"
printf 'attempt\t%s\t%s\n' "$((used + 1))" "${max_attempts}"
