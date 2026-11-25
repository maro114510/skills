#!/usr/bin/env bats
# Tests for oe wait.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe wait against it.
# - testdata/fake-gh.sh stands in for gh and answers every read from that state.
# - OE_GITHUB_NEXT swaps in a second state at the second poll, so a change lands at a point the test controls.
# - OE_WAIT_INTERVAL=0 polls without sleeping, so a test waits only as long as its --timeout.
# - Every test runs at 08:00 on the same day.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  export OE_WAIT_INTERVAL=0
  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  cd "${BATS_TEST_TMPDIR}" || return 1
  unset OE_WORKTREE_ROOT
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  four_hours=14400
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Leaves an Owner running on Issue $1 the way oe start leaves it: a working marker started at 07:30 at the end of its body.
agent_runs() {
  jq --argjson n "$1" '.issues |= map(if .number == $n then .body = "<!-- oe:working role=owner at=2027-01-15T07:30:00Z -->" else . end)' \
    "${OE_GITHUB}" >"${OE_GITHUB}.new" && mv "${OE_GITHUB}.new" "${OE_GITHUB}"
}

# Saves, from stdin, the state that replaces the current one at the second poll.
github_at_second_poll() {
  export OE_GITHUB_NEXT="${BATS_TEST_TMPDIR}/github-next.json"
  cat >"${OE_GITHUB_NEXT}"
}

# Saves a state where Issue 5, has its PR 15 still running a check.
pr_15_checks_running() {
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

# Saves a state where Issue 5, waits for the answer to its question.
issue_5_waits_for_an_answer() {
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

# Saves a state where Issue 5 has no branch yet and nothing blocks it.
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
  [ "$(action_of 5)" = start-owner ]
}

# Saves a state where Issue 5 has no branch yet and nothing blocks it, and Issues 6 to 8 have no branch either.
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
  agent_runs 6
  agent_runs 7

  run bash "${oe}" wait o/r 1 --max-agents 2 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "with --max-agents 0, as after a start that failed with no agent running, an Issue to start at the first read keeps the wait running until the timeout" {
  issue_5_ready_to_claim

  run bash "${oe}" wait o/r 1 --max-agents 0 --timeout 1

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "without --max-agents, three running agents keep an Issue to start from ending the wait, as the skill's default of three agents" {
  issues_5_to_8_ready_to_claim
  agent_runs 6
  agent_runs 7
  agent_runs 8

  run bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 5 ]
}

@test "running agents counted from the working markers on GitHub, below --max-agents, let an Issue to start at the first read return the wait at once" {
  issues_5_to_8_ready_to_claim
  agent_runs 6

  run bash "${oe}" wait o/r 1 --max-agents 2 --timeout 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(action_of 6)" = wait-agent ]
}

@test "a first read that holds a hold returns at once even with every agent slot taken, because the hold starts no agent" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "state": "closed", "opened": "07:10"}]}]}
JSON

  run bash "${oe}" wait o/r 1 --max-agents 0 --timeout 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
}

@test "an agent that pushes during a wait makes that wait return with the Issue's new action" {
  github <<'JSON'
{"issues": [{"number": 5}]}
JSON
  agent_runs 5
  github_at_second_poll <<'JSON'
{"issues": [{"number": 5, "branch": true, "body": "<!-- oe:working role=owner at=2027-01-15T07:30:00Z -->",
  "pull_requests": [{"number": 15, "opened": "07:50", "checks": {"test": "in_progress"}}]}]}
JSON

  run --separate-stderr bash "${oe}" wait o/r 1 --timeout 30

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a failed first read keeps the wait running, and the next read comes no sooner than the poll interval" {
  issue_5_ready_to_claim
  interval=2

  GH_FAIL_EPIC_READ=1 OE_WAIT_INTERVAL="${interval}" run --separate-stderr bash "${oe}" wait o/r 1 --timeout 60

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
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

# Prints the UTC time of epoch second $1 as oe wait shows a reset time, YYYY-MM-DDTHH:MM:SSZ.
utc_time() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

@test "an exhausted GraphQL bucket does not end the wait: it shows the reset time, waits for it, and then returns the next actions" {
  issue_5_ready_to_claim
  reset_in_two_seconds="$(($(date +%s) + 2))"

  GH_RATE_LIMIT_UNTIL="${reset_in_two_seconds}" run --separate-stderr bash "${oe}" wait o/r 1 --timeout 60

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(date +%s)" -ge "${reset_in_two_seconds}" ]
  case "${stderr}" in
  *"$(utc_time "${reset_in_two_seconds}")"*) ;;
  *) return 1 ;;
  esac
}

