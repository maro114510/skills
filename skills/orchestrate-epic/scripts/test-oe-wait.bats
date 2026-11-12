#!/usr/bin/env bats
# Tests for oe wait.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe wait against them.
# - testdata/records.bash writes the host-local records under the test's own OE_STATE_DIR.
# - testdata/fake-gh.sh stands in for gh and answers every read from that state.
# - OE_GITHUB_NEXT swaps in a second state at the second poll, so a change lands at a point the test controls.
# - OE_WAIT_INTERVAL=0 polls without sleeping, so a test waits only as long as its --timeout.
# - Every test runs at 08:00 on the same day.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  load testdata/records
  load testdata/agents
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  export OE_WAIT_INTERVAL=0
  unset OE_WORKTREE_ROOT
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  four_hours=14400
  # An empty value overrides any notification command the user's own git config sets, so no test notifies the user.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=skills.notify GIT_CONFIG_VALUE_0=
  notified="${BATS_TEST_TMPDIR}/notified"
}

# Sets the notification command, through the git config skills.notify that oe reads, to one that appends each call's message and link to $notified, separated by a tab.
notification_command() {
  export GIT_CONFIG_VALUE_0="printf '%s\\t%s\\n' \"\$1\" \"\$2\" >>'${notified}'"
}

# Prints the number of calls the notification command received.
notification_count() {
  if [ -e "${notified}" ]; then
    wc -l <"${notified}" | tr -d ' '
  else
    echo 0
  fi
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Saves, from stdin, the state that replaces the current one at the second poll.
github_at_second_poll() {
  export OE_GITHUB_NEXT="${BATS_TEST_TMPDIR}/github-next.json"
  cat >"${OE_GITHUB_NEXT}"
}

# Saves a state where Issue 5, claimed and attempted once, has its PR 15 still running a check.
pr_15_checks_running() {
  records 5 claim@07:00 attempt@07:01
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"test": "in_progress"}}]
  }]
}
JSON
}

# Prints the action that the output gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

@test "wait returns the new next actions as soon as the state changes between two polls" {
  pr_15_checks_running
  github_at_second_poll <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"test": "success"}}]
  }]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 60

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "a reason whose elapsed time grows between polls while every action stays the same does not end the wait" {
  records 5 claim@07:00
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 15, "opened": "07:55"}]
  }]
}
JSON
  github_at_second_poll <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 15, "opened": "07:54"}]
  }]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "wait returns at the timeout with the unchanged next actions when nothing changes" {
  pr_15_checks_running

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(action_of 5)" = wait-ci ]
}

# Saves a state where Issue 5, claimed and attempted once, waits for the answer to its question.
issue_5_waits_for_an_answer() {
  records 5 claim@07:00 attempt@07:01
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"}]
  }]
}
JSON
}

@test "with every Issue waiting on a person and nothing changing for hours, wait runs until its timeout" {
  issue_5_waits_for_an_answer
  unchanged_since_four_hours_ago="$((OE_NOW - four_hours))"

  run bash "${oe}" wait o/r 1 --timeout 1 --idle-since "${unchanged_since_four_hours_ago}"

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "an answer that arrives on an Issue waiting on a person returns the wait with the Issue's Owner to start" {
  issue_5_waits_for_an_answer
  github_at_second_poll <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "OWNER", "at": "07:20", "body": "Use option A"}
    ]
  }]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 60

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# Saves a state where Issue 5 has no branch yet and nothing blocks its claim.
issue_5_ready_to_claim() {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}]
}
JSON
}

@test "a first read that holds an Issue to start returns it at once, before any change" {
  issue_5_ready_to_claim

  run bash "${oe}" wait o/r 1 --timeout 2

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

# Saves a state where Issue 5 has no branch yet and nothing blocks its claim, and Issues 6 to 8 have no branch either.
issues_5_to_8_ready_to_claim() {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}, {"number": 6}, {"number": 7}, {"number": 8}]
}
JSON
}

@test "with as many agents running as --max-agents allows, an Issue to start at the first read keeps the wait running until the timeout" {
  issues_5_to_8_ready_to_claim
  session_holds_lock
  agent_runs 6 owner
  agent_runs 7 verifier

  run bash "${oe}" wait o/r 1 --max-agents 2 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = claim ]
}

@test "with --max-agents 0, as after a start that failed with no agent running, an Issue to start at the first read keeps the wait running until the timeout" {
  issue_5_ready_to_claim

  run bash "${oe}" wait o/r 1 --max-agents 0 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = claim ]
}

@test "without --max-agents, three running agents keep an Issue to start from ending the wait, as the skill's default of three agents" {
  issues_5_to_8_ready_to_claim
  session_holds_lock
  agent_runs 6 owner
  agent_runs 7 owner
  agent_runs 8 verifier

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
}

