#!/usr/bin/env bash
# oe ready
#
# Prints the next action of every child Issue of an Epic.
# It reads GitHub through gh and the record store that oe-store.sh defines, and writes nothing anywhere.
# The actions follow the next-action table in docs/design/orchestrate-epic.md.
#
# Usage
#
#   oe ready <owner/repo> <epic-number> [--running <issue-number>]... [--facts]
#
# - --running leaves out an Issue whose agent already runs in this session.
# - --facts, for oe status, prints each line as the JSON object that facts in oe-ready.jq describes.
#   It changes only the format: the same reads run, and the same action is decided.
# - OE_NOW sets the current time in epoch seconds.
#
# Output
#
# - Each line holds an Issue number, an action, a reason, and the oe command that the action runs, separated by tabs.
#   The command is oe start for an action that starts an agent, oe update for a branch update, and empty otherwise.
# - Lines are sorted by Issue number.
# - oe-ready.jq lists every action and the row it comes from.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | Every Issue was classified | One line per Issue |
# | 1 | A GitHub read or the record store read failed | Nothing |
# | 2 | The arguments are invalid | Nothing |
#
# Files
#
# | File | Holds |
# |---|---|
# | oe-ready-epic.graphql | The Epic read |
# | oe-ready-issue.graphql | The read of one Issue |
# | oe-ready-checks.graphql | One more page of checks on a commit |
# | oe-ready.jq | Every rule that turns a response into an action |
# | oe-bots.jq | The review bots whose findings start a repair, and how a finding is read |
# | oe-records.jq | Which comments count as questions and as engineer input |
# | oe-config.sh | The limits and names shared with oe's writers |
# | oe-store.sh | Where each Issue's claim, attempt, and update records live on this host |
#
# Reads, in order
#
# 1. The Epic read gives the default branch head, its checks, and the child Issues.
# 2. The open pull request list gives the head of each Issue branch.
# 3. Commit statuses give the verdict on each head and the number of Verifier starts.
# 4. Repository activity gives the push time of each head.
# 5. One read per Issue, with its claim, attempt, and update records from this host, gives everything else.
# 6. One compare per listed head, when another Issue's pull request merged into the default branch,
#    gives whether the head contains that merge.
#
# Reads 1 and 5 hold 100 checks of a commit, and one more read per page gives the rest.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe ready <owner/repo> <epic-number> [--running <issue-number>]... [--facts]" >&2
  exit 2
}

