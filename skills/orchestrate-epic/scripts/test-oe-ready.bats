#!/usr/bin/env bats
# Tests for oe ready.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe ready against them.
# - testdata/fake-gh.sh stands in for gh and answers every read from that state.
# - testdata/fake-github.jq lists every field of the state and its default.
# - testdata/records.bash writes the host-local records under the test's own OE_STATE_DIR.
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
  unset OE_WORKTREE_ROOT
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
}

teardown() {
  stop_sessions
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Configures $1 as the agents' bot, through the git config skills.bot that oe reads.
agent_bot() {
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=skills.bot GIT_CONFIG_VALUE_0="$1"
}

# Prints the action that oe ready gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

# Prints the field $2 of the line for the Issue numbered $1, counting the Issue number as field 1.
field_of() {
  printf '%s\n' "${lines[@]}" | awk -F '\t' -v n="$1" -v f="$2" '$1 == n { print $f }'
}

# Default branch gate

@test "a default branch head with no checks eleven minutes after its push holds nothing and ends nothing" {
  github <<'JSON'
{
  "default_branch": {"pushed": "07:49"},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "a failed check on the default branch head makes no Issue ready" {
  github <<'JSON'
{
  "default_branch": {"checks": {"lint": "success", "test": "failure"}},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
}

@test "a failed check on the default branch head still reports a closed Issue as done and holds an open one" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "failure"}},
  "issues": [{"number": 5, "closed": true}, {"number": 6}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = "done" ]
  [ "$(action_of 6)" = wait-base ]
}

@test "a running check on the default branch head still lets an Issue with completed dependencies be claimed" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "in_progress"}},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "a failure oe/verify status on the default branch head does not count as a failed check" {
  github <<'JSON'
{
  "default_branch": {"statuses": {"oe/verify": "failure"}},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

# Failed reads

@test "every failed GitHub read exits non-zero and prints nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01
  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]

  # The Epic read, the Issue read, the pull request list, the commit statuses, and the push activity.
  for read in subIssues "num=5" /pulls /statuses /activity; do
    GH_FAIL="${read}" run --separate-stderr bash "${oe}" ready o/r 1

    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
  done
}

@test "an unreadable record file fails the read and prints nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true}]
}
JSON
  records 5 claim@07:00
  echo 'not json' >>"$(record_file 5)"

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  case "${stderr}" in
  *"record"*) ;;
  *) return 1 ;;
  esac
}

# Before the claim

@test "an Issue with no branch and every dependency completed is claimed" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "blocked_by": [{"number": 3, "state": "completed"}]}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(action_of 5)" = claim ]
}

@test "a closed Issue is done" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "closed": true}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = "done" ]
}

@test "an Issue with one open dependency is not ready" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "blocked_by": [{"number": 3, "state": "completed"}, {"number": 4, "state": "open"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-dependencies ]
}

@test "an Issue whose dependency closed as not planned waits instead of being claimed" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "blocked_by": [{"number": 4, "state": "not_planned"}]}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-dependencies ]
}

@test "an Issue whose branch exists without a pull request and without any record on this host is not claimed again and gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an open Issue whose pull request merged after the latest claim waits for an engineer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40"}]
  }]
}
JSON
  records 5 claim@07:00

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-engineer ]
}

@test "a pull request merged before the latest claim does not hold a restarted Issue" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40"}]
  }]
}
JSON
  records 5 claim@07:50

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "an Issue whose branch exists and whose pull request closed without merging waits for an engineer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "state": "closed", "opened": "07:10"}]
  }]
}
JSON
  records 5 claim@07:00

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-engineer ]
}

@test "a merged pull request from a fork with the Issue's branch name is ignored" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40", "from_fork": true}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "Issues come in number order" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 7}, {"number": 5}, {"number": 6}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]%%$'\t'*}" = 5 ]
  [ "${lines[1]%%$'\t'*}" = 6 ]
  [ "${lines[2]%%$'\t'*}" = 7 ]
}

# Running agents