@test "running agents counted from oe's own records, below --max-agents, let an Issue to start at the first read return the wait at once" {
  issues_5_to_8_ready_to_claim
  session_holds_lock
  agent_runs 6 owner

  run bash "${oe}" wait o/r 1 --max-agents 2 --timeout 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
  [ "$(action_of 6)" = running ]
}

# Ends the agent on Issue $1 once oe wait has finished its first poll, within about thirty seconds.
# The fake gh counts Epic reads only under GH_FAIL_EPIC_READ, so the test sets it to a read that never comes.
ends_after_first_poll() {
  local _
  for _ in $(seq 300); do
    if [ "$(cat "${OE_GITHUB}.epic-reads" 2>/dev/null || echo 0)" -ge 2 ]; then
      agent_ends "$1"
      return 0
    fi
    sleep 0.1
  done
}

@test "an agent that ends during a wait makes that wait return with the Issue's new action" {
  pr_15_checks_running
  session_holds_lock
  agent_runs 5 owner
  ends_after_first_poll 5 3>&- &

  GH_FAIL_EPIC_READ=1000 OE_WAIT_INTERVAL=1 run --separate-stderr bash "${oe}" wait o/r 1 --timeout 30

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a failed first read keeps the wait running, and the next read comes no sooner than the poll interval" {
  issue_5_ready_to_claim
  interval=2

  GH_FAIL_EPIC_READ=1 OE_WAIT_INTERVAL="${interval}" run --separate-stderr bash "${oe}" wait o/r 1 --timeout 60

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
  failed_read="$(sed -n 1p "${OE_GITHUB}.epic-read-times")"
  next_read="$(sed -n 2p "${OE_GITHUB}.epic-read-times")"
  [ "$((next_read - failed_read))" -ge "${interval}" ]
}

@test "a read that fails after the first keeps the wait running until the timeout, with the latest next actions" {
  pr_15_checks_running

  GH_FAIL_EPIC_READ=2 run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "reads failing until the timeout end the wait with an error and no next actions" {
  pr_15_checks_running

  GH_FAIL=graphql run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  case "${stderr}" in
  *"Epic read failed"*) ;;
  *) return 1 ;;
  esac
}