fail() {
  echo "oe ready: $1" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
repo="$1"
epic="$2"
shift 2
running=" "
entry=classify
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --facts ]]; then
    entry='facts | tojson'
    shift
    continue
  fi
  [[ "$1" == --running && "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage "Expected --running <issue-number>, got: $*"
  running+="$2 "
  shift 2
done

now="${OE_NOW:-$(date -u +%s)}"
[[ "${now}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

epic_query="$(<"${dir}/oe-ready-epic.graphql")" || fail "cannot read oe-ready-epic.graphql"
issue_query="$(<"${dir}/oe-ready-issue.graphql")" || fail "cannot read oe-ready-issue.graphql"
checks_query="$(<"${dir}/oe-ready-checks.graphql")" || fail "cannot read oe-ready-checks.graphql"
trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
bots="$(<"${dir}/oe-bots.jq")" || fail "cannot read oe-bots.jq"
rules="$(<"${dir}/oe-ready.jq")" || fail "cannot read oe-ready.jq"
rules="${trust}"$'\n'"${bots}"$'\n'"${rules}"

# Prints the jq program that runs the entry point $1 of oe-ready.jq,
# with pr_heads set to $2, records to the JSON array $3, and stale_heads to $4.
program() {
  printf 'def now_s: %s; def no_checks_grace: %s; def max_attempts: %s; def max_verifier_starts: %s; def max_updates: %s;\n' \
    "${now}" "${no_checks_grace}" "${max_attempts}" "${max_verifier_starts}" "${max_updates}"
  printf 'def verify_context: "%s"; def pr_heads: {%s}; def records: %s; def stale_heads: {%s};\n%s\n%s\n' \
    "${verify_context}" "${2:-}" "${3:-[]}" "${4:-}" "${rules}" "$1"
}

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

# Prints the epoch seconds of the latest push of the commit $2 to the branch $1.
# Prints nothing when repository activity does not list that push.
pushed_at() {
  gh api "repos/${repo}/activity?ref=refs/heads/$1&per_page=100" \
    --jq '[.[] | select(.after == "'"$2"'")] | first | .timestamp // empty | sub("\\.[0-9]+"; "") | fromdateiso8601' \
    2>"${err}" || fail "activity read for $1 failed: $(head -n1 "${err}")"
}

# Prints the GraphQL response $1 with every check of each commit in it, reading the pages after the first.
# A page that cannot be read fails, so no action is decided from part of the checks.
all_checks() {
  local response="$1" at oid cursor page
  while true; do
    at="$(jq -c 'first(paths(objects | .statusCheckRollup?.contexts.pageInfo.hasNextPage == true)) // empty' \
      <<<"${response}")" || fail "checks unreadable"
    [[ -n "${at}" ]] || break
    IFS=$'\t' read -r oid cursor < <(jq -r --argjson at "${at}" \
      'getpath($at) | "\(.oid)\t\(.statusCheckRollup.contexts.pageInfo.endCursor)"' <<<"${response}")
    [[ "${oid}" =~ ^[0-9a-f]{40}$ && -n "${cursor}" && "${cursor}" != null ]] || fail "checks unreadable"
    page="$(gh api graphql -f query="${checks_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" \
      -f oid="${oid}" -f after="${cursor}" --jq '.data.repository.object.statusCheckRollup.contexts' 2>"${err}")" ||
      fail "checks read on ${oid} failed: $(head -n1 "${err}")"
    response="$(jq -c --argjson at "${at}" --argjson page "${page:-null}" '
      setpath($at + ["statusCheckRollup", "contexts"];
        getpath($at).statusCheckRollup.contexts
        | .nodes += ($page.nodes // []) | .pageInfo = $page.pageInfo)' <<<"${response}")" ||
      fail "checks on ${oid} unreadable"
  done
  printf '%s' "${response}"
}

# Read 1: the Epic.
epic_response="$(gh api graphql -f query="${epic_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F epic="${epic}" \
  2>"${err}")" || fail "Epic read failed: $(head -n1 "${err}")"
epic_response="$(all_checks "${epic_response}")" || exit 1
epic_lines="$(jq -r "$(program epic_lines)" <<<"${epic_response}" 2>"${err}")" ||
  fail "Epic read failed: $(head -n1 "${err}")"

issues=()
default_line=""
while IFS=$'\t' read -r kind a b c d; do
  case "${kind}" in
  default) default_line="${a}"$'\t'"${b}"$'\t'"${c}"$'\t'"${d}" ;;
  issue) issues+=("${a}") ;;
  *) fail "unexpected Epic read line: ${kind}" ;;
  esac
done <<<"${epic_lines}"
IFS=$'\t' read -r default_name default_sha default_ci default_detail <<<"${default_line}"
[[ "${default_name}" =~ ^[A-Za-z0-9._/-]+$ && "${default_sha}" =~ ^[0-9a-f]{40}$ &&
  "${default_ci}" =~ ^(none|pending|failed|passed)$ ]] ||
  fail "default branch head unreadable"

# Rows 1 and 2 of the next-action table gate every Issue on the default branch head.
#
# | Row | When | Result |
# |---|---|---|
# | 1 | A check on the head failed | Every Issue gets wait-base |
# | 2 | A check on the head is pending, or the head has no checks | Every Issue goes on to rows 3 to 13 |
#
# Row 2 holds nothing, because a pending or missing check does not show the default branch is broken,
# and each pull request's own CI still runs on its merge base.
gate_reason=""
if [[ "${default_ci}" == failed ]]; then
  gate_reason="checks failed on ${default_name} head ${default_sha:0:7}: ${default_detail//[$'\t\r']/ }"
fi

# Prints $1 in single quotes, so a shell reads it back unchanged in any locale.
shell_quote() {
  local q="'\\''"
  printf "'%s'" "${1//\'/${q}}"
}

# Prints the head SHA of the open pull request of Issue $1 in the pull request list, or nothing.
listed_head() {
  local n sha
  while IFS=$'\t' read -r n sha; do
    [[ "${n}" != "$1" ]] || printf '%s' "${sha}"
  done <<<"${pulls:-}"
}

# Prints out's lines with a fourth field: the oe start command for an action that starts an agent,
# the oe update command for a branch update, and nothing otherwise.
# The command is complete and quoted, so a session that lost SKILL.md can run it as printed.
with_start() {
  local n action reason start sha lines=""
  while IFS=$'\t' read -r n action reason; do
    [[ -n "${n}" ]] || continue
    # A start command runs as printed, so a line that is not exactly what classify writes fails the read instead.
    [[ "${n}" =~ ^[1-9][0-9]*$ && "${action}" =~ ^[a-z-]+$ && "${reason}" != *$'\t'* ]] ||
      fail "unexpected line for Issue ${n}"
    case "${action}" in
    claim) start="start owner ${repo} ${n} --claim $(shell_quote "${reason}")" ;;
    start-owner) start="start owner ${repo} ${n} $(shell_quote "${reason}")" ;;
    start-verifier) start="start verifier ${repo} ${n}" ;;
    # classify gives update only to a head in the pull request list, so the listed head is the head it read.
    update)
      sha="$(listed_head "${n}")"
      [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || fail "no listed head for Issue ${n}"
      start="update ${repo} ${n} ${sha}"
      ;;
    *) start="" ;;
    esac
    lines+="$(printf '%s\t%s\t%s\t%s' "${n}" "${action}" "${reason}" "${start:+bash $(shell_quote "${dir}/oe") ${start}}")"$'\n'
  done <<<"$1"
  printf '%s' "${lines}"
}

