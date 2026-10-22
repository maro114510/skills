#!/usr/bin/env bats
# Tests for wait.sh, evaluate.jq, ledger.sh, and check.sh. Each case edits one clean normalized
# pr-state snapshot with jq and evaluates it through --snapshot, so no test calls GitHub.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  git init -q "${BATS_TEST_TMPDIR}/repo"
  cd "${BATS_TEST_TMPDIR}/repo" || return 1
  export BABYSIT_NOW=1000000
  token="tok-1"
  snap="${BATS_TEST_TMPDIR}/snap.json"
  # READY: open, mergeable, one passing Actions check, approved without a review body, nothing pending.
  clean='{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
    "author":"me","viewer":"me","isCrossRepository":false,"baseRef":"main","headRef":"feat/x","head":"aaa",
    "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED",
    "checks":[{"key":"github-actions/.github/workflows/ci.yml/pull_request/test","name":"test","workflow":"CI",
      "kind":"check_run","rerunnable":true,"status":"pass","runId":100,"workflowRunId":10,"attempt":1,
      "url":"https://example.invalid/run/100","startedAt":"2026-01-01T00:00:00Z"}],
    "reviewRequests":[],"latestReviews":[{"author":"bob","state":"APPROVED"}],
    "threads":[],
    "reviews":[{"id":"R1","author":"bob","authorAssociation":"MEMBER","body":"","bodyHash":"e0","createdAt":"2026-01-01T00:00:00Z",
      "url":"u","isMinimized":false,"state":"APPROVED"}],
    "comments":[]}'
  comment='{"id":"IC1","author":"carol","authorAssociation":"NONE","body":"please rename","bodyHash":"h1",
    "createdAt":"2026-01-02T00:00:00Z","url":"u","isMinimized":false}'
  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
  set_snap '.'
}

# Writes the clean snapshot after the jq edit $1.
set_snap() {
  jq -c --argjson comment "${comment}" "$1" <<<"${clean}" >"${snap}"
}

# Runs one wait call that evaluates the snapshot once and returns idle when nothing fires.
poll() {
  run bash "${scripts}/wait.sh" o/r 7 --max 0 --session "${token}" --snapshot "${snap}" "$@"
}

event() {
  jq -r '.event' <<<"${output}"
}

field() {
  jq -r "$1" <<<"${output}"
}

record() {
  bash "${scripts}/ledger.sh" record o/r 7 "${token}" "$@"
}

ledger() {
  bash "${scripts}/ledger.sh" show o/r 7 | jq -r "$1"
}