@test "a default branch head without checks past the grace holds nothing, so the wait returns the Issue to claim" {
  github <<'JSON'
{
  "default_branch": {"pushed": "07:00"},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "an agent cap written with a leading zero is refused" {
  pr_15_checks_running

  run --separate-stderr bash "${oe}" wait o/r 1 --max-agents 08 --timeout 0

  [ "${status}" -eq 2 ]
}

@test "a timeout that is not a whole number of seconds is refused" {
  pr_15_checks_running

  run --separate-stderr bash "${oe}" wait o/r 1 --timeout soon

  [ "${status}" -eq 2 ]
}

# Starts oe wait for Epic $1 in the background with a long timeout, and prints its process ID.
# Its output goes to wait-<pid>.out, and it polls once a second, so it stays in its loop until stopped.
background_wait() {
  local out="${BATS_TEST_TMPDIR}/wait.$$.${RANDOM}.out"
  OE_WAIT_INTERVAL=1 bash "${oe}" wait o/r "$1" --timeout 600 --running 5 >"${out}" 2>&1 3>&- &
  echo $! >>"${BATS_TEST_TMPDIR}/waits"
  mv "${out}" "${BATS_TEST_TMPDIR}/wait-$!.out"
  echo $!
}

# Stops every wait a test started, with its process tree, so a failed test leaves none running.
teardown() {
  stop_sessions
  [ -e "${BATS_TEST_TMPDIR}/waits" ] || return 0
  while read -r pid; do
    pkill -P "${pid}" 2>/dev/null || true
    kill "${pid}" 2>/dev/null || true
  done <"${BATS_TEST_TMPDIR}/waits"
}

# Succeeds once process $1 has ended, within about five seconds.
ended() {
  local _
  for _ in $(seq 50); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# Succeeds once oe wait has recorded process $1 for an Epic, within about five seconds.
recorded() {
  local _
  for _ in $(seq 50); do
    find "${OE_STATE_DIR}" -path '*/waits/*' -type f -exec grep -qx "$1 .*" {} \; -print 2>/dev/null | grep -q . && return 0
    sleep 0.1
  done
  return 1
}

@test "starting a wait while one runs for the same Epic stops no process, and returns at once with the latest next actions" {
  pr_15_checks_running
  first="$(background_wait 1)"
  recorded "${first}"

  run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 6 ]
  [ "$(action_of 5)" = wait-ci ]
  kill -0 "${first}"
}

@test "a wait for another Epic leaves the first running" {
  pr_15_checks_running
  first="$(background_wait 1)"
  recorded "${first}"

  other="$(background_wait 2)"
  recorded "${other}"

  kill -0 "${first}"
}

@test "an invalid wait leaves the running one alone" {
  pr_15_checks_running
  first="$(background_wait 1)"
  recorded "${first}"

  run env OE_WAIT_INTERVAL=soon bash "${oe}" wait o/r 1 --timeout 0

  [ "${status}" -eq 2 ]
  kill -0 "${first}"
}

@test "a recorded process that is no longer a wait is left running" {
  pr_15_checks_running
  first="$(background_wait 1)"
  recorded "${first}"
  kill "${first}"
  ended "${first}"
  sleep 30 &
  bystander=$!
  echo "${bystander}" >>"${BATS_TEST_TMPDIR}/waits"
  record="$(find "${OE_STATE_DIR}" -path '*/waits/*' -type f)"
  # ps prints start times to the second, so the first wait's start time could match a bystander started in the same second.
  start_no_process_has="Thu Jan  1 00:00:00 1970"
  printf '%s %s\n' "${bystander}" "${start_no_process_has}" >"${record}"

  run bash "${oe}" wait o/r 1 --timeout 0 --running 5

  kill -0 "${bystander}"
}

@test "a wait that ends on its own leaves no record of itself" {
  pr_15_checks_running

  run bash "${oe}" wait o/r 1 --timeout 0 --running 5

  [ "${status}" -eq 5 ]
  [ -z "$(find "${OE_STATE_DIR}" -path '*/waits/*' -type f 2>/dev/null)" ]
}

@test "releasing the Epic's lock stops its wait, and leaves another Epic's wait running" {
  pr_15_checks_running
  sleep 600 >/dev/null 2>&1 3>&- &
  session=$!
  echo "${session}" >>"${BATS_TEST_TMPDIR}/waits"
  token="$(OE_SESSION_PID="${session}" bash "${oe}" lock acquire o/r 1 | sed -n 's/^token=//p')"
  first="$(background_wait 1)"
  other="$(background_wait 2)"
  recorded "${first}"
  recorded "${other}"

  run bash "${oe}" lock release o/r 1 "${token}"

  [ "${status}" -eq 0 ]
  ended "${first}"
  [ ! -s "${BATS_TEST_TMPDIR}/wait-${first}.out" ]
  kill -0 "${other}"
}

@test "a session that takes over the Epic's lock from an ended session stops the wait that session left" {
  pr_15_checks_running
  sleep 600 >/dev/null 2>&1 3>&- &
  ended_session=$!
  echo "${ended_session}" >>"${BATS_TEST_TMPDIR}/waits"
  OE_SESSION_PID="${ended_session}" bash "${oe}" lock acquire o/r 1 >/dev/null
  left="$(background_wait 1)"
  recorded "${left}"
  { kill "${ended_session}" && wait "${ended_session}"; } 2>/dev/null || true
  sleep 600 >/dev/null 2>&1 3>&- &
  new_session=$!
  echo "${new_session}" >>"${BATS_TEST_TMPDIR}/waits"

  OE_SESSION_PID="${new_session}" run bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 0 ]
  ended "${left}"
}

@test "a session acquiring its own lock again leaves its wait running" {
  pr_15_checks_running
  sleep 600 >/dev/null 2>&1 3>&- &
  session=$!
  echo "${session}" >>"${BATS_TEST_TMPDIR}/waits"
  token="$(OE_SESSION_PID="${session}" bash "${oe}" lock acquire o/r 1 | sed -n 's/^token=//p')"
  first="$(background_wait 1)"
  recorded "${first}"

  OE_SESSION_PID="${session}" run bash "${oe}" lock acquire o/r 1 "${token}"

  [ "${status}" -eq 0 ]
  kill -0 "${first}"
}

# Notifications

@test "a question waiting for an answer calls the notification command once, with a message and the Issue's link" {
  notification_command
  issue_5_waits_for_an_answer

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(cat "${notified}")" = $'Issue #5 in o/r has a question for you\thttps://github.com/o/r/issues/5' ]
}

@test "a parked Issue calls the notification command once, with the park's reason and the Issue's link" {
  notification_command
  records 5 claim@07:00 attempt@07:01
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "pushed": "07:40"}]
  }]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(notification_count)" -eq 1 ]
  case "$(cat "${notified}")" in
  "Issue #5 in o/r is parked: no checks on "*$'\thttps://github.com/o/r/issues/5') ;;
  *) return 1 ;;
  esac
}

@test "an Issue waiting for a person calls the notification command once, with the reason and the Issue's link" {
  notification_command
  records 5 claim@07:00
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40"}]
  }]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(cat "${notified}")" = $'Issue #5 in o/r waits for you: PR #50 merged; the Issue is still open\thttps://github.com/o/r/issues/5' ]
}

