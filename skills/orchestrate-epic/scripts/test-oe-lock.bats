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
    { kill "${pid}" && wait "${pid}"; } 2>/dev/null || true
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
  { kill "$1" && wait "$1"; } 2>/dev/null || true
}

# Puts a ps that fails to start ahead of the real one on PATH, as a sandbox that refuses setuid programs does.
ps_cannot_run() {
  mkdir -p "${BATS_TEST_TMPDIR}/no-ps"
  printf '#!/bin/sh\necho "ps: Operation not permitted" >&2\nexit 126\n' >"${BATS_TEST_TMPDIR}/no-ps/ps"
  chmod +x "${BATS_TEST_TMPDIR}/no-ps/ps"
  export PATH="${BATS_TEST_TMPDIR}/no-ps:${PATH}"
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

@test "a session under another TZ and locale is refused while the holder that took the lock under UTC and C runs" {
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run env -u LC_ALL -u LC_TIME TZ=UTC LANG=C bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  start_session

  OE_SESSION_PID="${session_pid}" run env TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 4 ]
}

@test "a session under another TZ and locale gets the lock once the holder that took it under UTC and C has ended" {
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run env -u LC_ALL -u LC_TIME TZ=UTC LANG=C bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  end_session "${first}"
  start_session

  OE_SESSION_PID="${session_pid}" run env TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 0 ]
}

@test "a lock that recorded its holder's start in the taker's TZ and locale still refuses a session under the same ones" {
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  # Before oe lock fixed TZ and the locale, it recorded the start as ps prints it under the taker's own.
  store="${OE_STATE_DIR}/locks.git"
  ref="$(git --git-dir="${store}" for-each-ref --format='%(refname)' refs/oe-lock)"
  taker_start="$(env TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 ps -o lstart= -p "${first}" | sed -e 's/^ *//' -e 's/ *$//')"
  legacy="$(git --git-dir="${store}" cat-file -p "${ref}" | sed "s|^lstart=.*|lstart=${taker_start}|" |
    git --git-dir="${store}" hash-object -w --stdin)"
  git --git-dir="${store}" update-ref "${ref}" "${legacy}"
  start_session

  OE_SESSION_PID="${session_pid}" run env TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 4 ]
}

@test "when ps cannot run, a session gets a free lock and a second session is refused while the first one runs" {
  ps_cannot_run
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  [ -n "$(token_of "${output}")" ]
  start_session

  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 4 ]
}

@test "when ps cannot run, a session gets the lock once the holding session has ended" {
  ps_cannot_run
  start_session
  first="${session_pid}"
  OE_SESSION_PID="${first}" run bash "${oe}" lock acquire o/r 1
  [ "${status}" -eq 0 ]
  end_session "${first}"
  start_session

  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 0 ]
}

@test "when ps cannot run, a lock whose holder start ps recorded in UTC and C still refuses a session while the holder runs" {
  start_session
  first="${session_pid}"
  store="${OE_STATE_DIR}/locks.git"
  mkdir -p "${OE_STATE_DIR}"
  git init --quiet --bare "${store}"
  ref="refs/oe-lock/$(printf 'o/r' | git hash-object --stdin)/1"
  ps_start="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "${first}" | sed -e 's/^ *//' -e 's/ *$//')"
  held="$(printf 'token=t\npid=%s\nlstart=%s\nrepo=o/r\nepic=1\nstarted=2026-01-01T00:00:00Z\n' "${first}" "${ps_start}" |
    git --git-dir="${store}" hash-object -w --stdin)"
  git --git-dir="${store}" update-ref "${ref}" "${held}"
  ps_cannot_run
  start_session

  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 4 ]
}

@test "acquiring without OE_SESSION_PID is refused, because no process would mark the session as running" {
  unset OE_SESSION_PID

  run bash "${oe}" lock acquire o/r 1

  [ "${status}" -eq 2 ]
}

@test "a release on an unreadable lock store fails instead of reporting the lock free" {
  start_session
  OE_SESSION_PID="${session_pid}" run bash "${oe}" lock acquire o/r 1
  token="$(token_of "${output}")"
  echo garbage >"${OE_STATE_DIR}/locks.git/HEAD"

  run --separate-stderr bash "${oe}" lock release o/r 1 "${token}"

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"lock store"*) ;;
  *) return 1 ;;
  esac
}