@test "an exhausted GraphQL bucket that resets after the timeout ends the wait at the timeout with an error and no next actions, after showing the reset time" {
  issue_5_ready_to_claim
  reset_in_an_hour="$(($(date +%s) + 3600))"
  started="$(date +%s)"

  GH_RATE_LIMIT_UNTIL="${reset_in_an_hour}" run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  [ "$(($(date +%s) - started))" -lt 30 ]
  case "${stderr}" in
  *"$(utc_time "${reset_in_an_hour}")"*) ;;
  *) return 1 ;;
  esac
}

@test "reads failing while the GraphQL bucket has calls left still end the wait, as before" {
  issue_5_ready_to_claim

  GH_FAIL=graphql run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"reset"*) return 1 ;;
  *) ;;
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
  [ "$(action_of 5)" = start-owner ]
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

@test "a second wait for the same Epic while one runs waits on its own, and returns at its timeout" {
  pr_15_checks_running
  OE_WAIT_INTERVAL=1 bash "${oe}" wait o/r 1 --timeout 30 >/dev/null 2>&1 3>&- &
  first=$!
  sleep 2

  run --separate-stderr bash "${oe}" wait o/r 1 --timeout 1
  pkill -P "${first}" 2>/dev/null || true
  kill "${first}" 2>/dev/null || true

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = wait-ci ]
}
# Reads of one Issue each, across the polls of one call

# Puts a date in front of the real one that prints the epoch second in the file OE_CLOCK, so a test moves time with OE_CLOCK_STEP.
clock_starts_at_eight() {
  real_date="$(command -v date)"
  # shellcheck disable=SC2016 # The shim expands $* and $@ when it runs, not here.
  printf '#!/usr/bin/env bash\nif [[ "$*" == "-u +%%s" ]]; then cat "${OE_CLOCK}"; else exec "%s" "$@"; fi\n' "${real_date}" >"${BATS_TEST_TMPDIR}/bin/date"
  chmod +x "${BATS_TEST_TMPDIR}/bin/date"
  export OE_CLOCK="${BATS_TEST_TMPDIR}/clock"
  echo 1800000000 >"${OE_CLOCK}"
  unset OE_NOW
}

# Prints how many times the Issue read ran for Issue $1.
issue_reads_of() {
  grep -cx "$1" "${OE_GITHUB}.issue-reads"
}

@test "two polls with nothing changed read an open Issue once" {
  pr_15_checks_running
  github_at_second_poll <"${OE_GITHUB}"
  clock_starts_at_eight

  OE_CLOCK_STEP=1 run bash "${oe}" wait o/r 1 --timeout 4

  [ "${status}" -eq 5 ]
  [ "$(wc -l <"${OE_GITHUB}.polls")" -ge 2 ]
  [ "$(issue_reads_of 5)" -eq 1 ]
}

@test "a check that finishes between two polls makes the next poll read the Issue again" {
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
  [ "$(action_of 5)" = start-verifier ]
  [ "$(issue_reads_of 5)" -eq 2 ]
}

@test "a comment on an open Issue between two polls makes the next poll read the Issue again" {
  pr_15_checks_running
  github_at_second_poll <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "NONE", "at": "07:30", "body": "Thanks"}],
    "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"test": "in_progress"}}]
  }]
}
JSON
  clock_starts_at_eight

  OE_CLOCK_STEP=1 run bash "${oe}" wait o/r 1 --timeout 4

  [ "${status}" -eq 5 ]
  [ "$(action_of 5)" = wait-ci ]
  [ "$(issue_reads_of 5)" -eq 2 ]
}

@test "a head that has had no checks for 10 minutes makes the next poll read the Issue again, with nothing else changed" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 15, "opened": "07:55"}]}]}
JSON
  clock_starts_at_eight
  seven_minutes=420

  OE_CLOCK_STEP="${seven_minutes}" run bash "${oe}" wait o/r 1 --timeout 3600

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(issue_reads_of 5)" -eq 2 ]
}

@test "a working marker that reaches its 2 hours between two polls makes the next poll read the Issue again, with nothing else changed" {
  github <<'JSON'
{"issues": [{"number": 5}]}
JSON
  agent_runs 5
  clock_starts_at_eight
  two_hours=7200

  OE_CLOCK_STEP="${two_hours}" run bash "${oe}" wait o/r 1 --timeout 36000

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(issue_reads_of 5)" -eq 2 ]
}
