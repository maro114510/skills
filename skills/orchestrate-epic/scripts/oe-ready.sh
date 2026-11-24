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
# - OE_READY_CACHE names a directory in which oe ready keeps what it read of each open Issue, which oe wait sets for the polls of one call.
#   A later run reads an open Issue again only when what the lighter reads below show has changed, or a time that decides its action has passed.
#   A run without it reads every open Issue.
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
# | oe-ready-commits.graphql | One more page of the commits of a pull request |
# | oe-ready-head.graphql | The light read of one open pull request |
# | oe-ready.jq | Every rule that turns a response into an action |
# | oe-records.jq | Which comments count as holds, questions, answers, and engineer input |
# | oe-config.sh | The limits and names shared with oe's writers |
#
# Reads, in order
#
# 1. The Epic read gives the default branch name and the child Issues.
# 2. The open pull request list gives the head of each Issue branch.
# 3. Commit statuses give the verdicts on each head, with the time of each.
# 4. Repository activity gives the push time of each head.
# 5. One read per open Issue gives everything else, the working marker in its body included.
#    A closed Issue is done on read 1 alone and gets no read of its own.
# 6. With OE_READY_CACHE, one light read of each open pull request gives its update time, whether it conflicts,
#    its review threads, and the state of its head's checks.
#    An open Issue is read again only when its update time, its dependencies, the head of its pull request, that head's verdict, or the light read changed,
#    or at the time next_deadline in oe-ready.jq gives: a head moved during the read, a working marker's 2 hours, or a head's 10 minutes with no checks.
#    Until then its line is the one from the run that read it, so the seconds in its reason are from that run.
#
# Read 5 holds the last 20 commits of an open pull request and 100 checks of each commit, and one more read per page gives the rest.
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
commits_query="$(<"${dir}/oe-ready-commits.graphql")" || fail "cannot read oe-ready-commits.graphql"
head_query="$(<"${dir}/oe-ready-head.graphql")" || fail "cannot read oe-ready-head.graphql"
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

