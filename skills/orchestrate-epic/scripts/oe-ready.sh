#!/usr/bin/env bash
# oe ready: prints each child Issue's next action, derived only from GitHub, following the
# next-action table in docs/design/orchestrate-epic.md. Read-only: it writes nothing to GitHub or
# to any checkout. It uses only gh, filtering every response with gh --jq.
# Usage: oe ready <owner/repo> <epic-number> [--running <issue-number>]...
#   --running leaves out an Issue whose agent is running in this session.
# Output, one line per child Issue in number order: <issue>\t<action>\t<reason>, where the action
# is the first match, top down:
#   wait-base          the default-branch head has a pending or failed check, or no check yet
#   done               the Issue is closed
#   wait-engineer      a PR merged after the latest claim, or the branch's PR closed unmerged
#   wait-dependencies  no branch, and a dependency is open or closed other than as completed
#   claim              no branch, and every dependency completed: claim it and start an Owner
#   wait-answer        the latest question has no unmarked comment from a trusted role after it
#   start-owner        a repair is needed: no PR, a conflict, a failed check, a failure verdict,
#                      or a trusted answer, Changes requested review, or review-thread comment
#                      since the latest attempt
#   parked             a repair is needed after MAX_ATTEMPTS attempts, the head has had no checks
#                      for NO_CHECKS_GRACE seconds, or the Verifier started MAX_VERIFIER_STARTS
#                      times without a verdict
#   wait-ci            a check on the PR head is pending, or none arrived yet
#   wait-merge         the PR head has a success verdict
#   start-verifier     every check on the PR head passed and it has no verdict
# Exit: 0 every Issue classified; 1 a GitHub read failed, with nothing on stdout; 2 usage error;
#   3 the default-branch head still has no checks ten minutes after its push: end the session,
#   with one line `end\t<reason>`.
# What oe reads, and what oe's writers must produce:
#   branch        feat/issue-<n> in this repository; a PR from a fork never counts
#   records       Issue comments whose body starts with <!-- oe:claim -->, <!-- oe:attempt -->,
#                 or <!-- oe:question -->, by OWNER, MEMBER, or COLLABORATOR. Only records after
#                 the latest claim count, ordered by their place in the comment list
#   human input   a comment or review by OWNER, MEMBER, or COLLABORATOR whose body does not start
#                 with <!-- oe:
#   verdict       commit status oe/verify on the head: pending before each Verifier start, then
#                 success or failure. It is never counted as a CI check
#   push time     repository activity for the branch, or the commit date when none is listed
# OE_NOW, in epoch seconds, overrides the current time.
set -uo pipefail

