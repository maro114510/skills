#!/usr/bin/env bats
# Tests for wait.sh, evaluate.jq, ledger.sh, and check.sh. Each case edits one clean normalized
# pr-state snapshot with jq and evaluates it through --snapshot, so no test calls GitHub.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  git init -q "${BATS_TEST_TMPDIR}/repo"
  cd "${BATS_TEST_TMPDIR}/repo" || return 1
  export BABYSIT_NOW=1000000
  # A park wait makes itself must not show a real notification.
  export BABYSIT_OSASCRIPT="${BATS_TEST_TMPDIR}/no-osascript"
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
  comment='{"id":"IC1","author":"carol","authorAssociation":"COLLABORATOR","body":"please rename","bodyHash":"h1",
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
  expect "$(field .comment.excerpt)" "please rename"
  expect "$(field .comment.bodyLength)" 13
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

# A comment created before the session started (BABYSIT_NOW is 1970-01-12) and one by the viewer "me".
# shellcheck disable=SC2016 # $comment is a jq variable bound by set_snap.
before_start='.comments = [($comment | .id = "IC_old" | .author = "bot" | .bodyHash = "o1" | .createdAt = "1970-01-01T00:00:00Z"),
  ($comment | .id = "IC_mine" | .author = "me" | .bodyHash = "m1")]'

@test "watch fires no event for comments older than the session or by the viewer, and the report lists them" {
  set_snap "${waiting} | ${before_start}"
  poll
  expect "$(event)" idle
  set_snap "${before_start} | .state = \"CLOSED\""
  poll
  expect "$(event)" closed
  expect "$(field '[.report.muted[] | "\(.key) \(.author)"] | join(",")')" "c:IC_old bot,c:IC_mine me"
}

@test "watch fires an edit to a comment older than the session" {
  set_snap "${waiting} | ${before_start}"
  poll
  expect "$(event)" idle
  set_snap "${waiting} | ${before_start} | .comments[0].bodyHash = \"o2\""
  poll
  expect "$(event)" comment
  expect "$(field .key)" c:IC_old
}

@test "a comment event carries a 200-character excerpt and the body length, not the body" {
  set_snap "${waiting} | .comments = [\$comment | .body = (\"x\" * 5000)]"
  poll
  expect "$(event)" comment
  expect "$(field '.comment.excerpt | length')" 200
  expect "$(field .comment.bodyLength)" 5000
  expect "$(field .hash)" h1
  expect "$(field '.comment | has("body")')" false
}

@test "a new watch session takes a new baseline" {
  set_snap "${waiting} | ${before_start}"
  poll
  expect "$(ledger '.baseline["c:IC_old"]')" o1
  bash "${scripts}/ledger.sh" stop o/r 7 "${token}"
  bash "${scripts}/ledger.sh" start o/r 7 tok-2 >/dev/null
  expect "$(ledger '.baseline // "none"')" none
}

@test "drive still acts on comments older than the session and on the viewer's own" {
  set_snap "${waiting} | ${before_start}"
  poll --mode drive
  expect "$(field .key)" c:IC_old
  record c:IC_old handled --hash o1
  poll --mode drive
  expect "$(field .key)" c:IC_mine
}

