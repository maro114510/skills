#!/usr/bin/env bats
# Tests for base-health.sh. Each case builds an Epic comment list and a pull-request snapshot with
# jq, then classifies them together.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/base-health.sh"
  comments='[]'
  now='2026-10-19T00:05:00Z'
  pull='{"data":{"repository":{"pullRequest":{
    "number":7,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",
    "mergeCommit":{"oid":"m111","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":2,"nodes":[
      {"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T00:00:10Z","checkSuite":{"databaseId":1}},
      {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS","createdAt":"2026-10-19T00:00:10Z"}]}}}}}}}'
}

# Appends one comment. $1 id, $2 created_at, $3 author login, $4 body.
add() {
  comments="$(jq -c --argjson id "$1" --arg at "$2" --arg login "$3" --arg body "$4" \
    '. + [{id: $id, created_at: $at, updated_at: $at, author_association: "OWNER", user: {login: $login}, body: $body}]' \
    <<<"${comments}")"
}

# The post-merge record. $1 id, $2 PR, $3 Issue, $4 author (default the loop identity).
record() {
  add "$1" 2026-10-18T23:59:00Z "${4:-loop}" "$(printf '%s\n' '<!-- orchestrate-epic:post-merge -->' \
    'orchestrate-epic post-merge:' "- pr: $2" "- issue: $3")"
}

# A freeze comment naming merge commit $2 and health status $4 (default FAIL). $1 id, $3 author
# (default the loop identity).
freeze() {
  add "$1" 2026-10-19T00:10:00Z "${3:-loop}" "$(printf '%s\n' '<!-- orchestrate-epic:freeze -->' \
    'orchestrate-epic: この Epic を凍結しました。' '- reason: post-merge checks failed' "- merge: $2" \
    "- health: ${4:-FAIL}" '- worker_dispatches: 1 / 5' '- reviewer_passes: 1 / 4' '- fix_cycles: 0 / 2')"
}

# Edits the pull-request snapshot with the jq expression $1 applied to .data.repository.pullRequest.
pr() {
  pull="$(jq -c ".data.repository.pullRequest |= (${1})" <<<"${pull}")"
}

# Replaces the merge commit's checks: $1 is a jq expression producing the contexts nodes array.
checks() {
  pr ".mergeCommit.statusCheckRollup.contexts |= {totalCount: ($1 | length), nodes: $1}"
}

classify() {
  run bash "${target}" --snapshot - --me loop < <(jq -cn --argjson c "${comments}" --argjson p "${pull}" \
    --arg now "${now}" '{comments: $c, pull: $p, now: $now}')
}

has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

lacks_prefix() {
  ! printf '%s\n' "${lines[@]}" | grep -q "^$1"
}

reason_has() {
  case "$(printf '%s\n' "${lines[@]}" | sed -n 's/^reason=//p' | head -n1)" in
  *"$1"*) return 0 ;;
  *) return 1 ;;
  esac
}

failed_run='{"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-19T00:00:10Z","checkSuite":{"databaseId":1}}'
pending_run='{"__typename":"CheckRun","name":"install","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-19T00:00:20Z","checkSuite":{"databaseId":2}}'

@test "rejects bad arguments with exit 2" {
  run bash "${target}"
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo
  [ "${status}" -eq 2 ]
  run bash "${target}" noslash 7
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 0
  [ "${status}" -eq 2 ]
  run bash "${target}" --snapshot - <<<'{}'
  [ "${status}" -eq 2 ]
  run bash "${target}" --snapshot "${BATS_TEST_TMPDIR}/missing.json" --me loop
  [ "${status}" -eq 2 ]
}

@test "an Epic with no post-merge record is CLEAR" {
  classify
  [ "${status}" -eq 0 ]
  has_line status=CLEAR
  has_line record_id=none
  has_line next=proceed
  lacks_prefix merge=
}

@test "a post-merge record planted by another login is ignored" {
  record 10 7 45 mallory
  classify
  [ "${status}" -eq 0 ]
  has_line status=CLEAR
  has_line record_id=none
}

