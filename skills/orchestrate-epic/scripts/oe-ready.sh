#!/usr/bin/env bash
# oe ready: prints each child Issue's next action, derived only from GitHub, following the
# next-action table in docs/design/orchestrate-epic.md. Read-only: it writes nothing to GitHub or
# to any checkout. It uses only gh, filtering every response with gh --jq.
# Usage: oe ready <owner/repo> <epic-number> [--running <issue-number>]...
#   --running leaves out an Issue whose agent is running in this session.
# Output, one line per child Issue in number order: <issue>\t<action>\t<reason>
#   wait-base       the default-branch head has a pending or failed check, or no check yet
#   claim           no branch and every dependency completed: claim it and start an Owner
#   start-verifier  the PR's head passed CI and has no verdict
# Exit: 0 every Issue classified; 1 a GitHub read failed, with nothing on stdout; 2 usage error;
#   3 the default-branch head still has no checks ten minutes after its push: end the session,
#   with one line `end\t<reason>`.
# OE_NOW, in epoch seconds, overrides the current time.
set -uo pipefail

# Seconds a SHA may go without checks before its CI counts as missing rather than not started.
NO_CHECKS_GRACE=600
VERIFY_CONTEXT=oe/verify
BRANCH_PREFIX=feat/issue-

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
[[ $# -eq 0 ]] || usage "Unknown argument: $1"

now="${OE_NOW:-$(date -u +%s)}"
[[ "${now}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

CHECKS='statusCheckRollup { contexts(first: 100) { totalCount nodes { __typename
  ... on CheckRun { name status conclusion startedAt checkSuite { databaseId } }
  ... on StatusContext { context state createdAt } } } }'

# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
GATE_QUERY='query($owner: String!, $repo: String!, $epic: Int!) {
  repository(owner: $owner, name: $repo) {
    nameWithOwner
    defaultBranchRef { name target { ... on Commit { oid committedDate '"${CHECKS}"' } } }
    issue(number: $epic) { subIssues(first: 100) { totalCount nodes { number repository { nameWithOwner } } } }
  }
}'

# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
ISSUE_QUERY='query($owner: String!, $repo: String!, $num: Int!, $branch: String!, $ref: String!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $num) {
      number state stateReason
      blockedBy(first: 100) { totalCount nodes { number state stateReason } }
      comments(last: 100) { totalCount nodes { authorAssociation body createdAt } }
    }
    ref(qualifiedName: $ref) { name }
    pullRequests(headRefName: $branch, first: 10, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        number state createdAt mergedAt isCrossRepository headRefOid mergeable
        commits(last: 1) { nodes { commit { oid committedDate '"${CHECKS}"' } } }
      }
    }
  }
}'

