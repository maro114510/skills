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
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  export OE_WAIT_INTERVAL=0
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  four_hours=14400
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

@test "a failed GitHub read ends the wait with an error and no next actions" {
  pr_15_checks_running

  GH_FAIL=graphql run --separate-stderr bash "${oe}" wait o/r 1 --timeout 60

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

@test "a second wait for the same Epic stops the first quietly, so at most one runs" {
  pr_15_checks_running
  first="$(background_wait 1)"
  recorded "${first}"

  second="$(background_wait 1)"

  ended "${first}"
  [ ! -s "${BATS_TEST_TMPDIR}/wait-${first}.out" ]
  kill -0 "${second}"
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