@test "a recorded PR that never merged is CLEAR" {
  record 10 7 45
  pr '.state = "OPEN" | .mergedAt = null | .mergeCommit = null'
  classify
  [ "${status}" -eq 0 ]
  has_line status=CLEAR
  has_line record_id=10
  has_line pr=7
  has_line issue=45
  has_line next=proceed
  reason_has "not merged"
}

@test "every check passing on the merge commit is PASS" {
  record 10 7 45
  classify
  [ "${status}" -eq 0 ]
  has_line status=PASS
  has_line merge=m111
  has_line issue=45
  has_line next=proceed
}

@test "a pending check on the merge commit is PENDING and waits" {
  record 10 7 45
  checks "[${pending_run}]"
  classify
  [ "${status}" -eq 0 ]
  has_line status=PENDING
  has_line next=wait
  reason_has "check pending: install"
}

@test "a pending commit status is PENDING" {
  record 10 7 45
  checks '[{"__typename":"StatusContext","context":"ci/lint","state":"PENDING","createdAt":"2026-10-19T00:00:10Z"}]'
  classify
  has_line status=PENDING
}

@test "no checks reported yet within the grace period is PENDING" {
  record 10 7 45
  pr '.mergeCommit.statusCheckRollup = null'
  classify
  [ "${status}" -eq 0 ]
  has_line status=PENDING
  has_line next=wait
  reason_has "no checks reported"
}

@test "no checks reported after the grace period is UNCONFIRMED and freezes" {
  record 10 7 45
  pr '.mergeCommit.statusCheckRollup = null'
  now='2026-10-19T00:10:00Z'
  classify
  [ "${status}" -eq 0 ]
  has_line status=UNCONFIRMED
  has_line next=freeze
  has_line merge=m111
}

@test "an empty check list is treated like no checks" {
  record 10 7 45
  checks '[]'
  now='2026-10-19T01:00:00Z'
  classify
  has_line status=UNCONFIRMED
}

@test "a failed check on the merge commit is FAIL and freezes" {
  record 10 7 45
  checks "[${failed_run}]"
  classify
  [ "${status}" -eq 0 ]
  has_line status=FAIL
  has_line next=freeze
  has_line merge=m111
  reason_has "check failed: validate"
}

@test "a failure wins over a pending check" {
  record 10 7 45
  checks "[${failed_run}, ${pending_run}]"
  classify
  has_line status=FAIL
}

@test "timed-out, action-required, and stale runs are failures, never a pass" {
  local c
  for c in TIMED_OUT ACTION_REQUIRED STALE STARTUP_FAILURE; do
    record 10 7 45
    checks "[$(jq -c --arg c "${c}" '.conclusion = $c' <<<"${failed_run}")]"
    classify
    has_line status=FAIL
  done
}

@test "a cancelled run is UNCONFIRMED and freezes, never a pass" {
  record 10 7 45
  checks "[$(jq -c '.conclusion = "CANCELLED"' <<<"${failed_run}")]"
  classify
  [ "${status}" -eq 0 ]
  has_line status=UNCONFIRMED
  has_line next=freeze
  reason_has "check cancelled"
}

@test "a pending check is awaited before a cancelled one is judged" {
  record 10 7 45
  checks "[$(jq -c '.conclusion = "CANCELLED"' <<<"${failed_run}"), ${pending_run}]"
  classify
  has_line status=PENDING
}

@test "a failure wins over a cancelled run" {
  record 10 7 45
  checks "[$(jq -c '.conclusion = "CANCELLED" | .name = "lint" | .checkSuite.databaseId = 3' <<<"${failed_run}"), ${failed_run}]"
  classify
  has_line status=FAIL
}

@test "a failed or errored commit status is FAIL" {
  local s
  for s in FAILURE ERROR; do
    record 10 7 45
    checks "[{\"__typename\":\"StatusContext\",\"context\":\"ci/lint\",\"state\":\"${s}\",\"createdAt\":\"2026-10-19T00:00:10Z\"}]"
    classify
    has_line status=FAIL
  done
}