sorted=()
if [[ ${#issues[@]} -gt 0 ]]; then
  while read -r n; do
    [[ "${running}" == *" ${n} "* ]] || sorted+=("${n}")
  done < <(printf '%s\n' "${issues[@]}" | sort -n -u)
fi

out=""
if [[ -n "${gate_reason}" ]]; then
  for n in ${sorted[@]+"${sorted[@]}"}; do
    if [[ "${entry}" == classify ]]; then
      out+="${n}"$'\t'wait-base$'\t'"${gate_reason}"$'\n'
    else
      out+="$(jq -cn --argjson n "${n}" --arg reason "${gate_reason}" \
        '{number: $n, action: "wait-base", reason: $reason}')"$'\n' || fail "cannot format Issue #${n}"
    fi
  done
  if [[ "${entry}" == classify ]]; then
    with_start "${out}"
  else
    printf '%s' "${out}"
  fi
  exit 0
fi

# Read 2: the head of each open Issue branch in this repository.
pulls="$(gh api "repos/${repo}/pulls?state=open&per_page=100" --paginate --jq '.[]
  | select((.head.repo.full_name // "" | ascii_downcase) == ("'"${repo}"'" | ascii_downcase)
    and (.head.ref | test("^'"${branch_prefix}"'[1-9][0-9]*$")))
  | "\(.head.ref | ltrimstr("'"${branch_prefix}"'"))\t\(.head.sha)"' 2>"${err}")" ||
  fail "pull request list read failed: $(head -n1 "${err}")"

# Reads 3 and 4 for each head.
#
# - Statuses come newest first, so the first verdict status is the current verdict.
# - oe writes a pending verdict before every Verifier start, so pending statuses count the starts.
pr_heads=""
while IFS=$'\t' read -r n sha; do
  [[ -n "${n}" ]] || continue
  [[ "${n}" =~ ^[1-9][0-9]*$ && "${sha}" =~ ^[0-9a-f]{40}$ ]] || fail "pull request list unreadable"
  [[ " ${sorted[*]-} " == *" ${n} "* ]] || continue
  states="$(gh api "repos/${repo}/commits/${sha}/statuses?per_page=100" --paginate \
    --jq '.[] | select(.context == "'"${verify_context}"'") | .state' 2>"${err}")" ||
    fail "status read for ${sha} failed: $(head -n1 "${err}")"
  verdict=none
  starts=0
  first=1
  while read -r state; do
    [[ -n "${state}" ]] || continue
    [[ "${state}" =~ ^(pending|success|failure|error)$ ]] || fail "unknown status state on ${sha}: ${state}"
    if ((first)); then
      verdict="${state}"
      first=0
    fi
    [[ "${state}" != pending ]] || starts=$((starts + 1))
  done <<<"${states}"
  pushed="$(pushed_at "${branch_prefix}${n}" "${sha}")" || exit 1
  pr_heads+="\"${sha}\": {verdict: \"${verdict}\", starts: ${starts}, pushed: ${pushed:-null}},"
done <<<"${pulls}"

# Read 5: each Issue.
responses=()
for n in ${sorted[@]+"${sorted[@]}"}; do
  response="$(gh api graphql -f query="${issue_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
    -f branch="${branch_prefix}${n}" -f ref="refs/heads/${branch_prefix}${n}" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  response="$(all_checks "${response}")" || exit 1
  responses+=("${response}")
done

# Sibling pull requests: each Issue's newest pull request, when it merged into the default branch, oldest merge first.
# Every merge commit lands on the default branch, so a head that contains the newest one contains every earlier one.
siblings=""
for response in ${responses[@]+"${responses[@]}"}; do
  siblings+="$(jq -r --arg base "${default_name}" '.data.repository as $r
    | ($r.pullRequests.nodes // [])[0]
    | select(. != null and .mergedAt != null and .isCrossRepository == false and .baseRefName == $base and .mergeCommit.oid != null)
    | "\(.mergedAt)\t\($r.issue.number)\t\(.number)\t\(.mergeCommit.oid)"' <<<"${response}" 2>"${err}")" ||
    fail "merged pull request unreadable: $(head -n1 "${err}")"
  siblings+=$'\n'
done
siblings="$(sort <<<"${siblings}")"

# Read 6: whether each listed head contains the newest merge commit of a sibling of its Issue.
# compare reports ahead or identical when the head contains it, and behind or diverged when it does not.
stale_heads=""
while IFS=$'\t' read -r n sha; do
  [[ -n "${n}" && " ${sorted[*]-} " == *" ${n} "* ]] || continue
  newest=""
  while IFS=$'\t' read -r _ sibling_issue sibling_pr merge; do
    [[ -n "${sibling_issue}" && "${sibling_issue}" != "${n}" ]] || continue
    [[ "${sibling_pr}" =~ ^[1-9][0-9]*$ && "${merge}" =~ ^[0-9a-f]{40}$ ]] || fail "merged pull request unreadable"
    newest="${sibling_pr} ${merge}"
  done <<<"${siblings}"
  [[ -n "${newest}" ]] || continue
  compared="$(gh api "repos/${repo}/compare/${newest#* }...${sha}?per_page=1" --jq .status 2>"${err}")" ||
    fail "compare of ${sha} with ${newest#* } failed: $(head -n1 "${err}")"
  case "${compared}" in
  ahead | identical) ;;
  behind | diverged) stale_heads+="\"${sha}\": ${newest%% *}," ;;
  *) fail "unknown compare status of ${sha}: ${compared}" ;;
  esac
done <<<"${pulls}"

# Each Issue, classified by rows 3 to 13 in oe-ready.jq.
# Only the kind, time, bots, and SHA of claim, attempt, and update records decide an action, so verdict findings stay out of the program.
i=0
for n in ${sorted[@]+"${sorted[@]}"}; do
  issue_records="$(records_read "${repo}" "${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
  issue_records="$(jq -c 'map(select(.kind == "claim" or .kind == "attempt" or .kind == "update") | {kind, at, bots, sha})' \
    <<<"${issue_records}")" || fail "records of Issue #${n} unreadable"
  line="$(jq -r "$(program "${entry}" "${pr_heads%,}" "${issue_records}" "${stale_heads%,}")" <<<"${responses[i]}" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  out+="${line}"$'\n'
  i=$((i + 1))
done
if [[ "${entry}" == classify ]]; then
  with_start "${out}"
else
  printf '%s' "${out}"
fi
