#!/usr/bin/env bash
# Classifies whether one pull request is ready to merge, from a single GraphQL snapshot of its
# state, draft flag, conflicts, checks, reviews, review requests, review threads, and merge state.
# Usage: pr-readiness.sh <owner/repo> <pr-number>   query GitHub, then classify
#        pr-readiness.sh --snapshot <file|->          classify a saved response of the same query
# Output: status=<READY|WAITING|BLOCKED|MERGED|CLOSED>, reason=<...>, pr=<n>, head=<sha>, one per line.
# Exit: 0 classified, 1 a required signal could not be read (status=BLOCKED), 2 usage error.
# Merge only on exit 0 with status=READY; every other result holds the merge.
set -uo pipefail

usage() {
  echo "$1" >&2
  echo "Usage: pr-readiness.sh <owner/repo> <pr-number> | --snapshot <file|->" >&2
  exit 2
}

hold() {
  printf 'status=BLOCKED\nreason=unreadable: %s\n' "$1"
  exit 1
}

# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
QUERY='query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      number state isDraft mergeable mergeStateStatus reviewDecision isMergeQueueEnabled headRefOid
      reviewRequests(first: 100) { totalCount nodes { requestedReviewer { __typename
        ... on User { login } ... on Team { slug } ... on Bot { login } ... on Mannequin { login } } } }
      latestOpinionatedReviews(first: 100) { totalCount nodes { state author { login } } }
      reviewThreads(first: 100) { totalCount nodes { isResolved } }
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state
        contexts(first: 100) { totalCount nodes { __typename
          ... on CheckRun { name status conclusion startedAt
            checkSuite { app { slug } workflowRun { workflow { name } } } }
          ... on StatusContext { context state createdAt } } } } } } }
    }
  }
}'