@test "an Issue waiting for a merge calls the notification command once, with the Issue's link" {
  notification_command
  records 5 claim@07:00 attempt@07:01
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success", "pending"]}]
  }]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(notification_count)" -eq 1 ]
  case "$(cat "${notified}")" in
  "Issue #5 in o/r waits for your merge: success verdict on "*$'\thttps://github.com/o/r/issues/5') ;;
  *) return 1 ;;
  esac
}

@test "reads that keep failing call the notification command once, with the Epic's link" {
  notification_command
  pr_15_checks_running

  GH_FAIL=graphql run --separate-stderr bash "${oe}" wait o/r 1 --timeout 3

  [ "${status}" -eq 1 ]
  [ "$(cat "${notified}")" = $'oe cannot read GitHub for Epic #1 in o/r: 3 reads in a row failed\thttps://github.com/o/r/issues/1' ]
}

@test "a single failed read calls nothing" {
  notification_command
  pr_15_checks_running

  GH_FAIL_EPIC_READ=2 run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(notification_count)" -eq 0 ]
}

@test "an Epic whose every Issue is done calls the notification command once, saying the session ends because the Epic is done" {
  notification_command
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "closed": true}]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(cat "${notified}")" = $'Epic #1 in o/r is done; the session ends\thttps://github.com/o/r/issues/1' ]
}

@test "oe ready failing with an error that ends the session calls the notification command once, with the exit code" {
  notification_command
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=skills.bot GIT_CONFIG_VALUE_1='not a login'
  pr_15_checks_running

  run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 1 ]
  [ "$(cat "${notified}")" = $'oe ready failed for Epic #1 in o/r with exit 2; the session ends\thttps://github.com/o/r/issues/1' ]
}

@test "an Issue still waiting at a later wait within the repeat interval calls nothing again" {
  notification_command
  issue_5_waits_for_an_answer
  bash "${oe}" wait o/r 1 --timeout 0 >/dev/null || true
  just_under_an_hour_later="$((OE_NOW + 3599))"

  OE_NOW="${just_under_an_hour_later}" run bash "${oe}" wait o/r 1 --timeout 0

  [ "${status}" -eq 5 ]
  [ "$(notification_count)" -eq 1 ]
}

@test "an Issue still waiting once the repeat interval has passed calls the notification command again" {
  notification_command
  issue_5_waits_for_an_answer
  bash "${oe}" wait o/r 1 --timeout 0 >/dev/null || true
  an_hour_later="$((OE_NOW + 3600))"

  OE_NOW="${an_hour_later}" run bash "${oe}" wait o/r 1 --timeout 0

  [ "${status}" -eq 5 ]
  [ "$(notification_count)" -eq 2 ]
}

@test "an Issue that stopped waiting and waits again calls the notification command again, within the repeat interval" {
  notification_command
  issue_5_waits_for_an_answer
  bash "${oe}" wait o/r 1 --timeout 0 >/dev/null || true
  pr_15_checks_running
  bash "${oe}" wait o/r 1 --timeout 0 >/dev/null || true
  issue_5_waits_for_an_answer

  run bash "${oe}" wait o/r 1 --timeout 0

  [ "${status}" -eq 5 ]
  [ "$(notification_count)" -eq 2 ]
}

@test "with no notification command configured, every event calls nothing and the wait exits as it did" {
  issue_5_waits_for_an_answer
  run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1
  [ "${status}" -eq 5 ]
  [ -z "${stderr}" ]

  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "closed": true}]
}
JSON
  run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1
  [ "${status}" -eq 5 ]
  [ -z "${stderr}" ]

  GH_FAIL=graphql run --separate-stderr bash "${oe}" wait o/r 1 --timeout 3
  [ "${status}" -eq 1 ]

  [ ! -e "${notified}" ]
  [ -z "$(find "${OE_STATE_DIR}" -path '*/notices/*' 2>/dev/null)" ]
}

@test "every poll saves the facts it read, so oe status can draw them without GitHub" {
  pr_15_checks_running

  run bash "${oe}" wait o/r 1 --timeout 0

  [ "${status}" -eq 5 ]
  [ "$(jq -r '.lines[0].action' "$(facts_record o/r 1)")" = wait-ci ]
  [ "$(jq -r '.at' "$(facts_record o/r 1)")" = "${OE_NOW}" ]
}

@test "a poll that fails to read GitHub records the failure and keeps the facts" {
  pr_15_checks_running
  run bash "${oe}" wait o/r 1 --timeout 0
  [ "${status}" -eq 5 ]

  GH_FAIL=subIssues run bash "${oe}" wait o/r 1 --timeout 0

  [ "${status}" -eq 1 ]
  [ "$(jq -r '.lines[0].action' "$(facts_record o/r 1)")" = wait-ci ]
  [ -n "$(jq -r '.failure.reason' "$(facts_record o/r 1)")" ]
}