# Saves a state where Issues 5 and 6 have no branch yet and nothing blocks their claim.
issues_5_and_6_ready_to_claim() {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}, {"number": 6}]
}
JSON
}

@test "an Issue whose agent oe start left running is named as running, with the command to run once it ends, without --running" {
  issues_5_and_6_ready_to_claim
  session_holds_lock
  agent_runs 6 owner

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(action_of 5)" = claim ]
  [ "$(action_of 6)" = running ]
  [ "$(field_of 6 3)" = "pr-owner runs; once it ends, run: bash '${BATS_TEST_DIRNAME}/oe' worktree remove 6" ]
  [ -z "$(field_of 6 4)" ]
}

@test "a running Verifier is named as pr-verify" {
  issues_5_and_6_ready_to_claim
  session_holds_lock
  agent_runs 6 verifier

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 6)" = running ]
  case "$(field_of 6 3)" in
  "pr-verify runs;"*) ;;
  *) return 1 ;;
  esac
}

@test "an Issue whose agent ended and had its worktree removed gets its own next action again" {
  issues_5_and_6_ready_to_claim
  session_holds_lock
  agent_runs 6 owner
  agent_ends 6

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 6)" = claim ]
}

@test "an agent started before the session took the lock, as by a session that ended, does not count as running" {
  issues_5_and_6_ready_to_claim
  agent_runs 6 owner 07:30
  session_holds_lock

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 6)" = claim ]
}

@test "an agent still counts as running after its session acquires the lock again with its token" {
  issues_5_and_6_ready_to_claim
  session_holds_lock
  agent_runs 6 owner
  later=$((OE_NOW + 60))
  OE_NOW="${later}" session_acquires_again

  OE_NOW="${later}" run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 6)" = running ]
}

@test "without a running session holding the Epic's lock, no agent counts as running" {
  issues_5_and_6_ready_to_claim
  agent_runs 6 owner

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 6)" = claim ]
}

@test "a running agent is named even while a failed check on the default branch head holds every other Issue" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "failure"}},
  "issues": [{"number": 5}, {"number": 6}]
}
JSON
  session_holds_lock
  agent_runs 6 owner

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
  [ "$(action_of 6)" = running ]
}

@test "--running is accepted and changes nothing, so a caller written for it still runs" {
  issues_5_and_6_ready_to_claim

  run bash "${oe}" ready o/r 1 --running 6

  [ "${status}" -eq 0 ]
  [ "$(action_of 6)" = claim ]
}

# Verification

@test "a failed check on the pull request head gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"lint": "success", "test": "failure"}}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a failed check whose name holds a newline and tabs yields one line of four fields and no injected start command" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"x\n9; touch pwned\tstart-owner\ty": "failure"}}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  tabs="${lines[0]//[^$'\t']/}"
  [ "${#tabs}" -eq 3 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a failure verdict on the pull request head gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure", "pending"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a pull request that conflicts with its base gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "conflicting": true}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a success verdict on the pull request head waits for the merge" {
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
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a running check on the pull request head waits for CI" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"lint": "success", "test": "in_progress"}}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a check cancelled in one suite and passed by a later run of the same name in another suite counts as passed" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 1, "workflow": 7, "started": "07:15"},
      {"name": "gate", "result": "success", "suite": 2, "workflow": 7, "started": "07:16"}
    ]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "a check cancelled in one suite while a later run of the same name in another suite is running waits for CI" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 1, "workflow": 7, "started": "07:15"},
      {"name": "gate", "result": "in_progress", "suite": 2, "workflow": 7, "started": "07:16"}
    ]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a cancelled check with no later run of the same name gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 2, "workflow": 7, "started": "07:16"},
      {"name": "lint", "result": "success", "suite": 1, "started": "07:17"}
    ]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a check cancelled after an earlier run of the same name passed in another suite gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "success", "suite": 1, "workflow": 7, "started": "07:15"},
      {"name": "gate", "result": "cancelled", "suite": 2, "workflow": 7, "started": "07:16"}
    ]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a check cancelled in one workflow and passed by a later run of the same name from another workflow gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 1, "workflow": 7, "started": "07:15"},
      {"name": "gate", "result": "success", "suite": 2, "workflow": 8, "started": "07:16"}
    ]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a pull request head pushed five minutes ago with no checks waits for CI, even when committed long before" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "committed": "06:00", "pushed": "07:55"}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a pull request head with no checks ten minutes after its push is parked" {
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
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = parked ]
}

