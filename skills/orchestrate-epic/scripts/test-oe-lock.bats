#!/usr/bin/env bats
# Tests for oe lock.
#
# - Each test keeps the lock under its own OE_STATE_DIR, so no test sees another's lock.
# - A session is a running process, started by the test and passed as OE_SESSION_PID.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  sessions=()
}

teardown() {
  for pid in ${sessions[@]+"${sessions[@]}"}; do
    kill "${pid}" 2>/dev/null || true
  done
}

# Starts a process that stands for one session, and sets session_pid to its PID.
start_session() {
  sleep 600 >/dev/null 2>&1 3>&- &
  session_pid=$!
  sessions+=("${session_pid}")
}

# Ends the session process $1 and waits until it is gone.
end_session() {
  kill "$1"
  wait "$1" 2>/dev/null || true
}

# Prints the token from the output of a successful acquire.
token_of() {
  printf '%s\n' "$1" | sed -n 's/^token=//p'
}

@test "a second session for the same Epic is refused while the first one runs" {
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  first_token="$(token_of "${output}")"
  [ -n "${first_token}" ]
  start_session

  OE_SESSION_PID="${session_pid}" run --separate-stderr bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 4 ]
  case "${stderr}" in
  *"pid=${first}"*) ;;
  *) return 1 ;;
  esac
  OE_SESSION_PID="${first}" run bash "${oe}" lock acquire o/r 1 "${first_token}"
  [ "${status}" -eq 0 ]
}

@test "a session for the same Epic gets the lock once the holding session has ended" {
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  end_session "${first}"
  start_session

  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 0 ]
  [ -n "$(token_of "${output}")" ]
}

@test "sessions for different Epics or repositories hold their locks side by side" {
  start_session
  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  start_session

  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/r 2
  [ "${status}" -eq 0 ]
  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/other 1
  [ "${status}" -eq 0 ]
}

@test "only the holding session can release the lock, and a release lets the next session in" {
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run bash "${oe}" lock acquire o/r 1
  first_token="$(token_of "${output}")"
  start_session
  second="${session_pid}"

  run bash "${oe}" lock release o/r 1 not-the-owner
  [ "${status}" -eq 4 ]
  OE_SESSION_PID="${second}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 4 ]

  run bash "${oe}" lock release o/r 1 "${first_token}"
  [ "${status}" -eq 0 ]
  OE_SESSION_PID="${second}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
}

@test "acquiring without OE_SESSION_PID is refused, because no process would mark the session as running" {
  unset OE_SESSION_PID

  run bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 2 ]
}
