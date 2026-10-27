#!/usr/bin/env bats
# Tests for rerun.sh and park.sh. Stubs stand in for gh and osascript and log their arguments, so no test
# calls GitHub or shows a notification.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  tmp="${BATS_TEST_TMPDIR}"
  token="tok-1"
  key="k:github-actions/.github/workflows/ci.yml/pull_request/test@aaa#0"
  export BABYSIT_NOW=1000000
  git init -q "${tmp}/repo"
  cd "${tmp}/repo" || return 1
  # Each stub writes one line per argument, then a separator line per call.
  for name in gh osascript; do
    cat >"${tmp}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${tmp}/${name}-calls"
echo -- >>"${tmp}/${name}-calls"
[ -e "${tmp}/${name}-fails" ] && exit 1
exit 0
EOF
    chmod +x "${tmp}/${name}"
  done
  export BABYSIT_GH="${tmp}/gh" BABYSIT_OSASCRIPT="${tmp}/osascript"
  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

rerun() {
  run bash "${scripts}/rerun.sh" o/r 7 --session "${token}" --key "${key}" --workflow-run 10 --run-id 100
}

park() {
  run bash "${scripts}/park.sh" o/r 7 --session "${token}" --key "$1" --reason "$2" "${@:3}"
}

ledger() {
  bash "${scripts}/ledger.sh" show o/r 7 | jq -r "$1"
}

calls() {
  if [ -e "${tmp}/$1-calls" ]; then grep -c '^--$' "${tmp}/$1-calls"; else echo 0; fi
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

@test "rerun rejects bad arguments with exit 2" {
  run bash "${scripts}/rerun.sh"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/rerun.sh" o/r 7 --session "${token}" --workflow-run 10 --run-id 100
  [ "${status}" -eq 2 ]
  run bash "${scripts}/rerun.sh" o/r 7 --session "${token}" --key "${key}" --workflow-run x --run-id 100
  [ "${status}" -eq 2 ]
  run bash "${scripts}/rerun.sh" o/r 7 --session "${token}" --key "${key}" --workflow-run 10 --run-id x
  [ "${status}" -eq 2 ]
  expect "$(calls gh)" 0
  rerun
  [ "${status}" -eq 0 ]
}

@test "rerun by a session without the lock exits 3 and re-runs nothing" {
  run bash "${scripts}/rerun.sh" o/r 7 --session other --key "${key}" --workflow-run 10 --run-id 100
  [ "${status}" -eq 3 ]
  expect "$(calls gh)" 0
}

@test "rerun re-runs only the failed jobs of the workflow run and records the failed run id" {
  rerun
  [ "${status}" -eq 0 ]
  expect "$(tr '\n' ' ' <"${tmp}/gh-calls")" "run rerun 10 --failed --repo o/r -- "
  expect "$(ledger ".items[\"${key}\"].disposition")" rerun
  expect "$(ledger ".items[\"${key}\"].run_id")" 100
}

@test "rerun that GitHub refuses exits 1 and records nothing, so the caller repairs instead" {
  : >"${tmp}/gh-fails"
  rerun
  [ "${status}" -eq 1 ]
  expect "$(ledger ".items[\"${key}\"] // \"none\"")" none
}

@test "park rejects bad arguments with exit 2" {
  run bash "${scripts}/park.sh"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/park.sh" o/r 7 --session "${token}" --reason "why"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/park.sh" o/r 7 --session "${token}" --key c:IC1 --reason "why"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/park.sh" o/r 7 --session "${token}" --key "${key}"
  [ "${status}" -eq 2 ]
  expect "$(calls osascript)" 0
  expect "$(ledger '.items // {} | length')" 0
  park c:IC1 "why" --hash h1
  [ "${status}" -eq 0 ]
}

@test "park by a session without the lock exits 3 and notifies nobody" {
  run bash "${scripts}/park.sh" o/r 7 --session other --key "${key}" --reason "why"
  [ "${status}" -eq 3 ]
  expect "$(calls osascript)" 0
}

@test "park records the item with its reason and shows one notification naming the PR" {
  park c:IC1 "asks for a schema change" --hash h1
  [ "${status}" -eq 0 ]
  expect "$(jq -r .notified <<<"${output}")" true
  expect "$(ledger '.items["c:IC1"].disposition')" parked
  expect "$(ledger '.items["c:IC1"].hash')" h1
  expect "$(ledger '.items["c:IC1"].reason')" "asks for a schema change"
  expect "$(calls osascript)" 1
  grep -q 'o/r#7' "${tmp}/osascript-calls"
  grep -q 'asks for a schema change' "${tmp}/osascript-calls"
}

@test "park still parks when osascript is missing or fails" {
  export BABYSIT_OSASCRIPT="${tmp}/nowhere"
  park "${key}" "gate parked the push"
  [ "${status}" -eq 0 ]
  expect "$(jq -r .notified <<<"${output}")" false
  expect "$(ledger ".items[\"${key}\"].disposition")" parked
  export BABYSIT_OSASCRIPT="${tmp}/osascript"
  : >"${tmp}/osascript-fails"
  park c:IC2 "needs a human" --hash h2
  [ "${status}" -eq 0 ]
  expect "$(jq -r .notified <<<"${output}")" false
  expect "$(ledger '.items["c:IC2"].disposition')" parked
}

@test "park passes comment text to osascript as arguments and never runs it" {
  hostile="\"; touch ${tmp}/pwned; echo \$(touch ${tmp}/pwned2)"$'\n'"second line"
  park c:IC3 "${hostile}" --hash h3
  [ "${status}" -eq 0 ]
  [ ! -e "${tmp}/pwned" ]
  [ ! -e "${tmp}/pwned2" ]
  # A new line in the text would end the notification early, so it becomes a space.
  expect "$(calls osascript)" 1
  grep -q 'pwned2).* second line' "${tmp}/osascript-calls"
}