@test "an unresolved thread hidden by the baseline still blocks READY" {
  set_snap ".threads = [{id: \"T1\", isResolved: false, path: \"a\", line: 1,
    comments: [\$comment | .id = \"TC_old\" | .createdAt = \"1970-01-01T00:00:00Z\"]}]"
  poll
  expect "$(event)" idle
  run bash "${scripts}/check.sh" o/r 7 --snapshot "${snap}"
  expect "$(field '.event')" null
  expect "$(field '.blockers | join(",")')" "1 unresolved review thread(s)"
}

@test "an approval without a body is not an event, and a review body is" {
  set_snap "${waiting}"
  poll
  expect "$(event)" idle
  set_snap "${waiting} | .reviews += [{id: \"R2\", author: \"bob\", authorAssociation: \"MEMBER\", body: \"nit: naming\", bodyHash: \"r2\", state: \"COMMENTED\", isMinimized: false, createdAt: \"2026-01-03\"}]"
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

@test "a draft approved at its head stops with approved in watch and drive" {
  set_snap '.isDraft = true | .latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"}]'
  poll
  expect "$(event)" approved
  expect "$(field '.report | has("parked") and has("unresolved")')" true
  poll --mode drive
  expect "$(event)" approved
  run bash "${scripts}/check.sh" o/r 7 --snapshot "${snap}"
  expect "$(field .event.event)" approved
}

@test "an approval on an older commit is not approved" {
  set_snap '.isDraft = true | .latestReviews = [{author: "bob", state: "APPROVED", commit: "old"}]'
  poll
  expect "$(event)" idle
}

@test "an approval at the head beside another reviewer's change request is not approved" {
  set_snap '.isDraft = true | .latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"},
    {author: "carol", state: "CHANGES_REQUESTED", commit: "aaa"}]'
  poll
  expect "$(event)" idle
}

@test "a bot's approval at the head is not approved" {
  set_snap '.isDraft = true | .latestReviews = [{author: "coderabbitai", authorType: "Bot", state: "APPROVED", commit: "aaa"}]'
  poll
  expect "$(event)" idle
}

@test "an approval at the head with a failing check is not approved, so drive repairs it" {
  set_snap '.latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"}]
    | .checks[0].status = "failed"'
  poll --mode drive
  expect "$(event)" check_failed
}

@test "an approval at the head with a check still running is not approved" {
  set_snap '.isDraft = true | .latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"}]
    | .checks[0].status = "pending"'
  poll
  expect "$(event)" idle
}

@test "an approval at the head that conflicts with the base is not approved, so drive merges the base" {
  set_snap '.latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"}]
    | .mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'
  poll --mode drive
  expect "$(event)" conflict
}

@test "an approval at the head whose mergeability GitHub has not computed is not approved" {
  set_snap '.isDraft = true | .latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"}]
    | .mergeable = "UNKNOWN"'
  poll
  expect "$(event)" idle
}

@test "an approval at a head without checks waits until the head counts as having no CI" {
  set_snap '.isDraft = true | .latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"}] | .checks = []'
  poll
  expect "$(event)" idle
  BABYSIT_NOW=$((BABYSIT_NOW + 600)) poll
  expect "$(event)" approved
}

@test "merged and closed outrank approved, and approved outranks READY" {
  approved_at_head='.latestReviews = [{author: "bob", state: "APPROVED", commit: "aaa"}]'
  set_snap "${approved_at_head} | .state = \"MERGED\""
  poll
  expect "$(event)" merged
  set_snap "${approved_at_head} | .state = \"CLOSED\""
  poll
  expect "$(event)" closed
  set_snap "${approved_at_head}"
  poll
  expect "$(event)" approved
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

@test "a limit stop lists every pending item with the key, who, and where to look" {
  ledger_path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  jq '.rounds = 5' "${ledger_path}" >"${ledger_path}.new"
  mv "${ledger_path}.new" "${ledger_path}"
  set_snap "${waiting} | .comments = [\$comment] | .checks[0].status = \"failed\""
  poll
  expect "$(event)" limit
  expect "$(field '.report.pending | length')" 2
  expect "$(field '.report.pending[] | select(.event == "comment") | [.key, .author, .url] | join(" ")')" "c:IC1 carol u"
  expect "$(field '.report.pending[] | select(.event == "check_failed") | [.name, .url] | join(" ")')" \
    "test https://example.invalid/run/100"
}

@test "drive leaves a reported comment quiet until its text changes, and stalls once only parked blockers remain" {
  set_snap "${waiting} | .threads = [{id: \"T1\", isResolved: false, path: \"a\", line: 1, comments: [\$comment | .id = \"TC1\"]}]"
  poll --mode drive
  expect "$(event)" comment
  report_current
  poll --mode drive
  expect "$(event)" idle
  run bash "${scripts}/check.sh" o/r 7 --mode drive --snapshot "${snap}"
  expect "$(field '.report.reported[0]')" c:TC1
  set_snap "${waiting} | .threads = [{id: \"T1\", isResolved: false, path: \"a\", line: 1,
    comments: [\$comment | .id = \"TC1\" | .bodyHash = \"h2\"]}]"
  poll --mode drive
  expect "$(event)" comment
  record c:TC1 parked --hash h2
  poll --mode drive
  expect "$(event)" stalled
  expect "$(field '.report.parked[0]')" c:TC1
}

@test "a stop report gives the reason of each parked item" {
  set_snap "${waiting} | .threads = [{id: \"T1\", isResolved: false, path: \"a\", line: 1, comments: [\$comment | .id = \"TC1\"]}]"
  record c:TC1 parked --hash h1 --reason "asks for a schema change"
  poll --mode drive
  expect "$(event)" stalled
  expect "$(field '.report.reasons["c:TC1"]')" "asks for a schema change"
}

@test "drive parks a comment whose author has no association as an untrusted author and returns no event" {
  set_snap "${waiting} | .comments = [\$comment | .authorAssociation = \"NONE\"]"
  poll --mode drive
  expect "$(event)" idle
  expect "$(ledger '.items["c:IC1"].disposition')" parked
  expect "$(ledger '.items["c:IC1"].reason')" "untrusted author"
  expect "$(ledger '.items["c:IC1"].hash')" h1
}

@test "drive parks a comment from a contributor, a first-timer, or an unknown association as an untrusted author" {
  set_snap "${waiting} | .comments = [
    (\$comment | .id = \"IC_contributor\" | .authorAssociation = \"CONTRIBUTOR\"),
    (\$comment | .id = \"IC_first_timer\" | .authorAssociation = \"FIRST_TIMER\"),
    (\$comment | .id = \"IC_first_contribution\" | .authorAssociation = \"FIRST_TIME_CONTRIBUTOR\"),
    (\$comment | .id = \"IC_mannequin\" | .authorAssociation = \"MANNEQUIN\"),
    (\$comment | .id = \"IC_unknown\" | del(.authorAssociation))]"
  poll --mode drive
  expect "$(event)" idle
  for id in IC_contributor IC_first_timer IC_first_contribution IC_mannequin IC_unknown; do
    expect "$(ledger ".items[\"c:${id}\"].reason")" "untrusted author"
  done
}

@test "drive hands an OWNER, MEMBER, or COLLABORATOR comment over as a comment event" {
  for association in OWNER MEMBER COLLABORATOR; do
    set_snap "${waiting} | .comments = [\$comment | .authorAssociation = \"${association}\"]"
    poll --mode drive
    expect "$(event)" comment
    expect "$(field .key)" c:IC1
  done
}

@test "drive hands a listed review bot's comment over as a comment event although the bot has no association" {
  for bot in coderabbitai chatgpt-codex-connector; do
    set_snap "${waiting} | .comments = [\$comment | .author = \"${bot}\" | .authorType = \"Bot\" | .authorAssociation = \"NONE\"]"
    poll --mode drive
    expect "$(event)" comment
    expect "$(field .comment.author)" "${bot}"
  done
}

@test "drive neither acts on nor parks the configured own bot's comment" {
  git config skills.bot agent-app
  set_snap "${waiting} | .comments = [\$comment | .author = \"agent-app\" | .authorType = \"Bot\" | .authorAssociation = \"NONE\"]"
  poll --mode drive
  expect "$(event)" idle
  expect "$(ledger '.items["c:IC1"].disposition // "none"')" none
}

@test "drive parks a user with the own bot's login, and the bot itself once none is configured, as untrusted authors" {
  set_snap "${waiting} | .comments = [
    (\$comment | .id = \"IC_user\" | .author = \"agent-app\" | .authorType = \"User\" | .authorAssociation = \"NONE\"),
    (\$comment | .id = \"IC_bot\" | .author = \"agent-app\" | .authorType = \"Bot\" | .authorAssociation = \"NONE\")]"
  git config skills.bot agent-app
  poll --mode drive
  expect "$(ledger '.items["c:IC_user"].reason')" "untrusted author"
  expect "$(ledger '.items["c:IC_bot"].disposition // "none"')" none
  git config --unset skills.bot
  poll --mode drive
  expect "$(ledger '.items["c:IC_bot"].reason')" "untrusted author"
}

@test "an approval by the own bot never makes the pull request approved" {
  git config skills.bot agent-app
  set_snap '.latestReviews = [{author: "agent-app", authorType: "Bot", state: "APPROVED", commit: "aaa"}]'
  poll --mode drive
  [ "$(event)" != approved ]
}

@test "drive parks a user who holds a listed bot's login, and a bot that is not listed, as untrusted authors" {
  set_snap "${waiting} | .comments = [
    (\$comment | .id = \"IC_user\" | .author = \"coderabbitai\" | .authorType = \"User\" | .authorAssociation = \"NONE\"),
    (\$comment | .id = \"IC_bot\" | .author = \"renovate\" | .authorType = \"Bot\" | .authorAssociation = \"NONE\")]"
  poll --mode drive
  expect "$(event)" idle
  expect "$(ledger '.items["c:IC_user"].reason')" "untrusted author"
  expect "$(ledger '.items["c:IC_bot"].reason')" "untrusted author"
}

@test "drive parks an untrusted thread comment and review body, and stalls once only they block" {
  set_snap "${waiting} | .threads = [{id: \"T1\", isResolved: false, path: \"a\", line: 1,
      comments: [\$comment | .id = \"TC1\" | .authorAssociation = \"NONE\"]}]
    | .reviews += [\$comment | .id = \"R2\" | .authorAssociation = \"NONE\" | .state = \"COMMENTED\"]"
  poll --mode drive
  expect "$(event)" stalled
  expect "$(field '.report.reasons["c:TC1"]')" "untrusted author"
  expect "$(field '.report.reasons["c:R2"]')" "untrusted author"
}

@test "drive parks an untrusted comment and returns the trusted comment after it in the same call" {
  set_snap "${waiting} | .comments = [(\$comment | .id = \"IC_out\" | .authorAssociation = \"NONE\"),
    (\$comment | .id = \"IC_in\" | .createdAt = \"2026-01-03T00:00:00Z\")]"
  poll --mode drive
  expect "$(event)" comment
  expect "$(field .key)" c:IC_in
  expect "$(ledger '.items["c:IC_out"].reason')" "untrusted author"
}

@test "an edited untrusted comment is parked again with its new text" {
  record c:IC1 parked --hash h1 --reason "untrusted author"
  set_snap "${waiting} | .comments = [\$comment | .authorAssociation = \"NONE\" | .bodyHash = \"h2\"]"
  poll --mode drive
  expect "$(event)" idle
  expect "$(ledger '.items["c:IC1"].hash')" h2
}

@test "5 used rounds do not fire the limit for an untrusted comment, which is parked instead" {
  path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  jq '.rounds = 5' "${path}" >"${path}.new" && mv "${path}.new" "${path}"
  set_snap "${waiting} | .comments = [\$comment | .authorAssociation = \"NONE\"]"
  poll --mode drive
  expect "$(event)" idle
  expect "$(ledger '.items["c:IC1"].reason')" "untrusted author"
}

@test "watch reports an untrusted comment as untrusted_comment and parks nothing" {
  set_snap "${waiting} | .comments = [\$comment | .authorAssociation = \"NONE\"]"
  poll
  expect "$(event)" untrusted_comment
  expect "$(field .key)" c:IC1
  expect "$(ledger '.items["c:IC1"] // "none"')" none
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

# Puts a fake gh first on PATH: every GraphQL call fails with the message $1, and the REST
# rate_limit endpoint reports $2 GraphQL points remaining until the epoch $3.
fake_gh() {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "api rate_limit" ]]; then
  echo '{"resources":{"graphql":{"limit":5000,"remaining":$2,"reset":$3}}}'
  exit 0
fi
echo "$1" >&2
exit 1
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

# Makes wait sleep through a stub that records each pause in the file sleeps instead of sleeping.
# The stub ends wait with TERM at the 6th pause, so a wait that loops on the pinned clock fails instead of hanging.
recording_sleep() {
  # shellcheck disable=SC2016 # $1 and $PPID belong to the generated stub.
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/sleeps"\n[ "$(wc -l <"%s/sleeps")" -lt 6 ] || kill "$PPID"\n' \
    "${BATS_TEST_TMPDIR}" "${BATS_TEST_TMPDIR}" >"${BATS_TEST_TMPDIR}/sleep"
  chmod +x "${BATS_TEST_TMPDIR}/sleep"
  export BABYSIT_SLEEP="${BATS_TEST_TMPDIR}/sleep"
}

sleeps() {
  tr '\n' ' ' <"${BATS_TEST_TMPDIR}/sleeps"
}

# Makes wait read GitHub through the real pr-state.sh on its first poll only, and the snapshot after it,
# as GitHub answers again once the rate limit resets.
recovering_pr_state() {
  cat >"${BATS_TEST_TMPDIR}/pr-state" <<EOF
#!/usr/bin/env bash
if [[ -e "${BATS_TEST_TMPDIR}/fetched" ]]; then
  cat "${snap}"
  exit 0
fi
: >"${BATS_TEST_TMPDIR}/fetched"
exec bash "${scripts}/pr-state.sh" "\$@"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/pr-state"
  export BABYSIT_PR_STATE="${BATS_TEST_TMPDIR}/pr-state"
}

@test "a GitHub failure other than the rate limit backs off and ends in exit 1" {
  fake_gh "HTTP 502: Bad Gateway (https://api.github.com/graphql)" 4999 1000600
  recording_sleep
  run bash "${scripts}/wait.sh" o/r 7 --max 60 --session "${token}"
  [ "${status}" -eq 1 ]
  expect "$(sleeps)" "30 60 120 240 "
  expect "$(ledger .api_failures)" 5
}

@test "a secondary rate limit with GraphQL points left backs off like any other failure" {
  fake_gh "You have exceeded a secondary rate limit. Please wait a few minutes before you try again." 4999 1000600
  recording_sleep
  run bash "${scripts}/wait.sh" o/r 7 --max 60 --session "${token}"
  [ "${status}" -eq 1 ]
  expect "$(sleeps)" "30 60 120 240 "
  expect "$(ledger .api_failures)" 5
}

# The rate_limit endpoint's reset when GitHub has drained the bucket 10 minutes before it refills.
reset_in_10_minutes=1000600
exhausted="GraphQL: API rate limit already exceeded for user ID 1."

@test "an exhausted GraphQL bucket shows the reset time, waits until it, and then polls again" {
  fake_gh "${exhausted}" 0 "${reset_in_10_minutes}"
  recording_sleep
  recovering_pr_state
  run bash "${scripts}/wait.sh" o/r 7 --max 60 --session "${token}"
  [ "${status}" -eq 0 ]
  grep -qF "waiting until 1970-01-12T13:56:40Z" <<<"${output}"
  expect "$(sleeps)" "600 "
  expect "$(jq -r .event <<<"$(tail -n1 <<<"${output}")")" ready
  expect "$(ledger .api_failures)" 0
}

@test "a rate-limit wait longer than --max ends at --max" {
  fake_gh "${exhausted}" 0 "${reset_in_10_minutes}"
  recording_sleep
  recovering_pr_state
  run bash "${scripts}/wait.sh" o/r 7 --max 1 --session "${token}"
  [ "${status}" -eq 0 ]
  expect "$(sleeps)" "60 "
  expect "$(jq -r .event <<<"$(tail -n1 <<<"${output}")")" ready
}

@test "a rate-limited call at --max returns idle without counting a failure and refreshes the heartbeat" {
  fake_gh "${exhausted}" 0 "${reset_in_10_minutes}"
  BABYSIT_NOW=$((BABYSIT_NOW + 5)) run bash "${scripts}/wait.sh" o/r 7 --max 0 --session "${token}"
  [ "${status}" -eq 0 ]
  expect "$(jq -r .event <<<"$(tail -n1 <<<"${output}")")" idle
  expect "$(ledger .api_failures)" 0
  expect "$(ledger .lock.heartbeat)" $((BABYSIT_NOW + 5))
}

@test "past the 8-hour mark a rate-limited call waits for the reset instead of returning at once" {
  eight_hours_later=$((BABYSIT_NOW + 28800))
  fake_gh "${exhausted}" 0 $((eight_hours_later + 600))
  recording_sleep
  recovering_pr_state
  set_snap "${waiting}"
  BABYSIT_NOW="${eight_hours_later}" run bash "${scripts}/wait.sh" o/r 7 --max 60 --session "${token}"
  [ "${status}" -eq 0 ]
  expect "$(sleeps)" "600 "
  expect "$(jq -r .event <<<"$(tail -n1 <<<"${output}")")" limit
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