@test "a re-run that passed supersedes the failed run of the same check" {
  record 10 7 45
  checks "[${failed_run}, $(jq -c '.conclusion = "SUCCESS" | .startedAt = "2026-10-19T00:03:00Z"' <<<"${failed_run}")]"
  classify
  has_line status=PASS
}

@test "a failure already frozen by this loop for the same merge commit is HANDLED" {
  record 10 7 45
  freeze 11 m111
  checks "[${failed_run}]"
  classify
  [ "${status}" -eq 0 ]
  has_line status=HANDLED
  has_line next=proceed
  reason_has "freeze 11"
}

@test "a merge checked too soon after it landed waits instead of passing" {
  record 10 7 45
  now='2026-10-19T00:01:00Z'
  classify
  [ "${status}" -eq 0 ]
  has_line status=PENDING
  has_line next=wait
  reason_has "settling"
}

@test "a check still pending an hour after the merge is UNCONFIRMED and freezes" {
  record 10 7 45
  checks "[${pending_run}]"
  now='2026-10-19T01:00:00Z'
  classify
  [ "${status}" -eq 0 ]
  has_line status=UNCONFIRMED
  has_line next=freeze
  reason_has "still pending"
}

@test "a freeze for UNCONFIRMED does not handle a later FAIL on the same merge" {
  record 10 7 45
  freeze 11 m111 loop UNCONFIRMED
  checks "[${failed_run}]"
  classify
  has_line status=FAIL
  has_line next=freeze
}

@test "a freeze without a health line handles nothing" {
  record 10 7 45
  add 11 2026-10-19T00:10:00Z loop "$(printf '%s\n' '<!-- orchestrate-epic:freeze -->' '- reason: x' '- merge: m111')"
  checks "[${failed_run}]"
  classify
  has_line status=FAIL
}

@test "an unconfirmed merge already frozen for the same commit is HANDLED" {
  record 10 7 45
  freeze 11 m111 loop UNCONFIRMED
  pr '.mergeCommit.statusCheckRollup = null'
  now='2026-10-19T02:00:00Z'
  classify
  has_line status=HANDLED
}

@test "a freeze for another commit or by another login does not handle the failure" {
  record 10 7 45
  freeze 11 m999
  freeze 12 m111 mallory
  checks "[${failed_run}]"
  classify
  has_line status=FAIL
  has_line next=freeze
}

@test "a freeze naming the merge never hides a pending check" {
  record 10 7 45
  freeze 11 m111
  checks "[${pending_run}]"
  classify
  has_line status=PENDING
}

@test "the latest post-merge record wins" {
  record 10 3 40
  record 20 7 45
  classify
  has_line record_id=20
  has_line pr=7
  has_line issue=45
}

@test "a record without a readable pr or issue is UNREADABLE" {
  add 10 2026-10-18T23:59:00Z loop "$(printf '%s\n' '<!-- orchestrate-epic:post-merge -->' '- pr: x' '- issue: 45')"
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
  has_line next=hold
  comments='[]'
  add 10 2026-10-18T23:59:00Z loop "$(printf '%s\n' '<!-- orchestrate-epic:post-merge -->' '- pr: 7')"
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "a missing pull-request snapshot for a recorded merge is UNREADABLE" {
  record 10 7 45
  pull='null'
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "GraphQL errors are UNREADABLE" {
  record 10 7 45
  pull='{"errors":[{"message":"rate limited"}]}'
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
  reason_has "rate limited"
}

@test "a snapshot for a different PR than the record is UNREADABLE" {
  record 10 8 45
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "a merged PR without a merge commit is UNREADABLE" {
  record 10 7 45
  pr '.mergeCommit = null'
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "a truncated check list is UNREADABLE, never a pass" {
  record 10 7 45
  pr '.mergeCommit.statusCheckRollup.contexts.totalCount = 101'
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "an unknown check state is UNREADABLE" {
  record 10 7 45
  checks '[{"__typename":"CheckRun","name":"validate","status":null,"conclusion":null}]'
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "comments that are not an array are UNREADABLE" {
  comments='{"message":"Not Found"}'
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "a non-JSON snapshot is UNREADABLE" {
  run bash "${target}" --snapshot - --me loop <<<'not json'
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}