@test "a Verifier that ended once without a verdict is started again" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["pending"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "a Verifier that ended twice without a verdict parks the Issue" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["pending", "pending"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = parked ]
}

# Sibling pull requests

# Saves a state where Issue 4's PR 40 merged into main at 07:30, and Issue 5's open PR 50 passed its checks
# with a verdict of $1, none for no verdict, and a head that lacks the merges in the JSON array $2.
sibling_merged() {
  jq -n --arg verdict "$1" --argjson missing "$2" '{
    default_branch: {checks: {test: "success"}},
    issues: [
      {number: 4, closed: true, pull_requests: [{number: 40, state: "merged", opened: "07:05", merged: "07:30"}]},
      {number: 5, branch: true, pull_requests: [{number: 50, opened: "07:10", checks: {test: "success"},
        verdicts: (if $verdict == "none" then [] else [$verdict] end), missing_merges: $missing}]}
    ]
  }' >"${OE_GITHUB}"
  records 5 claim@07:00 attempt@07:01
}

@test "a head that passed its checks and lacks a merged sibling pull request waits for its branch update instead of a Verifier" {
  sibling_merged none '[40]'

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-update ]
  IFS=$'\t' read -r _ _ reason command <<<"${lines[1]}"
  [ -z "${command}" ]
  case "${reason}" in
  *"#40"*) ;;
  *) return 1 ;;
  esac
}

@test "a head with a success verdict that lacks a merged sibling pull request waits for its branch update instead of the merge" {
  sibling_merged success '[40]'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-update ]
}

@test "a head that contains the merged sibling pull request is verified, and one with a success verdict waits for the merge" {
  sibling_merged none '[]'
  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]

  sibling_merged success '[]'
  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a pull request merged into a branch other than the default branch is no sibling" {
  sibling_merged none '[40]'
  jq '.issues[0].pull_requests[0].base = "release"' "${OE_GITHUB}" >"${OE_GITHUB}.new" && mv "${OE_GITHUB}.new" "${OE_GITHUB}"

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "a failed read of whether a head contains a merged sibling exits non-zero and prints nothing" {
  sibling_merged none '[40]'

  GH_FAIL=/compare run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

# Attempts

@test "three attempts after the latest claim park an Issue that still needs repair" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01 attempt@07:20 attempt@07:40

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = parked ]
}

@test "attempts before the latest claim do not count toward the cap" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]
  }]
}
JSON
  records 5 claim@06:00 attempt@06:01 attempt@06:20 attempt@06:40 claim@07:00 attempt@07:00

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# Engineer input

@test "a question with no later comment waits for the answer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"}
    ]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a marked or untrusted comment after a question does not answer it" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:20", "body": "<!-- oe:note -->\nUse option A"},
      {"by": "NONE", "at": "07:21", "body": "Use option A"},
      {"by": "CONTRIBUTOR", "at": "07:22", "body": "Use option A"}
    ]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "an unmarked trusted answer after the latest attempt gets an Owner, even on a verified pull request" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:20", "body": "Use option A"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an answer given as a comment gets an Owner and leaves the Issue body unchanged" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "body": "## Acceptance Criteria\n\n- The export retries once.",
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nDecision: Which option?"},
      {"by": "MEMBER", "at": "07:20", "body": "Use option A"}
    ]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(jq -r '.issues[0].body' "${OE_GITHUB}")" = "## Acceptance Criteria

- The export retries once." ]
}

