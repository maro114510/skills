#!/usr/bin/env bash
# oe ready
#
# Prints the next action of every child Issue of an Epic.
# It reads GitHub only, through gh, and writes nothing anywhere.
# The actions follow the next-action table in docs/design/orchestrate-epic.md.
#
# Usage
#
#   oe ready <owner/repo> <epic-number> [--running <issue-number>]...
#
# - --running is accepted and ignored, so a caller written for it still runs: the working marker in each Issue body shows a running agent.
# - OE_NOW sets the current time in epoch seconds.
#
# Output
#
# - Each line holds an Issue number, an action, a reason, and the command that the action runs, separated by tabs.
#   The command is oe start for an action that starts an agent, oe hold for hold, and empty for every other action, except the one below.
# - A wait-answer line holds the open hold or question in its reason, with each line break written as \n,
#   and its command is the oe question --answer call that records the person's reply, ending in <reply>.
# - Lines are sorted by Issue number.
# - oe-ready.jq lists every action and the row it comes from.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | Every Issue was classified | One line per Issue |
# | 1 | A GitHub read failed | Nothing |
# | 2 | The arguments, or git config skills.bot, are invalid | Nothing |
#
# Files
#
# | File | Holds |
# |---|---|
# | oe-ready-epic.graphql | The Epic read |
# | oe-ready-issue.graphql | The read of one Issue |
# | oe-ready-checks.graphql | One more page of checks on a commit |
# | oe-ready.jq | Every rule that turns a response into an action |
# | oe-records.jq | Which comments count as holds, questions, answers, and engineer input |
# | oe-config.sh | The limits and names shared with oe's writers |
#
# Reads, in order
#
# 1. The Epic read gives the default branch name and the child Issues.
# 2. The open pull request list gives the head of each Issue branch.
# 3. Commit statuses give the verdict on each head.
# 4. Repository activity gives the push time of each head.
# 5. One read per Issue gives everything else, the working marker in its body included.
#
# Read 5 holds 100 checks of a commit, and one more read per page gives the rest.
# No read covers the default branch's checks, so its state never decides an action.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe ready <owner/repo> <epic-number> [--running <issue-number>]..." >&2
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
while [[ $# -gt 0 ]]; do
  [[ "$1" == --running && "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage "Expected --running <issue-number>, got: $*"
  shift 2
done

now="${OE_NOW:-$(date -u +%s)}"
[[ "${now}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

epic_query="$(<"${dir}/oe-ready-epic.graphql")" || fail "cannot read oe-ready-epic.graphql"
issue_query="$(<"${dir}/oe-ready-issue.graphql")" || fail "cannot read oe-ready-issue.graphql"
checks_query="$(<"${dir}/oe-ready-checks.graphql")" || fail "cannot read oe-ready-checks.graphql"
trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
rules="$(<"${dir}/oe-ready.jq")" || fail "cannot read oe-ready.jq"
rules="${trust}"$'\n'"${rules}"
bot="$(bot_def)" || usage "Invalid git config skills.bot"

# Prints the jq program that runs the entry point $1 of oe-ready.jq, with pr_heads set to $2.
program() {
  printf 'def now_s: %s; def no_checks_grace: %s; def marker_ttl: %s; def repair_cap: %s;\n' \
    "${now}" "${no_checks_grace}" "${marker_ttl}" "${repair_cap}"
  printf 'def verify_context: "%s"; def branch_prefix: "%s"; def pr_heads: {%s};\n%s\n%s\n' \
    "${verify_context}" "${branch_prefix}" "${2:-}" "${bot}"$'\n'"${rules}" "$1"
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
epic_lines="$(jq -r "$(program epic_lines)" <<<"${epic_response}" 2>"${err}")" ||
  fail "Epic read failed: $(head -n1 "${err}")"

issues=()
default_name=""
while IFS=$'\t' read -r kind a b; do
  case "${kind}" in
  default) default_name="${a}" ;;
  issue)
    [[ "${b}" =~ ^(OPEN|CLOSED)$ ]] || fail "unknown state of Issue #${a}: ${b}"
    issues+=("${a}")
    ;;
  *) fail "unexpected Epic read line: ${kind}" ;;
  esac
done <<<"${epic_lines}"
[[ "${default_name}" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "default branch unreadable"

# Prints $1 in single quotes, so a shell reads it back unchanged in any locale.
shell_quote() {
  local q="'\\''"
  printf "'%s'" "${1//\'/${q}}"
}

# Prints out's lines with a fourth field: the oe start command for an action that starts an agent,
# the oe hold command for hold, the oe question command that records the person's answer for wait-answer, and nothing otherwise.
# A command is complete and quoted, so a session that lost SKILL.md can run it as printed.
# The answer command ends in <reply>, which the session replaces with the person's reply, quoted.
with_commands() {
  local n action reason command lines=""
  while IFS=$'\t' read -r n action reason; do
    [[ -n "${n}" ]] || continue
    # A command runs as printed, so a line that is not exactly what classify writes fails the read instead.
    [[ "${n}" =~ ^[1-9][0-9]*$ && "${action}" =~ ^[a-z-]+$ && "${reason}" != *$'\t'* ]] ||
      fail "unexpected line for Issue ${n}"
    case "${action}" in
    start-owner) command="bash $(shell_quote "${dir}/oe") start owner ${repo} ${n} $(shell_quote "${reason}")" ;;
    start-verifier) command="bash $(shell_quote "${dir}/oe") start verifier ${repo} ${n}" ;;
    hold) command="bash $(shell_quote "${dir}/oe") hold ${repo} ${n} $(shell_quote "${reason}")" ;;
    wait-answer) command="bash $(shell_quote "${dir}/oe") question ${repo} ${n} --answer <reply>" ;;
    *) command="" ;;
    esac
    lines+="$(printf '%s\t%s\t%s\t%s' "${n}" "${action}" "${reason}" "${command}")"$'\n'
  done <<<"$1"
  printf '%s' "${lines}"
}

sorted=()
if [[ ${#issues[@]} -gt 0 ]]; then
  while read -r n; do
    sorted+=("${n}")
  done < <(printf '%s\n' "${issues[@]}" | sort -n -u)
fi

# Read 2: the head of each open Issue branch in this repository.
pulls="$(gh api "repos/${repo}/pulls?state=open&per_page=100" --paginate --jq '.[]
  | select((.head.repo.full_name // "" | ascii_downcase) == ("'"${repo}"'" | ascii_downcase)
    and (.head.ref | test("^'"${branch_prefix}"'[1-9][0-9]*$")))
  | "\(.head.ref | ltrimstr("'"${branch_prefix}"'"))\t\(.head.sha)"' 2>"${err}")" ||
  fail "pull request list read failed: $(head -n1 "${err}")"

# Reads 3 and 4 for each head.
# Statuses come newest first, so the first verdict status that is not pending is the current verdict.
pr_heads=""
while IFS=$'\t' read -r n sha; do
  [[ -n "${n}" ]] || continue
  [[ "${n}" =~ ^[1-9][0-9]*$ && "${sha}" =~ ^[0-9a-f]{40}$ ]] || fail "pull request list unreadable"
  [[ " ${sorted[*]-} " == *" ${n} "* ]] || continue
  states="$(gh api "repos/${repo}/commits/${sha}/statuses?per_page=100" --paginate \
    --jq '.[] | select(.context == "'"${verify_context}"'") | .state' 2>"${err}")" ||
    fail "status read for ${sha} failed: $(head -n1 "${err}")"
  verdict=none
  while read -r state; do
    [[ -n "${state}" ]] || continue
    [[ "${state}" =~ ^(pending|success|failure|error)$ ]] || fail "unknown status state on ${sha}: ${state}"
    [[ "${state}" != pending ]] || continue
    verdict="${state}"
    break
  done <<<"${states}"
  pushed="$(pushed_at "${branch_prefix}${n}" "${sha}")" || exit 1
  pr_heads+="\"${sha}\": {verdict: \"${verdict}\", pushed: ${pushed:-null}},"
done <<<"${pulls}"

# Read 5: each Issue, classified by oe-ready.jq.
out=""
for n in ${sorted[@]+"${sorted[@]}"}; do
  response="$(gh api graphql -f query="${issue_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
    -f branch="${branch_prefix}${n}" -f ref="refs/heads/${branch_prefix}${n}" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  response="$(all_checks "${response}")" || exit 1
  line="$(jq -r "$(program classify "${pr_heads%,}")" <<<"${response}" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  out+="${line}"$'\n'
done
with_commands "$(printf '%s' "${out}" | sort -t $'\t' -k1,1n)"
