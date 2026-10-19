#!/usr/bin/env bats
# Tests for pr-readiness.sh. Each case edits one clean GraphQL snapshot with jq and classifies it.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/pr-readiness.sh"
  clean='{"data":{"repository":{"pullRequest":{
    "number":7,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
    "reviewDecision":"APPROVED","isMergeQueueEnabled":false,"headRefOid":"abc123",
    "reviewRequests":{"totalCount":0,"nodes":[]},
    "latestOpinionatedReviews":{"totalCount":1,"nodes":[{"state":"APPROVED","author":{"login":"alice"}}]},
    "reviewThreads":{"totalCount":1,"nodes":[{"isResolved":true}]},
    "commits":{"nodes":[{"commit":{"oid":"abc123","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":2,"nodes":[
      {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS"}]}}}}]}}}}}'
}

# Classifies the clean snapshot after applying the jq edit $1 to .data.repository.pullRequest.
classify() {
  local snapshot
  snapshot="$(jq -c ".data.repository.pullRequest |= (${1:-.})" <<<"${clean}")"
  run bash "${target}" --snapshot - <<<"${snapshot}"
}

has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

reason() {
  printf '%s\n' "${lines[@]}" | sed -n 's/^reason=//p' | head -n1
}

# Succeeds when the reason line contains $1. A failing function call, unlike a bare mid-test
# `[[ ]]`, fails the test on every bash.
reason_has() {
  case "$(reason)" in
  *"$1"*) return 0 ;;
  *) return 1 ;;
  esac
}

# Edits the checks list: $1 is a jq expression producing the contexts nodes array.
checks() {
  echo ".commits.nodes[0].commit.statusCheckRollup.contexts |= {totalCount: ($1 | length), nodes: $1}"
}

@test "rejects bad arguments with exit 2" {
  run bash "${target}"
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo
  [ "${status}" -eq 2 ]
  run bash "${target}" noslash 7
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 0
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 7a
  [ "${status}" -eq 2 ]
  run bash "${target}" --snapshot
  [ "${status}" -eq 2 ]
  run bash "${target}" --snapshot "${BATS_TEST_TMPDIR}/missing.json"
  [ "${status}" -eq 2 ]
}

@test "checks and reviews complete with no rejection is READY" {
  classify
  [ "${status}" -eq 0 ]
  has_line "status=READY"
  has_line "pr=7"
  has_line "head=abc123"
}

@test "no review policy and no reviews is READY" {
  classify '.reviewDecision = null | .latestOpinionatedReviews = {totalCount: 0, nodes: []}'
  [ "${status}" -eq 0 ]
  has_line "status=READY"
}

@test "HAS_HOOKS merge state is READY" {
  classify '.mergeStateStatus = "HAS_HOOKS"'
  has_line "status=READY"
}

@test "neutral and skipped checks do not hold a merge" {
  classify "$(checks '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"NEUTRAL"},
    {"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"SKIPPED"}]')"
  has_line "status=READY"
}

@test "merged PR is MERGED" {
  classify '.state = "MERGED" | .mergeable = "UNKNOWN" | .mergeStateStatus = "UNKNOWN"'
  [ "${status}" -eq 0 ]
  has_line "status=MERGED"
}

@test "closed PR is CLOSED" {
  classify '.state = "CLOSED"'
  [ "${status}" -eq 0 ]
  has_line "status=CLOSED"
}

@test "a pending check run is WAITING" {
  classify "$(checks '[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null}]')"
  [ "${status}" -eq 0 ]
  has_line "status=WAITING"
  reason_has "check pending: test"
}

@test "a queued check run and a pending or expected status are WAITING" {
  classify "$(checks '[{"__typename":"CheckRun","name":"q","status":"QUEUED","conclusion":null},
    {"__typename":"StatusContext","context":"ci/a","state":"PENDING"},
    {"__typename":"StatusContext","context":"ci/b","state":"EXPECTED"}]')"
  has_line "status=WAITING"
  reason_has "check pending: q"
  reason_has "check pending: ci/a"
  reason_has "check pending: ci/b"
}

@test "no checks reported on the head is WAITING" {
  classify '.commits.nodes[0].commit.statusCheckRollup = null'
  [ "${status}" -eq 0 ]
  has_line "status=WAITING"
  reason_has "no checks reported"
}

@test "mergeability still being computed is WAITING" {
  classify '.mergeable = "UNKNOWN" | .mergeStateStatus = "UNKNOWN"'
  has_line "status=WAITING"
}

@test "a required review not yet given is WAITING" {
  classify '.reviewDecision = "REVIEW_REQUIRED"'
  has_line "status=WAITING"
  reason_has "review required"
}

@test "an outstanding review request is WAITING" {
  classify '.reviewRequests = {totalCount: 2, nodes: [{requestedReviewer: {__typename: "User", login: "bob"}},
    {requestedReviewer: {__typename: "Team", slug: "core"}}]}'
  has_line "status=WAITING"
  reason_has "review requested: bob"
  reason_has "review requested: core"
}

@test "a conflict is BLOCKED" {
  classify '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'
  [ "${status}" -eq 0 ]
  has_line "status=BLOCKED"
  reason_has "conflict"
}

@test "an unresolved review thread is BLOCKED" {
  classify '.reviewThreads = {totalCount: 2, nodes: [{isResolved: true}, {isResolved: false}]}'
  has_line "status=BLOCKED"
  reason_has "1 unresolved review thread"
}

@test "changes requested by the review decision is BLOCKED" {
  classify '.reviewDecision = "CHANGES_REQUESTED"'
  has_line "status=BLOCKED"
  reason_has "changes requested"
}

@test "changes requested by a bot review outside the review decision is BLOCKED" {
  classify '.latestOpinionatedReviews = {totalCount: 2, nodes: [{state: "APPROVED", author: {login: "alice"}},
    {state: "CHANGES_REQUESTED", author: {login: "coderabbitai"}}]}'
  has_line "status=BLOCKED"
  reason_has "changes requested: coderabbitai"
}