@test "a question record from the configured bot, which GitHub gives no association, waits for the answer" {
  agent_bot agent-app
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"}
    ]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a comment from the configured bot that is no record does not answer its question" {
  agent_bot agent-app
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:20", "body": "Use option A"}
    ]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a trusted person's comment answers a question from the configured bot" {
  agent_bot agent-app
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "OWNER", "login": "owner", "at": "07:20", "body": "Use option A"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an answer recorded through oe under the configured bot is read as the engineer's answer" {
  agent_bot agent-app
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:20", "body": "<!-- oe:answer -->\nA. Use option A"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an answer-shaped comment from another bot or an untrusted user does not answer the question" {
  agent_bot agent-app
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "NONE", "login": "renovate", "type": "Bot", "at": "07:20", "body": "<!-- oe:answer -->\nA. Use option A"},
      {"by": "NONE", "login": "agent-app", "type": "User", "at": "07:21", "body": "<!-- oe:answer -->\nA. Use option A"},
      {"by": "CONTRIBUTOR", "at": "07:22", "body": "<!-- oe:answer -->\nA. Use option A"}
    ]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "the line of an Issue with an open question holds the question and the command that records its answer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\n### Question from the orchestrate-epic agent working on this Issue\n\nDecision: Which option?\n\nOptions:\n- A. Keep it\n  - No work.\n\n---\nAnswer in the session's conversation."}
    ]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  IFS=$'\t' read -r n action reason command <<<"${lines[0]}"
  [ "${n}" = 5 ]
  [ "${action}" = wait-answer ]
  [ "${reason}" = 'question https://github.com/o/r/issues/5#issuecomment-1 has no answer yet:\nDecision: Which option?\n\nOptions:\n- A. Keep it\n  - No work.' ]
  [ "${command}" = "bash '${oe}' question o/r 5 --answer <reply>" ]
}

@test "a question-shaped comment from another bot, or from a user with the configured bot's login, is ignored" {
  agent_bot agent-app
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {
      "number": 5,
      "branch": true,
      "comments": [
        {"by": "NONE", "login": "renovate", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
        {"by": "NONE", "login": "agent-app", "type": "User", "at": "07:11", "body": "<!-- oe:question -->\nWhich option?"}
      ],
      "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
    }
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "with no bot configured, a question-shaped comment from a bot is ignored" {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "an invalid configured bot login fails the read" {
  agent_bot 'bad"login'
  github <<'JSON'
{"default_branch": {"checks": {"test": "success"}}, "issues": [{"number": 5}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 2 ]
  [ "${output}" != "${output#*skills.bot}" ]
}

@test "an answer that an earlier attempt already took does not start another Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:02", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:03", "body": "Use option A"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01 attempt@07:04

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a trusted Changes requested review after the latest attempt gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "reviews": [{"by": "MEMBER", "at": "07:40", "body": "Rename this"}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a Changes requested review before the latest attempt does not start another Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "reviews": [{"by": "MEMBER", "at": "07:20", "body": "Rename this"}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a trusted review-thread comment after the latest attempt gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "thread_comments": [{"by": "COLLABORATOR", "at": "07:40", "body": "This leaks the token"}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an untrusted review-thread comment does not start an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "thread_comments": [{"by": "NONE", "at": "07:40", "body": "This leaks the token"}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

# Bot findings

@test "a Major CodeRabbit finding after the latest attempt gets an Owner that names the bot" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40",
        "body": "This is a Major finding: `brew install chezmoi` runs before `brew` is on PATH."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  case "${lines[0]}" in
  *"coderabbitai"*) ;;
  *) return 1 ;;
  esac
}

@test "a P1 Codex finding after the latest attempt gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "chatgpt-codex-connector", "type": "Bot", "at": "07:40",
        "body": "P1: the retry count is off by one."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a Minor CodeRabbit finding starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40",
        "body": "Minor: prefer a shorter name here."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a Major finding from a bot that is not listed starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "stylebot", "type": "Bot", "at": "07:40", "body": "Major: rename this."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a Major finding in a reply to a trusted thread starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [
        {"by": "MEMBER", "at": "07:30", "body": "Is this safe?"},
        {"login": "coderabbitai", "type": "Bot", "at": "07:40", "body": "Major: no, it is not."}
      ]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a resolved Major finding starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"resolved": true, "comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40",
        "body": "Major: fix this."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "an outdated Major finding starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"outdated": true, "comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40",
        "body": "Major: fix this."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a Major finding on a head a trusted user approved starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "approvals": [{"by": "MEMBER", "at": "07:50"}],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40",
        "body": "Major: fix this."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a Major finding from before the latest attempt starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:20",
        "body": "Major: fix this."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a Major finding from a bot whose round is used starts nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40",
        "body": "Major: fix this."}]}]
    }]
  }]
}
JSON
  records 5 claim@07:00
  printf '%s\n' '{"kind":"attempt","at":"2027-01-15T07:30:00Z","bots":["coderabbitai"]}' >>"$(record_file 5)"

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a bot round recorded before the latest claim does not count against the new claim" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40",
        "body": "Major: fix this."}]}]
    }]
  }]
}
JSON
  records 5 claim@06:00
  printf '%s\n' '{"kind":"attempt","at":"2027-01-15T06:30:00Z","bots":["coderabbitai"]}' >>"$(record_file 5)"
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# A push during the read

