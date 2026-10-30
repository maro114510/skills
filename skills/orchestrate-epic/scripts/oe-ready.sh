#!/usr/bin/env bash
# oe ready
#
# Prints the next action of every child Issue of an Epic.
# It reads GitHub through gh and the record store that oe-store.sh defines, and writes nothing anywhere.
# The actions follow the next-action table in docs/design/orchestrate-epic.md.
#
# Usage
#
#   oe ready <owner/repo> <epic-number> [--running <issue-number>]...
#
# - --running leaves out an Issue whose agent already runs in this session.
# - OE_NOW sets the current time in epoch seconds.
#
# Output
#
# - Each line holds an Issue number, an action, and a reason, separated by tabs.
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
# | 3 | The default branch head still has no checks after no_checks_grace | One line that starts with end |
#
# Files
#
# | File | Holds |
# |---|---|
# | oe-ready-epic.graphql | The Epic read |
# | oe-ready-issue.graphql | The read of one Issue |
# | oe-ready.jq | Every rule that turns a response into an action |
# | oe-records.jq | Which comments count as questions and as engineer input |
# | oe-config.sh | The limits and names shared with oe's writers |
# | oe-store.sh | Where each Issue's claim and attempt records live on this host |
#
# Reads, in order
#
# 1. The Epic read gives the default branch head, its checks, and the child Issues.
# 2. Repository activity gives the push time of a head that has no checks yet.
# 3. The open pull request list gives the head of each Issue branch.
# 4. Commit statuses give the verdict on each head and the number of Verifier starts.
# 5. One read per Issue, with its claim and attempt records from this host, gives everything else.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

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
running=" "
while [[ $# -gt 0 ]]; do
  [[ "$1" == --running && "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage "Expected --running <issue-number>, got: $*"
  running+="$2 "
  shift 2
done

now="${OE_NOW:-$(date -u +%s)}"
[[ "${now}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

epic_query="$(<"${dir}/oe-ready-epic.graphql")" || fail "cannot read oe-ready-epic.graphql"
issue_query="$(<"${dir}/oe-ready-issue.graphql")" || fail "cannot read oe-ready-issue.graphql"
trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
rules="$(<"${dir}/oe-ready.jq")" || fail "cannot read oe-ready.jq"
rules="${trust}"$'\n'"${rules}"

# Prints the jq program that runs the entry point $1 of oe-ready.jq, with pr_heads set to $2 and records to the JSON array $3.
program() {
  printf 'def now_s: %s; def no_checks_grace: %s; def max_attempts: %s; def max_verifier_starts: %s;\n' \
    "${now}" "${no_checks_grace}" "${max_attempts}" "${max_verifier_starts}"
  printf 'def verify_context: "%s"; def pr_heads: {%s}; def records: %s;\n%s\n%s\n' \
    "${verify_context}" "${2:-}" "${3:-[]}" "${rules}" "$1"
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

# Read 1: the Epic.
epic_lines="$(gh api graphql -f query="${epic_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F epic="${epic}" \
  --jq "$(program epic_lines)" 2>"${err}")" || fail "Epic read failed: $(head -n1 "${err}")"

issues=()
default_line=""
while IFS=$'\t' read -r kind a b c d e; do
  case "${kind}" in
  default) default_line="${a}"$'\t'"${b}"$'\t'"${c}"$'\t'"${d}"$'\t'"${e}" ;;
  issue) issues+=("${a}") ;;
  *) fail "unexpected Epic read line: ${kind}" ;;
  esac
done <<<"${epic_lines}"
IFS=$'\t' read -r default_name default_sha default_committed default_ci default_detail <<<"${default_line}"
[[ "${default_name}" =~ ^[A-Za-z0-9._/-]+$ && "${default_sha}" =~ ^[0-9a-f]{40}$ &&
  "${default_committed}" =~ ^[0-9]+$ && "${default_ci}" =~ ^(none|pending|failed|passed)$ ]] ||
  fail "default branch head unreadable"

# Rows 1 and 2 of the next-action table gate every Issue on the default branch head.
#
# | Row | When | Result |
# |---|---|---|
# | 1 | The head has no checks, and no_checks_grace has passed since its push | Exit 3 |
# | 2 | The head has no checks, and no_checks_grace has not passed since its push | Every Issue gets wait-base |
# | 2 | A check on the head is pending or failed | Every Issue gets wait-base |
gate_reason=""
case "${default_ci}" in
none)
  # Read 2: the push time of the default branch head.
  pushed="$(pushed_at "${default_name}" "${default_sha}")" || exit 1
  age=$((now - ${pushed:-${default_committed}}))
  if ((age >= no_checks_grace)); then
    printf 'end\tno checks on %s head %s %ss after its push\n' "${default_name}" "${default_sha:0:7}" "${age}"
    exit 3
  fi
  gate_reason="no checks yet on ${default_name} head ${default_sha:0:7}, ${age}s after its push"
  ;;
pending) gate_reason="checks pending on ${default_name} head ${default_sha:0:7}: ${default_detail}" ;;
failed) gate_reason="checks failed on ${default_name} head ${default_sha:0:7}: ${default_detail}" ;;
esac

sorted=()
if [[ ${#issues[@]} -gt 0 ]]; then
  while read -r n; do
    [[ "${running}" == *" ${n} "* ]] || sorted+=("${n}")
  done < <(printf '%s\n' "${issues[@]}" | sort -n -u)
fi

out=""
if [[ -n "${gate_reason}" ]]; then
  for n in ${sorted[@]+"${sorted[@]}"}; do
    out+="${n}"$'\t'wait-base$'\t'"${gate_reason}"$'\n'
  done
  printf '%s' "${out}"
  exit 0
fi

# Read 3: the head of each open Issue branch in this repository.
pulls="$(gh api "repos/${repo}/pulls?state=open&per_page=100" --paginate --jq '.[]
  | select((.head.repo.full_name // "" | ascii_downcase) == ("'"${repo}"'" | ascii_downcase)
    and (.head.ref | test("^'"${branch_prefix}"'[1-9][0-9]*$")))
  | "\(.head.ref | ltrimstr("'"${branch_prefix}"'"))\t\(.head.sha)"' 2>"${err}")" ||
  fail "pull request list read failed: $(head -n1 "${err}")"

# Read 4 and read 2 for each head.
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

# Read 5: each Issue, classified by rows 3 to 12 in oe-ready.jq.
# Only the kind and time of claim and attempt records decide an action, so verdict findings stay out of the program.
for n in ${sorted[@]+"${sorted[@]}"}; do
  issue_records="$(records_read "${repo}" "${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
  issue_records="$(jq -c 'map(select(.kind == "claim" or .kind == "attempt") | {kind, at})' <<<"${issue_records}")" ||
    fail "records of Issue #${n} unreadable"
  line="$(gh api graphql -f query="${issue_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
    -f branch="${branch_prefix}${n}" -f ref="refs/heads/${branch_prefix}${n}" \
    --jq "$(program classify "${pr_heads%,}" "${issue_records}")" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  out+="${line}"$'\n'
done
printf '%s' "${out}"