# Reports the current event in watch mode, as the skill does after showing it to the user.
report_current() {
  record "$(field .key)" reported --hash "$(field '.hash // ""')"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

# Not READY because a reviewer was requested and has not started, so nothing but items can fire.
waiting='.reviewRequests = [{reviewer: "dave", type: "User"}]'

@test "rejects bad arguments with exit 2" {
  run bash "${scripts}/wait.sh"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/wait.sh" noslash 7 --max 1 --session "${token}"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/wait.sh" ../x 7 --max 1 --session "${token}"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/wait.sh" o/r 0 --max 1 --session "${token}"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/wait.sh" o/r 7 --max x --session "${token}"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/wait.sh" o/r 7 --max 1
  [ "${status}" -eq 2 ]
  run bash "${scripts}/wait.sh" o/r 7 --max 1 --session "${token}" --mode check
  [ "${status}" -eq 2 ]
  run bash "${scripts}/wait.sh" o/r 7 --max 1 --session "${token}" --snapshot "${BATS_TEST_TMPDIR}/missing"
  [ "${status}" -eq 2 ]
}

@test "a session that does not hold the lock exits 3" {
  run bash "${scripts}/wait.sh" o/r 7 --max 0 --session other --snapshot "${snap}"
  [ "${status}" -eq 3 ]
  run bash "${scripts}/wait.sh" o/r 8 --max 0 --session "${token}" --snapshot "${snap}"
  [ "${status}" -eq 3 ]
}

@test "an unchanged snapshot evaluated 100 times emits zero events" {
  set_snap "${waiting} | .comments = [\$comment]"
  poll
  expect "$(event)" comment
  report_current
  for _ in $(seq 100); do
    poll
    [ "${status}" -eq 0 ]
    expect "$(event)" idle
  done
}

@test "a change to a failed check emits exactly one event" {
  set_snap "${waiting}"
  poll
  expect "$(event)" idle
  set_snap "${waiting} | .checks[0].status = \"failed\""
  poll
  expect "$(event)" check_failed
  expect "$(field .key)" "k:github-actions/.github/workflows/ci.yml/pull_request/test@aaa#0"
  expect "$(field .check.runId)" 100
  report_current
  poll
  expect "$(event)" idle
}

@test "a check that cannot be re-run is confirmed at once" {
  set_snap "${waiting} | .checks[0] += {status: \"failed\", rerunnable: false}"
  poll
  expect "$(event)" check_confirmed
}

@test "the same comment fetched repeatedly never re-notifies, and an edit does" {
  set_snap "${waiting} | .comments = [\$comment]"
  poll
  expect "$(event)" comment
  expect "$(field .key)" "c:IC1"
  expect "$(field .comment.body)" "please rename"
  report_current
  poll
  expect "$(event)" idle
  set_snap "${waiting} | .comments = [\$comment | .bodyHash = \"h2\"]"
  poll
  expect "$(event)" comment
}

@test "a head change re-evaluates checks but not comments" {
  set_snap "${waiting} | .checks[0].status = \"failed\" | .comments = [\$comment]"
  poll
  expect "$(event)" check_failed
  report_current
  poll
  expect "$(event)" comment
  report_current
  poll
  expect "$(event)" idle

  set_snap "${waiting} | .head = \"bbb\" | .checks[0].status = \"failed\" | .comments = [\$comment]"
  poll
  expect "$(event)" check_failed
  expect "$(field .key)" "k:github-actions/.github/workflows/ci.yml/pull_request/test@bbb#1"
  report_current
  poll
  expect "$(event)" idle

  # Back to the first SHA: a fresh generation, so its old report does not hide the failure.
  set_snap "${waiting} | .checks[0].status = \"failed\" | .comments = [\$comment]"
  poll
  expect "$(event)" check_failed
  expect "$(field .key)" "k:github-actions/.github/workflows/ci.yml/pull_request/test@aaa#2"
}

@test "a head change by itself is not an event" {
  set_snap "${waiting}"
  poll
  expect "$(event)" idle
  set_snap "${waiting} | .head = \"bbb\""
  poll
  expect "$(event)" idle
  expect "$(ledger .head.gen)" 1
}

@test "a check moving from pending to pass is not an event" {
  set_snap "${waiting} | .checks[0].status = \"pending\""
  poll
  expect "$(event)" idle
  set_snap "${waiting}"
  poll
  expect "$(event)" idle
}

@test "the agent's own replies never become events" {
  ledger_path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  jq '.own.replies = [{hash: "h1", id: null}, {hash: "zz", id: "IC2"}]' "${ledger_path}" >"${ledger_path}.new"
  mv "${ledger_path}.new" "${ledger_path}"
  set_snap "${waiting} | .comments = [\$comment, (\$comment | .id = \"IC2\" | .bodyHash = \"h9\")]"
  poll
  expect "$(event)" idle
}

@test "an approval without a body is not an event, and a review body is" {
  set_snap "${waiting}"
  poll
  expect "$(event)" idle
  set_snap "${waiting} | .reviews += [{id: \"R2\", author: \"bob\", body: \"nit: naming\", bodyHash: \"r2\", state: \"COMMENTED\", isMinimized: false, createdAt: \"2026-01-03\"}]"
  poll
  expect "$(event)" comment
  expect "$(field .comment.kind)" review
}

@test "resolved threads and minimized comments are not events" {
  set_snap "${waiting} | .threads = [{id: \"T1\", isResolved: true, path: \"a.sh\", line: 3, comments: [\$comment | .id = \"TC1\"]}]
    | .comments = [\$comment | .isMinimized = true]"
  poll
  expect "$(event)" idle
  set_snap "${waiting} | .threads = [{id: \"T1\", isResolved: false, path: \"a.sh\", line: 3, comments: [\$comment | .id = \"TC1\"]}]"
  poll
  expect "$(event)" comment
  expect "$(field .comment.thread)" T1
  expect "$(field .comment.path)" a.sh
}

@test "a conflict fires once per head" {
  set_snap "${waiting} | .mergeable = \"CONFLICTING\" | .mergeStateStatus = \"DIRTY\""
  poll
  expect "$(event)" conflict
  expect "$(field .key)" "x:aaa#0"
  report_current
  poll
  expect "$(event)" idle
}

@test "merged, closed, and READY stop with a report" {
  set_snap '.state = "MERGED"'
  poll
  expect "$(event)" merged
  expect "$(field '.report | has("parked") and has("reported") and has("unresolved")')" true
  set_snap '.state = "CLOSED"'
  poll
  expect "$(event)" closed
  set_snap '.'
  poll
  expect "$(event)" ready
}

@test "a reviewer who never started blocks READY instead of reading as zero feedback" {
  set_snap "${waiting}"
  poll
  expect "$(event)" idle
  set_snap '.reviewDecision = "REVIEW_REQUIRED" | .latestReviews = [] | .reviews = []'
  poll
  expect "$(event)" idle
}

@test "unresolved threads, drafts, pending checks, and unknown mergeability block READY" {
  for edit in '.isDraft = true' '.checks[0].status = "pending"' '.mergeable = "UNKNOWN"' \
    '.threads = [{id: "T1", isResolved: false, path: "a", line: 1, comments: []}]' \
    '.latestReviews = [{author: "bob", state: "CHANGES_REQUESTED"}]'; do
    set_snap "${edit}"
    poll
    expect "$(event)" idle
  done
}

@test "a head without checks for 10 minutes counts as having no CI" {
  set_snap '.checks = []'
  poll
  expect "$(event)" idle
  BABYSIT_NOW=$((BABYSIT_NOW + 599)) poll
  expect "$(event)" idle
  BABYSIT_NOW=$((BABYSIT_NOW + 600)) poll
  expect "$(event)" ready
}

@test "8 hours after the session started the limit fires" {
  set_snap "${waiting}"
  BABYSIT_NOW=$((BABYSIT_NOW + 28800)) poll
  expect "$(event)" limit
}

@test "5 used rounds fire the limit only while a repairable item is pending" {
  ledger_path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  jq '.rounds = 5' "${ledger_path}" >"${ledger_path}.new"
  mv "${ledger_path}.new" "${ledger_path}"
  set_snap "${waiting}"
  poll
  expect "$(event)" idle
  set_snap "${waiting} | .comments = [\$comment]"
  poll
  expect "$(event)" limit
}

@test "drive acts on items watch only reported, and stalls once only parked blockers remain" {
  set_snap "${waiting} | .threads = [{id: \"T1\", isResolved: false, path: \"a\", line: 1, comments: [\$comment | .id = \"TC1\"]}]"
  poll
  expect "$(event)" comment
  report_current
  poll
  expect "$(event)" idle
  poll --mode drive
  expect "$(event)" comment
  record c:TC1 parked --hash h1
  poll --mode drive
  expect "$(event)" stalled
  expect "$(field '.report.parked[0]')" c:TC1
}

@test "a re-run check waits for a newer run, which confirms a failure" {
  set_snap "${waiting} | .checks[0].status = \"failed\""
  poll --mode drive
  expect "$(event)" check_failed
  record "$(field .key)" rerun --run-id 100
  poll --mode drive
  expect "$(event)" idle
  set_snap "${waiting} | .checks[0] += {status: \"failed\", runId: 101, attempt: 2}"
  poll --mode drive
  expect "$(event)" check_confirmed
  expect "$(field .check.runId)" 101
}

@test "a check failing after 2 repair pushes is stuck" {
  ledger_path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  jq '.repairs["github-actions/.github/workflows/ci.yml/pull_request/test"] = 2' "${ledger_path}" >"${ledger_path}.new"
  mv "${ledger_path}.new" "${ledger_path}"
  set_snap "${waiting} | .checks[0].status = \"failed\""
  poll --mode drive
  expect "$(event)" check_stuck
}

@test "several pending items come out one per call in table order" {
  set_snap "${waiting} | .comments = [\$comment] | .checks[0].status = \"failed\" | .mergeable = \"CONFLICTING\""
  poll
  expect "$(event)" conflict
  report_current
  poll
  expect "$(event)" check_failed
  report_current
  poll
  expect "$(event)" comment
}

@test "wait records the head and refreshes the heartbeat" {
  set_snap "${waiting}"
  BABYSIT_NOW=$((BABYSIT_NOW + 5)) poll
  expect "$(ledger .head.sha)" aaa
  expect "$(ledger '.heads.aaa.first_seen')" $((BABYSIT_NOW + 5))
  expect "$(ledger .lock.heartbeat)" $((BABYSIT_NOW + 5))
}

@test "repeated API failures back off and end in exit 1 at the limit" {
  stub="${BATS_TEST_TMPDIR}/pr-state"
  printf '#!/usr/bin/env bash\necho call >>"%s/calls"\nexit 1\n' "${BATS_TEST_TMPDIR}" >"${stub}"
  chmod +x "${stub}"
  # shellcheck disable=SC2016 # $1 belongs to the generated stub.
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/sleeps"\n' "${BATS_TEST_TMPDIR}" >"${BATS_TEST_TMPDIR}/sleep"
  chmod +x "${BATS_TEST_TMPDIR}/sleep"
  BABYSIT_PR_STATE="${stub}" BABYSIT_SLEEP="${BATS_TEST_TMPDIR}/sleep" \
    run bash "${scripts}/wait.sh" o/r 7 --max 60 --session "${token}"
  [ "${status}" -eq 1 ]
  expect "$(wc -l <"${BATS_TEST_TMPDIR}/calls" | tr -d ' ')" 5
  expect "$(tr '\n' ' ' <"${BATS_TEST_TMPDIR}/sleeps")" "30 60 120 240 "
  expect "$(ledger .api_failures)" 5
}

@test "API failures count across re-arms, and a success resets them" {
  stub="${BATS_TEST_TMPDIR}/pr-state"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${stub}"
  chmod +x "${stub}"
  BABYSIT_PR_STATE="${stub}" run bash "${scripts}/wait.sh" o/r 7 --max 0 --session "${token}"
  [ "${status}" -eq 0 ]
  expect "$(event)" idle
  expect "$(ledger .api_failures)" 1
  poll
  expect "$(ledger .api_failures)" 0
  ledger_path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  jq '.api_failures = 4' "${ledger_path}" >"${ledger_path}.new"
  mv "${ledger_path}.new" "${ledger_path}"
  BABYSIT_PR_STATE="${stub}" run bash "${scripts}/wait.sh" o/r 7 --max 0 --session "${token}"
  [ "${status}" -eq 1 ]
}

@test "ledger start refuses a live lock, takes over a stale one, and resets the session" {
  record c:IC1 reported --hash h1
  run bash "${scripts}/ledger.sh" start o/r 7 tok-2
  [ "${status}" -eq 3 ]
  BABYSIT_NOW=$((BABYSIT_NOW + 4200)) run bash "${scripts}/ledger.sh" start o/r 7 tok-2
  [ "${status}" -eq 0 ]
  expect "$(ledger .lock.token)" tok-2
  expect "$(ledger .started_at)" $((BABYSIT_NOW + 4200))
  expect "$(ledger '.items["c:IC1"].disposition')" reported
  run bash "${scripts}/ledger.sh" record o/r 7 "${token}" c:IC1 handled
  [ "${status}" -eq 3 ]
  run bash "${scripts}/ledger.sh" stop o/r 7 "${token}"
  [ "${status}" -eq 3 ]
  run bash "${scripts}/ledger.sh" stop o/r 7 tok-2
  [ "${status}" -eq 0 ]
  expect "$(ledger '.lock // "none"')" none
}

@test "ledger rejects bad dispositions and a re-run without its run id" {
  run bash "${scripts}/ledger.sh" record o/r 7 "${token}" c:IC1 finished
  [ "${status}" -eq 2 ]
  run bash "${scripts}/ledger.sh" record o/r 7 "${token}" k:x rerun
  [ "${status}" -eq 2 ]
  run bash "${scripts}/ledger.sh" record o/r 7 "${token}" c:IC1 reported
  [ "${status}" -eq 2 ]
}

@test "the ledger and its lock ignore the case of the repository name" {
  expect "$(bash "${scripts}/ledger.sh" path O/R 7)" "$(bash "${scripts}/ledger.sh" path o/r 7)"
  run bash "${scripts}/ledger.sh" start O/R 7 tok-2
  [ "${status}" -eq 3 ]
}

@test "check reports once and writes nothing" {
  ledger_path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  before="$(cat "${ledger_path}")"
  set_snap "${waiting} | .comments = [\$comment]"
  run bash "${scripts}/check.sh" o/r 7 --snapshot "${snap}"
  [ "${status}" -eq 0 ]
  expect "$(field .status)" NOT_READY
  expect "$(field .event.event)" comment
  expect "$(field '.blockers | any(test("dave"))')" true
  expect "$(cat "${ledger_path}")" "${before}"
  set_snap '.'
  run bash "${scripts}/check.sh" o/r 7 --snapshot "${snap}"
  expect "$(field .status)" READY
}

@test "check without a ledger or a Git repository still reports" {
  cd "${BATS_TEST_TMPDIR}" || return 1
  run bash "${scripts}/check.sh" o/r 9 --snapshot "${snap}"
  [ "${status}" -eq 0 ]
  expect "$(field .status)" READY
}

@test "check exits 1 when GitHub cannot be read" {
  stub="${BATS_TEST_TMPDIR}/pr-state"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${stub}"
  chmod +x "${stub}"
  BABYSIT_PR_STATE="${stub}" run bash "${scripts}/check.sh" o/r 7
  [ "${status}" -eq 1 ]
}