@test "a push during the read does not hide a pending question" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:question -->\nWhich option?"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a push during the read fails the read when the action depends on the head" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

# Reads that GitHub cuts short

@test "a closed Issue with more comments than one read holds is done" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "closed": true, "branch": true, "older_comments": 150}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = "done" ]
}

@test "more review threads than one read holds fail the read instead of missing engineer input" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"], "older_threads": 100
    }]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:30

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "older pull requests left out of the read do not fail it, and the newest one decides the action" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"test": "success"}}],
    "older_pull_requests": 100
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "more comments than one read holds fail the read when the claim is older than every comment read" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "MEMBER", "at": "07:10", "body": "Looks fine"}],
    "older_comments": 150
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "more comments than one read holds do not fail the read when every comment since the claim was read" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "MEMBER", "at": "07:00", "body": "Looks fine"},
      {"by": "OWNER", "at": "07:20", "body": "<!-- oe:question -->\nWhich option?"}
    ],
    "older_comments": 150
  }]
}
JSON
  records 5 claim@07:10 attempt@07:11

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

# Prints 150 checks named check-1 to check-150, which GitHub returns over two pages.
# check-150, on the second page, has the result $1, and every other check passed.
checks_150() {
  jq -nc --arg last "$1" '[range(1; 150) | {key: "check-\(.)", value: "success"}] + [{key: "check-150", value: $last}] | from_entries'
}

@test "a pending check on the second page of a pull request head with 150 checks waits for CI" {
  github <<JSON
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": $(checks_150 in_progress)}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "150 passed checks over two pages on a pull request head start the Verifier without a truncation error" {
  github <<JSON
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": $(checks_150 success)}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
  case "${stderr}" in
  *"checks truncated"*) return 1 ;;
  *) ;;
  esac
}

@test "a failed check on the second page of a pull request head with 150 checks gets an Owner that names it" {
  github <<JSON
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": $(checks_150 failure)}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  IFS=$'\t' read -r _ _ reason _ <<<"${lines[0]}"
  case "${reason}" in
  *"checks failed on "*": check-150") ;;
  *) return 1 ;;
  esac
}

@test "a failed check on the second page of a default branch head with 150 checks makes no Issue ready" {
  github <<JSON
{
  "default_branch": {"checks": $(checks_150 failure)},
  "issues": [{"number": 5}]
}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
  IFS=$'\t' read -r _ _ reason _ <<<"${lines[0]}"
  case "${reason}" in
  *"checks failed on main head "*": check-150") ;;
  *) return 1 ;;
  esac
}