# Precedence: MERGED/CLOSED, then any unreadable signal, then BLOCKED, then WAITING, then READY.
# Every check counts, required or not: a pending one waits and a failed one blocks, so a required
# check that is not configured as required still holds the merge. Unknown enum values fail closed.
# shellcheck disable=SC2016 # jq program, not shell expansion.
CLASSIFY='
  def conn($name): (.[$name] // null) as $c
    | if ($c | type) != "object" or ($c.nodes | type) != "array" or ($c.totalCount | type) != "number"
      then "\($name) missing"
      elif $c.totalCount > ($c.nodes | length) then "\($name) truncated (\($c.totalCount) > \($c.nodes | length))"
      else empty end;
  def who: .requestedReviewer // {} | .login // .slug // "unknown reviewer";
  def check_name: .name // .context // "unnamed check";
  # One of pass, pending, failed, action, or unreadable.
  def check_class:
    if .__typename == "CheckRun" then
      if (.status | type) != "string" then "unreadable"
      elif .status != "COMPLETED" then "pending"
      elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "pass"
      elif .conclusion == "ACTION_REQUIRED" then "action"
      elif (.conclusion | type) == "string" then "failed"
      else "unreadable" end
    elif .__typename == "StatusContext" then
      if .state == "SUCCESS" then "pass"
      elif .state == "PENDING" or .state == "EXPECTED" then "pending"
      elif (.state | type) == "string" then "failed"
      else "unreadable" end
    else "unreadable" end;
  # A re-run leaves the superseded run in the rollup, so keep only the latest run per check:
  # the same workflow (or app) and name for a check run, the same context for a status. A run not
  # started yet has no timestamp and counts as the latest, since it is the pending re-run.
  def check_key: [.__typename, (.checkSuite.workflowRun.workflow.name // .checkSuite.app.slug // ""), check_name];
  def latest_checks: group_by(check_key)
    | map(sort_by((.startedAt // .createdAt) as $t | [$t == null, $t // ""]) | last);
  def out($status; $reasons): {status: $status, reason: ($reasons | join("; ")), pr: .number, head: .headRefOid};

  if (.errors // null) != null then {status: "BLOCKED", unreadable: true, reason: "GraphQL errors: \([.errors[]?.message] | join(", "))"}
  elif (.data.repository.pullRequest | type) != "object" then {status: "BLOCKED", unreadable: true, reason: "pull request not found in response"}
  else .data.repository.pullRequest
  | if .state == "MERGED" then out("MERGED"; ["merged"])
    elif .state == "CLOSED" then out("CLOSED"; ["closed without merging"])
    else
      ([.commits.nodes[0]?.commit?] | first) as $commit
      | ($commit.statusCheckRollup // null) as $rollup
      | ($rollup.contexts.nodes // [] | latest_checks
          | map({name: check_name, class: check_class})) as $checks
      | [ (if .state != "OPEN" then "state \(.state // "missing")" else empty end),
          (("isDraft", "isMergeQueueEnabled") as $f
            | if (.[$f] | type) != "boolean" then "\($f) missing" else empty end),
          (("mergeable", "mergeStateStatus") as $f
            | if (.[$f] | type) != "string" then "\($f) missing" else empty end),
          conn("reviewRequests"), conn("latestOpinionatedReviews"), conn("reviewThreads"),
          (if ($commit | type) != "object" then "head commit missing" else empty end),
          (if $rollup != null then ($rollup | conn("contexts") | "checks: \(.)") else empty end),
          (if any(.reviewThreads.nodes[]?; (.isResolved | type) != "boolean") then "review thread state missing" else empty end),
          (if any(.latestOpinionatedReviews.nodes[]?; (.state | type) != "string") then "review state missing" else empty end),
          ($checks[] | select(.class == "unreadable") | "check state missing: \(.name)")
        ] as $unreadable
      | if ($unreadable | length) > 0 then out("BLOCKED"; $unreadable) + {unreadable: true}
        else
          [ (if .isDraft then "draft" else empty end),
            (if .mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY" then "conflict with base" else empty end),
            (if .reviewDecision == "CHANGES_REQUESTED" then "changes requested by review decision" else empty end),
            (.latestOpinionatedReviews.nodes[] | select(.state == "CHANGES_REQUESTED")
              | "changes requested: \(.author.login // "unknown")"),
            ([.reviewThreads.nodes[] | select(.isResolved == false)] | length
              | if . > 0 then "\(.) unresolved review thread(s)" else empty end),
            ($checks[] | select(.class == "failed") | "check failed: \(.name)"),
            ($checks[] | select(.class == "action") | "human action required: \(.name)"),
            (if .isMergeQueueEnabled then "merge queue required; this loop never bypasses it" else empty end)
          ] as $blocked
        | [ (if .mergeable == "UNKNOWN" or .mergeStateStatus == "UNKNOWN" then "mergeability still being computed" else empty end),
            (if $rollup == null or ($checks | length) == 0 then "no checks reported on head" else empty end),
            ($checks[] | select(.class == "pending") | "check pending: \(.name)"),
            (if .reviewDecision == "REVIEW_REQUIRED" then "review required" else empty end),
            (.reviewRequests.nodes[] | "review requested: \(who)")
          ] as $waiting
        | if ($blocked | length) > 0 then out("BLOCKED"; $blocked)
          elif ($waiting | length) > 0 then out("WAITING"; $waiting)
          elif .mergeStateStatus == "CLEAN" or .mergeStateStatus == "HAS_HOOKS" then out("READY"; ["checks and reviews complete, merge state \(.mergeStateStatus)"])
          else out("BLOCKED"; ["merge state \(.mergeStateStatus): repository merge controls not satisfied"])
          end
        end
    end
  end
  | "status=\(.status)", "reason=\(.reason)",
    (if .pr != null then "pr=\(.pr)" else empty end),
    (if .head != null then "head=\(.head)" else empty end),
    (if .unreadable then "unreadable=true" else empty end)'

classify() {
  local snapshot="$1" result
  [[ -n "${snapshot}" ]] || hold "empty response"
  result="$(jq -r "${CLASSIFY}" <<<"${snapshot}" 2>/dev/null)" || hold "response is not JSON of the expected shape"
  if grep -qxF 'unreadable=true' <<<"${result}"; then
    grep -vxF 'unreadable=true' <<<"${result}" | sed '2s/^reason=/reason=unreadable: /'
    exit 1
  fi
  printf '%s\n' "${result}"
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

if [[ "${1:-}" == --snapshot ]]; then
  [[ $# -eq 2 ]] || usage "--snapshot needs exactly one file or -"
  if [[ "$2" == - ]]; then
    classify "$(cat)"
  else
    [[ -r "$2" ]] || usage "Cannot read snapshot: $2"
    classify "$(cat "$2")"
  fi
  exit 0
fi

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <pr-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid pull request number: $2"

err="$(mktemp)" || hold "mktemp failed"
trap 'rm -f "${err}"' EXIT
response="$(gh api graphql -f query="${QUERY}" -f owner="${1%/*}" -f repo="${1#*/}" -F num="$2" 2>"${err}")" ||
  hold "gh api graphql failed: $(head -n1 "${err}")"
classify "${response}"
