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

@test "after the idle limit with no agent running, wait ends with the next actions, and a rerun lists the same ones" {
  pr_15_checks_running

  run bash "${oe}" wait o/r 1 --timeout 60 --idle-since "$((OE_NOW - four_hours))"

  [ "${status}" -eq 6 ]
  [ "$(action_of 5)" = wait-ci ]
  summary=("${lines[@]}")

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[*]}" = "${summary[*]}" ]
}

@test "an output unchanged for less than the idle limit waits until the timeout" {
  pr_15_checks_running

  run bash "${oe}" wait o/r 1 --timeout 1 --idle-since "$((OE_NOW - four_hours + 1))"

  [ "${status}" -eq 5 ]
}

@test "a running agent keeps the idle limit from ending the session" {
  pr_15_checks_running

  run bash "${oe}" wait o/r 1 --running 6 --timeout 1 --idle-since "$((OE_NOW - four_hours))"

  [ "${status}" -eq 5 ]
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

@test "a default branch head without checks past the grace ends the wait with the end line" {
  github <<'JSON'
{
  "default_branch": {"pushed": "07:00"},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" wait o/r 1 --timeout 60

  [ "${status}" -eq 3 ]
  case "${lines[0]}" in
  end$'\t'*) ;;
  *) return 1 ;;
  esac
}

@test "a timeout that is not a whole number of seconds is refused" {
  pr_15_checks_running

  run --separate-stderr bash "${oe}" wait o/r 1 --timeout soon

  [ "${status}" -eq 2 ]
}