# Seconds a SHA may go without checks before its CI counts as missing rather than not started.
NO_CHECKS_GRACE=600
# Verifier starts on one SHA, each marked by a pending oe/verify status, before the Issue parks.
MAX_VERIFIER_STARTS=2
# Owner attempts since the latest claim before an Issue that still needs repair parks.
MAX_ATTEMPTS=3
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
running=" "
while [[ $# -gt 0 ]]; do
  [[ "$1" == --running && "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage "Expected --running <issue-number>, got: $*"
  running+="$2 "
  shift 2
done

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
        reviews(last: 100, states: [CHANGES_REQUESTED]) { nodes { authorAssociation body submittedAt } }
        reviewThreads(last: 50) { nodes { comments(last: 50) { nodes { authorAssociation body createdAt } } } }
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
  def trusted: (.authorAssociation // "") as $a | $a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR";
  def record($kind): trusted and ((.body // "") | startswith("<!-- oe:\($kind) -->"));
  def human: trusted and ((.body // "") | startswith("<!-- oe:") | not);
  def repair($attempts): join("; ") as $why
    | if $attempts >= '"${MAX_ATTEMPTS}"' then "parked\t\($attempts) attempts used; still: \($why)"
      else "start-owner\tattempt \($attempts + 1) of '"${MAX_ATTEMPTS}"': \($why)" end;
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
  | ($i.comments.nodes // error("comments unreadable")) as $cs
  | ([range(0; $cs | length) | select($cs[.] | record("claim"))] | last) as $claim
  | (if $claim == null then null else $cs[$claim].createdAt end) as $claimAt
  | [($r.pullRequests.nodes // error("pull requests unreadable"))[] | select(.isCrossRepository == false)] as $prs
  | ($r.ref != null) as $branch
  | if $i.comments.totalCount > ($cs | length) and $claim == null and ($branch or ($prs | length) > 0)
    then error("Issue #\($i.number) has over \($cs | length) comments and none of the latest is a claim record")
    else . end
  | ([$prs[] | select($claimAt == null or .createdAt >= $claimAt)] | first) as $pr
  | ([$prs[] | select(.mergedAt != null and ($claimAt == null or .mergedAt >= $claimAt))] | first) as $merged
  | [range(($claim // -1) + 1; $cs | length) | select($cs[.] | record("attempt"))] as $attempts
  | ($attempts | last // $claim) as $sinceIndex
  | (if $sinceIndex == null then null else $cs[$sinceIndex].createdAt end) as $since
  | ([range(($claim // -1) + 1; $cs | length) | select($cs[.] | record("question"))] | last) as $question
  | (if $question == null then [] else [range($question + 1; $cs | length) | select($cs[.] | human)] end) as $answers
  | (if any($answers[]; . > ($sinceIndex // -1)) then ["a trusted answer to the question"] else [] end) as $answered
  | "\($i.number)\t" + (
      if $i.state == "CLOSED" then "done\tclosed"
      elif $merged != null then "wait-engineer\tPR #\($merged.number) merged; the Issue is still open"
      elif $branch and $pr != null and $pr.state == "CLOSED" then "wait-engineer\tPR #\($pr.number) closed without merging"
      elif ($branch | not) then
        ($i.blockedBy
          | if (.nodes | type) != "array" or .totalCount > (.nodes | length) then error("Issue #\($i.number) dependencies unreadable") else .nodes end
          | map(select(.state != "CLOSED" or .stateReason != "COMPLETED"))) as $waiting
        | if ($waiting | length) > 0
          then "wait-dependencies\t" + ($waiting | map("#\(.number) " + (if .state == "OPEN" then "open" else "closed as \(.stateReason // "unknown")" end)) | join(", "))
          else "claim\tevery dependency completed" end
      elif $question != null and ($answers | length) == 0 then "wait-answer\tthe question has no unmarked comment from a trusted role yet"
      elif $pr == null then $answered + ["no PR yet"] | repair($attempts | length)
      else
        ($pr.commits.nodes[0].commit // error("PR #\($pr.number) head unreadable")) as $head
        | if $head.oid != $pr.headRefOid then error("PR #\($pr.number) head changed during the read") else . end
        | (facts[$head.oid] // error("PR #\($pr.number) head \($head.oid) changed during the read")) as $f
        | ($head | ci) as $ci
        | $head.oid[0:7] as $sha
        | $answered + [
            if $pr.mergeable == "CONFLICTING" then "PR #\($pr.number) conflicts with its base" else empty end,
            if $ci.state == "failed" then "checks failed on \($sha): \($ci.detail)" else empty end,
            if $f.verdict == "failure" or $f.verdict == "error" then "failure verdict on \($sha)" else empty end,
            if any($pr.reviews.nodes[]?; human and ($since == null or .submittedAt > $since))
            then "a trusted Changes requested review" else empty end,
            if any($pr.reviewThreads.nodes[]?.comments.nodes[]?; human and ($since == null or .createdAt > $since))
            then "a trusted review-thread comment" else empty end
          ] as $repairs
        | (now_s - ($f.pushed // ($head.committedDate | epoch))) as $age
        | if ($repairs | length) > 0 then $repairs | repair($attempts | length)
          elif $ci.state == "pending" then "wait-ci\tchecks pending on \($sha): \($ci.detail)"
          elif $ci.state == "none" and $age < '"${NO_CHECKS_GRACE}"' then "wait-ci\tno checks yet on \($sha), \($age)s after its push"
          elif $ci.state == "none" then "parked\tno checks on \($sha) \($age)s after its push"
          elif $f.verdict == "success" then "wait-merge\tsuccess verdict on \($sha)"
          elif $f.starts >= '"${MAX_VERIFIER_STARTS}"' then "parked\tVerifier started \($f.starts) times on \($sha) without a verdict"
          else "start-verifier\tchecks passed on \($sha)" end
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
  [[ " ${sorted[*]-} " == *" ${n} "* ]] || continue
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