@test "a failed read of the second page of checks exits non-zero and prints nothing" {
  github <<JSON
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": $(checks_150 success)}]
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  GH_FAIL="after=" run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "a question from before the latest claim does not hold a restarted Issue" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "OWNER", "at": "06:30", "body": "<!-- oe:question -->\nWhich option?"}]
  }]
}
JSON
  records 5 claim@06:00 attempt@06:01 claim@07:00

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# oe ready --save

@test "--save prints what oe ready prints and saves the facts of every Issue, a running one too, with the time of the read" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "closed": true},
    {"number": 6, "branch": true, "pull_requests": [{"number": 60, "opened": "07:10", "checks": {"test": "in_progress"}}]},
    {"number": 7, "branch": true}
  ]
}
JSON
  records 6 claim@07:00 attempt@07:01
  records 7 claim@07:00 attempt@07:01
  agent_runs 7 owner

  run bash "${oe}" ready o/r 1
  plain="${output}"
  run bash "${oe}" ready o/r 1 --save

  [ "${status}" -eq 0 ]
  [ "${output}" = "${plain}" ]
  record="$(cat "$(facts_record o/r 1)")"
  [ "$(jq -r '.at' <<<"${record}")" = "${OE_NOW}" ]
  [ "$(jq -r '.failure' <<<"${record}")" = null ]
  [ "$(jq -r '[.lines[] | "\(.number) \(.action)"] | join(",")' <<<"${record}")" = "5 done,6 wait-ci,7 start-owner" ]
}

@test "--save with a failed read keeps the facts of the read before it, and records the reason and when it failed" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 6, "branch": true, "pull_requests": [{"number": 60, "opened": "07:10", "checks": {"test": "in_progress"}}]}]
}
JSON
  records 6 claim@07:00 attempt@07:01
  bash "${oe}" ready o/r 1 --save >/dev/null

  OE_NOW=$((OE_NOW + 90)) GH_FAIL=subIssues run --separate-stderr bash "${oe}" ready o/r 1 --save

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  record="$(cat "$(facts_record o/r 1)")"
  [ "$(jq -r '.at' <<<"${record}")" = "${OE_NOW}" ]
  [ "$(jq -r '.failure.at' <<<"${record}")" = "$((OE_NOW + 90))" ]
  [ -n "$(jq -r '.failure.reason' <<<"${record}")" ]
  [ "$(jq -r '.lines[0].action' <<<"${record}")" = wait-ci ]
}

@test "--save with a failed read before any read saved records the failure without facts" {
  github <<'JSON'
{"issues": [{"number": 6}]}
JSON

  GH_FAIL=subIssues run --separate-stderr bash "${oe}" ready o/r 1 --save

  [ "${status}" -eq 1 ]
  record="$(cat "$(facts_record o/r 1)")"
  [ "$(jq -r '.at' <<<"${record}")" = null ]
  [ "$(jq -c '.lines' <<<"${record}")" = '[]' ]
  [ -n "$(jq -r '.failure.reason' <<<"${record}")" ]
}

@test "a plain oe ready, and one with --facts, saves nothing" {
  github <<'JSON'
{"default_branch": {"checks": {"test": "success"}}, "issues": [{"number": 6}]}
JSON

  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  run bash "${oe}" ready o/r 1 --facts
  [ "${status}" -eq 0 ]

  [ ! -e "$(facts_record o/r 1)" ]
}

@test "--save cannot be combined with --facts" {
  run --separate-stderr bash "${oe}" ready o/r 1 --facts --save

  [ "${status}" -eq 2 ]
  [ ! -e "$(facts_record o/r 1)" ]
}

@test "--save under a failed default branch check saves each Issue's wait for it" {
  github <<'JSON'
{"default_branch": {"checks": {"test": "failure"}}, "issues": [{"number": 6}, {"number": 7, "closed": true}]}
JSON

  run bash "${oe}" ready o/r 1 --save

  [ "${status}" -eq 0 ]
  [ "$(jq -r '[.lines[] | "\(.number) \(.action)"] | join(",")' "$(facts_record o/r 1)")" = "6 wait-base,7 done" ]
}