# Prints the GraphQL response $1 with every commit of each open pull request in it, reading the pages before the first.
# A page that cannot be read fails, so no repair cap is decided from part of the commits.
all_commits() {
  local response="$1" at number cursor page
  while true; do
    at="$(jq -c 'first(paths(objects | .state? == "OPEN" and .commits?.pageInfo?.hasPreviousPage == true)) // empty' \
      <<<"${response}")" || fail "commits unreadable"
    [[ -n "${at}" ]] || break
    IFS=$'\t' read -r number cursor < <(jq -r --argjson at "${at}" \
      'getpath($at) | "\(.number)\t\(.commits.pageInfo.startCursor)"' <<<"${response}")
    [[ "${number}" =~ ^[1-9][0-9]*$ && -n "${cursor}" && "${cursor}" != null ]] || fail "commits unreadable"
    page="$(gh api graphql -f query="${commits_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" \
      -F number="${number}" -f before="${cursor}" --jq '.data.repository.pullRequest.commits' 2>"${err}")" ||
      fail "commits read on PR #${number} failed: $(head -n1 "${err}")"
    # A page that is not a list of commits, is empty although the read advertised earlier commits, or does not move back from the cursor, would end or repeat the read on part of the commits.
    jq -e --arg cursor "${cursor}" '(.nodes | type) == "array" and (.nodes | length) > 0 and (.pageInfo.hasPreviousPage | type) == "boolean"
      and (.pageInfo.hasPreviousPage == false or ((.pageInfo.startCursor | type) == "string" and .pageInfo.startCursor != $cursor))' \
      <<<"${page}" >/dev/null 2>&1 || fail "commits page on PR #${number} unreadable"
    # The page is read from a descriptor, since a page of 50 commits can exceed the limit of one argument.
    response="$(jq -c --argjson at "${at}" --slurpfile page <(printf '%s' "${page}") '
      setpath($at + ["commits"];
        getpath($at).commits
        | .nodes = (($page[0].nodes // []) + .nodes) | .pageInfo = $page[0].pageInfo)' <<<"${response}")" ||
      fail "commits on PR #${number} unreadable"
  done
  printf '%s' "${response}"
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
epic_facts="$(jq -c "$(program epic_facts)" <<<"${epic_response}" 2>"${err}")" || fail "Epic read failed: $(head -n1 "${err}")"

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
  | "\(.head.ref | ltrimstr("'"${branch_prefix}"'"))\t\(.head.sha)\t\(.number)"' 2>"${err}")" ||
  fail "pull request list read failed: $(head -n1 "${err}")"

# Reads 3 and 4 for each head.
# Statuses come newest first, so the first verdict status that is not pending is the latest verdict.
# pr_heads keeps every verdict status that is not pending, newest first, because a re-run request makes the older ones count as none.
pr_heads=""
heads=""
while IFS=$'\t' read -r n sha pr; do
  [[ -n "${n}" ]] || continue
  [[ "${n}" =~ ^[1-9][0-9]*$ && "${sha}" =~ ^[0-9a-f]{40}$ && "${pr}" =~ ^[1-9][0-9]*$ ]] || fail "pull request list unreadable"
  [[ " ${sorted[*]-} " == *" ${n} "* ]] || continue
  states="$(gh api "repos/${repo}/commits/${sha}/statuses?per_page=100" --paginate \
    --jq '.[] | select(.context == "'"${verify_context}"'") | "\(.state)\t\(.created_at)"' 2>"${err}")" ||
    fail "status read for ${sha} failed: $(head -n1 "${err}")"
  verdict=none
  verdicts=""
  while IFS=$'\t' read -r state at; do
    [[ -n "${state}" ]] || continue
    [[ "${state}" =~ ^(pending|success|failure|error)$ ]] || fail "unknown status state on ${sha}: ${state}"
    [[ "${at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] || fail "unreadable status time on ${sha}: ${at}"
    [[ "${state}" != pending ]] || continue
    [[ "${verdict}" != none ]] || verdict="${state}"
    verdicts+="{state: \"${state}\", at: \"${at}\"},"
  done <<<"${states}"
  pushed="$(pushed_at "${branch_prefix}${n}" "${sha}")" || exit 1
  pr_heads+="\"${sha}\": {verdicts: [${verdicts%,}], pushed: ${pushed:-null}},"
  heads+="${n}"$'\t'"${sha}"$'\t'"${pr}"$'\t'"${verdict}"$'\n'
done <<<"${pulls}"

# Prints what an open Issue's action rests on, as one line of JSON, with the light read of its open pull request, read 6, when it has one.
# It prints the same line while nothing has changed that the action rests on, except a time that decides it.
facts_of() {
  local n="$1" sha pr verdict light="null" head="null"
  IFS=$'\t' read -r sha pr verdict < <(awk -F '\t' -v n="${n}" '$1 == n { print $2 "\t" $3 "\t" $4 }' <<<"${heads}")
  if [[ -n "${sha}" ]]; then
    light="$(gh api graphql -f query="${head_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F number="${pr}" --jq '.data.repository.pullRequest
      | {updatedAt, mergeable, threads: [.reviewThreads.nodes[] | [.isResolved, .isOutdated]], checks: .commits.nodes[0].commit.statusCheckRollup.state}' \
      2>"${err}")" || fail "pull request #${pr} read failed: $(head -n1 "${err}")"
    head="$(jq -cn --arg sha "${sha}" --arg verdict "${verdict}" --argjson light "${light}" '{sha: $sha, verdict: $verdict, light: $light}')" ||
      fail "pull request #${pr} unreadable"
  fi
  jq -cn --argjson epic "$(jq -c --arg n "${n}" '.[$n]' <<<"${epic_facts}")" --argjson head "${head}" '{epic: $epic, head: $head}'
}

# Read 5: each Issue, classified by oe-ready.jq.
# A closed Issue is done without a read, which is what classify gives it.
out=""
for n in ${sorted[@]+"${sorted[@]}"}; do
  if [[ "$(jq -r --arg n "${n}" '.[$n].state' <<<"${epic_facts}")" == CLOSED ]]; then
    out+="${n}"$'\t'done$'\t'closed$'\n'
    continue
  fi
  facts=""
  if [[ -n "${OE_READY_CACHE:-}" ]]; then
    facts="$(facts_of "${n}")" || exit 1
    if [[ -f "${OE_READY_CACHE}/${n}.json" ]] &&
      line="$(jq -r --argjson facts "${facts}" --argjson now "${now}" \
        'select(.facts == $facts and (.deadline == null or $now < .deadline)) | .line' "${OE_READY_CACHE}/${n}.json" 2>/dev/null)" &&
      [[ -n "${line}" ]]; then
      out+="${line}"$'\n'
      continue
    fi
  fi
  response="$(gh api graphql -f query="${issue_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
    -f branch="${branch_prefix}${n}" -f ref="refs/heads/${branch_prefix}${n}" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  response="$(all_commits "${response}")" || exit 1
  response="$(all_checks "${response}")" || exit 1
  line="$(jq -r "$(program classify "${pr_heads%,}")" <<<"${response}" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  if [[ -n "${facts}" ]]; then
    deadline="$(jq -r "$(program next_deadline "${pr_heads%,}")" <<<"${response}" 2>"${err}")" ||
      fail "Issue #${n} read failed: $(head -n1 "${err}")"
    jq -n --argjson facts "${facts}" --arg line "${line}" --argjson deadline "${deadline:-null}" '{facts: $facts, line: $line, deadline: $deadline}' \
      >"${OE_READY_CACHE}/${n}.json" || fail "cannot write the cache of Issue #${n}"
  fi
  out+="${line}"$'\n'
done
with_commands "$(printf '%s' "${out}" | sort -t $'\t' -k1,1n)"
