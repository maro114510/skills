#!/usr/bin/env bats
# Tests for the writes drive mode makes through ledger.sh: heartbeat, own pushes, round and repair
# counts, and own replies with their per-thread cap.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  git init -q "${BATS_TEST_TMPDIR}/repo"
  cd "${BATS_TEST_TMPDIR}/repo" || return 1
  export BABYSIT_NOW=1000000
  token="tok-1"
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  check_key="github-actions/.github/workflows/ci.yml/pull_request/test"
  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

ledger_cmd() {
  bash "${scripts}/ledger.sh" "$1" o/r 7 "${token}" "${@:2}"
}

ledger() {
  bash "${scripts}/ledger.sh" show o/r 7 | jq -r "$1"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

@test "touch moves the heartbeat to now" {
  BABYSIT_NOW=1000300 run ledger_cmd touch
  [ "${status}" -eq 0 ]
  expect "$(ledger .lock.heartbeat)" 1000300
}

@test "a session that lost the lock exits 3 from every drive write" {
  run bash "${scripts}/ledger.sh" touch o/r 7 other
  [ "${status}" -eq 3 ]
  run bash "${scripts}/ledger.sh" own-push o/r 7 other "${sha}"
  [ "${status}" -eq 3 ]
  run bash "${scripts}/ledger.sh" count-push o/r 7 other
  [ "${status}" -eq 3 ]
  run bash "${scripts}/ledger.sh" reply-begin o/r 7 other conversation --hash h1
  [ "${status}" -eq 3 ]
  run bash "${scripts}/ledger.sh" reply-done o/r 7 other conversation --hash h1 --id IC9
  [ "${status}" -eq 3 ]
  expect "$(ledger '.own // "none"')" none
  expect "$(ledger .rounds)" 0
}

@test "own-push lists each pushed sha in order" {
  run ledger_cmd own-push "${sha}"
  [ "${status}" -eq 0 ]
  run ledger_cmd own-push "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  expect "$(ledger '.own.pushes | join(",")')" "${sha},bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}

@test "own-push rejects a value that is not a full sha" {
  run ledger_cmd own-push abc123
  [ "${status}" -eq 2 ]
  expect "$(ledger '.own // "none"')" none
  run ledger_cmd own-push "${sha}"
  [ "${status}" -eq 0 ]
  expect "$(ledger '.own.pushes | length')" 1
}

@test "count-push adds one round, and one repair for each named check" {
  run ledger_cmd count-push
  [ "${status}" -eq 0 ]
  expect "$(ledger .rounds)" 1
  expect "$(ledger '.repairs | length')" 0
  run ledger_cmd count-push "${check_key}"
  run ledger_cmd count-push "${check_key}" "status/lint"
  expect "$(ledger .rounds)" 3
  expect "$(ledger ".repairs[\"${check_key}\"]")" 2
  expect "$(ledger '.repairs["status/lint"]')" 1
}

@test "reply-begin lists the body hash with no comment id yet, and counts nothing" {
  run ledger_cmd reply-begin T1 --hash h1
  [ "${status}" -eq 0 ]
  expect "$(ledger '.own.replies | length')" 1
  expect "$(ledger '.own.replies[0].hash')" h1
  expect "$(ledger '.own.replies[0].id')" null
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 T1)" 0
}

@test "reply-done gives the pending reply its comment id and counts it on its thread" {
  ledger_cmd reply-begin T1 --hash h1
  run ledger_cmd reply-done T1 --hash h1 --id TC9
  [ "${status}" -eq 0 ]
  expect "$(ledger '.own.replies[0].id')" TC9
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 T1)" 1
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 T2)" 0
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 conversation)" 0
}

@test "reply-done without a pending reply for that hash fails and counts nothing" {
  ledger_cmd reply-begin T1 --hash h1
  run ledger_cmd reply-done T1 --hash other --id TC9
  [ "${status}" -eq 2 ]
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 T1)" 0
}

@test "replies keep one count per thread, and the conversation counts as one thread" {
  for h in h1 h2; do
    ledger_cmd reply-begin conversation --hash "${h}"
    ledger_cmd reply-done conversation --hash "${h}" --id "IC-${h}"
  done
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 conversation)" 2
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 T1)" 0
}

@test "a new session resets the round, repair, and reply counts but keeps own pushes and replies" {
  ledger_cmd own-push "${sha}"
  ledger_cmd count-push "${check_key}"
  ledger_cmd reply-begin T1 --hash h1
  ledger_cmd reply-done T1 --hash h1 --id TC9
  ledger_cmd stop
  BABYSIT_NOW=$((BABYSIT_NOW + 5)) run bash "${scripts}/ledger.sh" start o/r 7 tok-2
  [ "${status}" -eq 0 ]
  expect "$(ledger .rounds)" 0
  expect "$(ledger '.repairs | length')" 0
  expect "$(bash "${scripts}/ledger.sh" replies o/r 7 T1)" 0
  expect "$(ledger '.own.pushes | length')" 1
  expect "$(ledger '.own.replies | length')" 1
}
