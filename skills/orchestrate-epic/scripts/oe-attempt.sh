#!/usr/bin/env bash
# oe attempt
#
# Records an Owner start on this host before the Owner starts, with the head of the Issue branch, and refuses a start oe ready would park.
# It counts attempts as oe ready does, so the Owner it admits is one that oe ready still allows.
#
# Usage
#
#   oe attempt <owner/repo> <issue-number>
#
# Counting
#
# - Records come from the record store that oe-store.sh defines.
# - Only attempt records after the latest claim record count as starts.
# - Every attempt record counts as a start when there is no claim record.
# - The record holds head, the Issue branch's head now, and none when the branch does not exist.
# - An attempt is a start that pushed, as oe-starts.jq says: the head read later differs from the one the start recorded.
#   A start that pushed nothing spends no attempt, but its record still holds the bot rounds it used.
# - The start is refused when max_attempts attempts are used, and when the latest max_attempts starts pushed nothing.
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
# - On success, one line holding attempt, the attempts used by earlier starts plus one, and max_attempts, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | The attempt record was written | The attempt record |
# | 1 | The record store or a GitHub read failed | Nothing |
# | 2 | The arguments, or git config skills.bot, are invalid | Nothing |
# | 4 | max_attempts attempts are already used, or the latest max_attempts starts pushed nothing | Nothing |
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
starts="$(<"${dir}/oe-starts.jq")" || fail "cannot read oe-starts.jq"

# Read 1: the Issue and its branch's open pull request, as oe ready reads them.
issue_query="$(<"${dir}/oe-ready-issue.graphql")" || fail "cannot read oe-ready-issue.graphql"
trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
bot="$(bot_def)" || usage "Invalid git config skills.bot"
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
program="$(printf '%s\n%s\n%s\n%s\n%s\n' "${bot}" "${trust}" "${bot_rules}" "${values}" '
.data.repository as $r
| ([($r.pullRequests.nodes // [])[]
    | select(.isCrossRepository == false)
    | select(claimed_at == "" or .createdAt >= claimed_at)] | first) as $pr
| {head: ($r.ref.target.oid // null),
    bots: (if $pr == null then []
      else ($pr.approvals.nodes // []) as $approvals
        | ($pr.headRefOid) as $head
        | [$pr.reviewThreads.nodes[] | bot_finding((if since_at == "" then null else since_at end); used_bots; bot_approved($approvals; $head)) | .login]
        | unique
      end)}')"

read_out="$(gh api graphql -f query="${issue_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
  -f branch="${branch_prefix}${n}" -f ref="refs/heads/${branch_prefix}${n}" \
  --jq "${program}" 2>"${err}")" || fail "Issue #${n} read failed: $(head -n1 "${err}")"
jq -e '(.bots | type == "array" and all(.[]; type == "string")) and (.head | type == "string" or . == null)' \
  <<<"${read_out}" >/dev/null 2>&1 || fail "the read of Issue #${n} is unreadable"
bots="$(jq -c .bots <<<"${read_out}")" || fail "cannot read the bots of Issue #${n}"
branch_head="$(jq -c .head <<<"${read_out}")" || fail "cannot read the branch head of Issue #${n}"

used="$(jq -r --argjson current "${branch_head}" "${starts}"$'\n''attempts_used($current)' <<<"${records}")" ||
  fail "cannot count the attempts of Issue #${n}"
idle="$(jq -r --argjson current "${branch_head}" "${starts}"$'\n''starts_without_push($current)' <<<"${records}")" ||
  fail "cannot count the starts of Issue #${n} that pushed nothing"
if ((used >= max_attempts)); then
  echo "oe attempt: Issue #${n} already used ${used} of ${max_attempts} attempts since its claim" >&2
  exit 4
fi
if ((idle >= max_attempts)); then
  echo "oe attempt: the latest ${idle} Owner starts on Issue #${n} pushed nothing" >&2
  exit 4
fi

record="$(jq -cn --arg at "${at}" --argjson bots "${bots}" --argjson head "${branch_head}" \
  '{kind: "attempt", at: $at} + (if $head != null then {head: $head} else {} end)
    + (if ($bots | length) > 0 then {bots: $bots} else {} end)')" ||
  fail "cannot build the record of Issue #${n}"
records_add "${repo}" "${n}" "${record}" 2>"${err}" ||
  fail "recording the attempt of Issue #${n} failed: $(head -n1 "${err}")"
printf 'attempt\t%s\t%s\n' "$((used + 1))" "${max_attempts}"