@test "a check asking for human action is BLOCKED" {
  classify "$(checks '[{"__typename":"CheckRun","name":"ai-review","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}]')"
  has_line "status=BLOCKED"
  reason_has "human action required: ai-review"
}

@test "failed checks are BLOCKED" {
  classify "$(checks '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"},
    {"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"TIMED_OUT"},
    {"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"CANCELLED"},
    {"__typename":"StatusContext","context":"d","state":"ERROR"},
    {"__typename":"StatusContext","context":"e","state":"FAILURE"}]')"
  has_line "status=BLOCKED"
  for n in a b c d e; do
    reason_has "check failed: ${n}"
  done
}

# Prints one CheckRun node: $1 name, $2 status, $3 conclusion or null, $4 startedAt or null,
# $5 check suite databaseId or null.
run_node() {
  jq -nc --arg n "$1" --arg s "$2" --argjson c "$3" --argjson t "$4" --argjson id "$5" \
    '{__typename: "CheckRun", name: $n, status: $s, conclusion: $c, startedAt: $t,
      checkSuite: {databaseId: $id, app: {slug: "github-actions"}, workflowRun: {workflow: {name: "CI"}}}}'
}

@test "a failed check re-run to success in the same check suite is READY" {
  classify "$(checks "[$(run_node test COMPLETED '"FAILURE"' '"2026-10-19T01:00:00Z"' 11),
    $(run_node test COMPLETED '"SUCCESS"' '"2026-10-19T02:00:00Z"' 11)]")"
  [ "${status}" -eq 0 ]
  has_line "status=READY"
}

@test "a re-run that has not started yet supersedes the earlier result and is WAITING" {
  classify "$(checks "[$(run_node test QUEUED null null 11),
    $(run_node test COMPLETED '"FAILURE"' '"2026-10-19T01:00:00Z"' 11)]")"
  has_line "status=WAITING"
  reason_has "check pending: test"
}

@test "same-named checks from workflows sharing a display name stay separate" {
  # Both fixtures report workflow name "CI"; only the check suite tells the two files apart.
  classify "$(checks "[$(run_node build COMPLETED '"FAILURE"' '"2026-10-19T01:00:00Z"' 11),
    $(run_node build COMPLETED '"SUCCESS"' '"2026-10-19T02:00:00Z"' 22)]")"
  has_line "status=BLOCKED"
  reason_has "check failed: build"
}

@test "one workflow triggered twice on the same head keeps both runs" {
  # A push run and a pull_request run of one file land in two check suites.
  classify "$(checks "[$(run_node test COMPLETED '"SUCCESS"' '"2026-10-19T02:00:00Z"' 11),
    $(run_node test COMPLETED '"FAILURE"' '"2026-10-19T01:00:00Z"' 22)]")"
  has_line "status=BLOCKED"
  reason_has "check failed: test"
}

@test "check runs without a check suite id are never collapsed" {
  classify "$(checks "[$(run_node test COMPLETED '"FAILURE"' '"2026-10-19T01:00:00Z"' null),
    $(run_node test COMPLETED '"SUCCESS"' '"2026-10-19T02:00:00Z"' null)]")"
  has_line "status=BLOCKED"
  reason_has "check failed: test"
}

@test "a re-posted commit status supersedes the earlier one" {
  classify "$(checks '[{"__typename":"StatusContext","context":"ci/a","state":"FAILURE","createdAt":"2026-10-19T01:00:00Z"},
    {"__typename":"StatusContext","context":"ci/a","state":"SUCCESS","createdAt":"2026-10-19T02:00:00Z"}]')"
  has_line "status=READY"
}