# Shared jq definitions. ci classifies a commit's checks, leaving out the oe/verify status, as
# none, pending, failed, or passed; any completed check that did not pass counts as failed.
# shellcheck disable=SC2016 # jq program, not shell expansion.
COMMON='
  def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
  def check_name: .name // .context // "unnamed check";
  def check_class:
    if .__typename == "CheckRun" then
      if .status != "COMPLETED" then "pending"
      elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "passed"
      else "failed" end
    elif .__typename == "StatusContext" then
      if .state == "SUCCESS" then "passed"
      elif .state == "PENDING" or .state == "EXPECTED" then "pending"
      else "failed" end
    else error("unknown check type \(.__typename)") end;
  def check_key($i):
    if .__typename == "StatusContext" then ["status", check_name]
    elif (.checkSuite.databaseId | type) == "number" then ["suite", (.checkSuite.databaseId | tostring), check_name]
    else ["unkeyed", ($i | tostring)] end;
  def ci:
    .oid as $oid
    | if .statusCheckRollup == null then {state: "none", detail: ""}
      else .statusCheckRollup.contexts
      | if (.nodes | type) != "array" or (.totalCount | type) != "number" then error("checks unreadable on \($oid)")
        elif .totalCount > (.nodes | length) then error("checks truncated on \($oid)")
        else . end
      | [.nodes | to_entries[] | .key as $i | .value
          | select(.__typename != "StatusContext" or .context != "'"${VERIFY_CONTEXT}"'")
          | {key: check_key($i), value: .}]
      | group_by(.key)
      | map(map(.value) | sort_by(.startedAt // .createdAt // "") | last | {name: check_name, class: check_class})
      | (map(select(.class == "failed") | .name)) as $failed
      | (map(select(.class == "pending") | .name)) as $pending
      | if ($failed | length) > 0 then {state: "failed", detail: ($failed | join(", "))}
        elif ($pending | length) > 0 then {state: "pending", detail: ($pending | join(", "))}
        elif length == 0 then {state: "none", detail: ""}
        else {state: "passed", detail: ""} end
      end;'

# shellcheck disable=SC2016 # jq program, not shell expansion.
GATE='
  .data.repository as $r
  | if ($r | type) != "object" then error("repository not found") else . end
  | ($r.defaultBranchRef.target // error("default branch head unreadable")) as $head
  | ($head | ci) as $ci
  | "default\t\($r.defaultBranchRef.name)\t\($head.oid)\t\($head.committedDate | epoch)\t\($ci.state)\t\($ci.detail)",
    (($r.issue // error("Epic not found")).subIssues
      | if .totalCount > (.nodes | length) then error("more than \(.nodes | length) child Issues") else . end
      | .nodes[]
      | if (.repository.nameWithOwner | ascii_downcase) != ($r.nameWithOwner | ascii_downcase)
        then error("child Issue #\(.number) is in \(.repository.nameWithOwner), not \($r.nameWithOwner)")
        else "issue\t\(.number)" end)'

# shellcheck disable=SC2016 # jq program, not shell expansion.
CLASSIFY='
  .data.repository as $r
  | ($r.issue // error("Issue not found")) as $i
  | [($r.pullRequests.nodes // error("pull requests unreadable"))[] | select(.isCrossRepository == false)] as $prs
  | ($prs | first) as $pr
  | ($r.ref != null) as $branch
  | "\($i.number)\t" + (
      if ($branch | not) then "claim\tevery dependency completed"
      elif $pr == null then error("not classified yet")
      else
        ($pr.commits.nodes[0].commit // error("PR #\($pr.number) head unreadable")) as $head
        | if $head.oid != $pr.headRefOid then error("PR #\($pr.number) head changed during the read") else . end
        | (facts[$head.oid] // error("PR #\($pr.number) head \($head.oid) changed during the read")) as $f
        | ($head | ci) as $ci
        | if $ci.state == "passed" then "start-verifier\tchecks passed on \($head.oid[0:7])"
          else error("not classified yet") end
      end)'

# Prints the epoch seconds of the latest push of SHA $2 to branch $1, or nothing when the
# repository activity does not show one.
pushed_at() {
  gh api "repos/${repo}/activity?ref=refs/heads/$1&per_page=100" \
    --jq '[.[] | select(.after == "'"$2"'")] | first | .timestamp // empty | sub("\\.[0-9]+"; "") | fromdateiso8601' \
    2>"${err}" || fail "activity read for $1 failed: $(head -n1 "${err}")"
}

gate="$(gh api graphql -f query="${GATE_QUERY}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F epic="${epic}" \
  --jq "${COMMON}${GATE}" 2>"${err}")" || fail "Epic read failed: $(head -n1 "${err}")"

issues=()
default_line=""
while IFS=$'\t' read -r kind a b c d e; do
  case "${kind}" in
  default) default_line="${a}"$'\t'"${b}"$'\t'"${c}"$'\t'"${d}"$'\t'"${e}" ;;
  issue) issues+=("${a}") ;;
  *) fail "unexpected Epic read line: ${kind}" ;;
  esac
done <<<"${gate}"
IFS=$'\t' read -r default_name default_sha default_committed default_ci default_detail <<<"${default_line}"
[[ "${default_name}" =~ ^[A-Za-z0-9._/-]+$ && "${default_sha}" =~ ^[0-9a-f]{40}$ &&
  "${default_committed}" =~ ^[0-9]+$ && "${default_ci}" =~ ^(none|pending|failed|passed)$ ]] ||
  fail "default branch head unreadable"

gate_reason=""
case "${default_ci}" in
none)
  pushed="$(pushed_at "${default_name}" "${default_sha}")" || exit 1
  age=$((now - ${pushed:-${default_committed}}))
  if ((age >= NO_CHECKS_GRACE)); then
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
  while read -r n; do sorted+=("${n}"); done < <(printf '%s\n' "${issues[@]}" | sort -n -u)
fi

out=""
if [[ -n "${gate_reason}" ]]; then
  for n in ${sorted[@]+"${sorted[@]}"}; do
    out+="${n}"$'\t'wait-base$'\t'"${gate_reason}"$'\n'
  done
  printf '%s' "${out}"
  exit 0
fi

# Facts read over REST for each open PR head: the oe/verify statuses and the push time.
pulls="$(gh api "repos/${repo}/pulls?state=open&per_page=100" --paginate --jq '.[]
  | select((.head.repo.full_name // "" | ascii_downcase) == ("'"${repo}"'" | ascii_downcase)
    and (.head.ref | test("^'"${BRANCH_PREFIX}"'[1-9][0-9]*$")))
  | "\(.head.ref | ltrimstr("'"${BRANCH_PREFIX}"'"))\t\(.head.sha)"' 2>"${err}")" ||
  fail "pull request list read failed: $(head -n1 "${err}")"

facts=""
while IFS=$'\t' read -r n sha; do
  [[ -n "${n}" ]] || continue
  [[ "${n}" =~ ^[1-9][0-9]*$ && "${sha}" =~ ^[0-9a-f]{40}$ ]] || fail "pull request list unreadable"
  states="$(gh api "repos/${repo}/commits/${sha}/statuses?per_page=100" --paginate \
    --jq '.[] | select(.context == "'"${VERIFY_CONTEXT}"'") | .state' 2>"${err}")" ||
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
  pushed="$(pushed_at "${BRANCH_PREFIX}${n}" "${sha}")" || exit 1
  facts+="\"${sha}\": {verdict: \"${verdict}\", starts: ${starts}, pushed: ${pushed:-null}},"
done <<<"${pulls}"

for n in ${sorted[@]+"${sorted[@]}"}; do
  line="$(gh api graphql -f query="${ISSUE_QUERY}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
    -f branch="${BRANCH_PREFIX}${n}" -f ref="refs/heads/${BRANCH_PREFIX}${n}" \
    --jq "${COMMON} def now_s: ${now}; def facts: {${facts%,}}; ${CLASSIFY}" 2>"${err}")" ||
    fail "Issue #${n} read failed: $(head -n1 "${err}")"
  out+="${line}"$'\n'
done
printf '%s' "${out}"