@test "a draft is BLOCKED" {
  classify '.isDraft = true | .mergeStateStatus = "DRAFT"'
  has_line "status=BLOCKED"
  reason_has "draft"
}

@test "a merge queue on the base branch is BLOCKED" {
  classify '.isMergeQueueEnabled = true'
  has_line "status=BLOCKED"
  reason_has "merge queue"
}

@test "repository merge controls rejecting the merge are BLOCKED" {
  for s in BLOCKED BEHIND UNSTABLE SOMETHING_NEW; do
    classify ".mergeStateStatus = \"${s}\""
    has_line "status=BLOCKED"
    reason_has "merge state ${s}"
  done
}

@test "a BLOCKED signal outranks a WAITING one, and every reason is listed" {
  classify "$(checks '[{"__typename":"CheckRun","name":"slow","status":"IN_PROGRESS","conclusion":null}]')"' | .mergeable = "CONFLICTING" | .reviewThreads.nodes[0].isResolved = false'
  has_line "status=BLOCKED"
  reason_has "conflict"
  reason_has "unresolved review thread"
  ! reason_has "check pending" || return 1
}

@test "a missing required field holds the merge with exit 1" {
  for f in state isDraft mergeable mergeStateStatus isMergeQueueEnabled reviewRequests latestOpinionatedReviews reviewThreads commits; do
    classify "del(.${f})"
    [ "${status}" -eq 1 ]
    has_line "status=BLOCKED"
    reason_has "unreadable"
  done
}

@test "a null or missing node inside a signal holds the merge" {
  classify '.reviewThreads.nodes[0].isResolved = null'
  [ "${status}" -eq 1 ]
  has_line "status=BLOCKED"
  classify '.commits.nodes = []'
  [ "${status}" -eq 1 ]
  classify "$(checks '[{"__typename":"CheckRun","name":"x","status":"COMPLETED","conclusion":null}]')"
  [ "${status}" -eq 1 ]
  classify "$(checks '[{"__typename":"SomethingElse"}]')"
  [ "${status}" -eq 1 ]
}

@test "each unreadable signal is named exactly once" {
  classify '.reviewThreads.totalCount = 101 | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0] = null'
  [ "${status}" -eq 1 ]
  [ "$(reason)" = "unreadable: reviewThreads truncated (101 > 1); check state missing: unnamed check" ]
}

@test "a truncated connection holds the merge" {
  for c in reviewThreads latestOpinionatedReviews reviewRequests; do
    classify ".${c}.totalCount = 101"
    [ "${status}" -eq 1 ]
    has_line "status=BLOCKED"
    reason_has "unreadable: ${c} truncated"
  done
  classify '.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount = 101'
  [ "${status}" -eq 1 ]
  has_line "status=BLOCKED"
}

@test "a merged PR needs no other signal to be read" {
  classify '.state = "MERGED" | .reviewThreads.totalCount = 101'
  [ "${status}" -eq 0 ]
  has_line "status=MERGED"
}

@test "GraphQL errors, a missing PR, or invalid JSON hold the merge" {
  run bash "${target}" --snapshot - <<<'{"errors":[{"message":"boom"}],"data":null}'
  [ "${status}" -eq 1 ]
  has_line "status=BLOCKED"
  run bash "${target}" --snapshot - <<<'{"data":{"repository":{"pullRequest":null}}}'
  [ "${status}" -eq 1 ]
  has_line "status=BLOCKED"
  run bash "${target}" --snapshot - <<<'not json'
  [ "${status}" -eq 1 ]
  has_line "status=BLOCKED"
  run bash "${target}" --snapshot - </dev/null
  [ "${status}" -eq 1 ]
  has_line "status=BLOCKED"
}

@test "live mode queries the named PR and classifies the response" {
  mkdir "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${BATS_TEST_TMPDIR}/gh-args"
printf '%s\n' "${GH_RESPONSE}"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" GH_RESPONSE="${clean}" run bash "${target}" octo/widgets 7
  [ "${status}" -eq 0 ]
  has_line "status=READY"
  grep -qxF 'owner=octo' "${BATS_TEST_TMPDIR}/gh-args"
  grep -qxF 'repo=widgets' "${BATS_TEST_TMPDIR}/gh-args"
  grep -qxF 'num=7' "${BATS_TEST_TMPDIR}/gh-args"
}

@test "live mode holds the merge when gh fails" {
  mkdir "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\necho "HTTP 502" >&2\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run bash "${target}" octo/widgets 7
  [ "${status}" -eq 1 ]
  has_line "status=BLOCKED"
  reason_has "unreadable"
}
