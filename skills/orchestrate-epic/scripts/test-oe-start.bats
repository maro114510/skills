#!/usr/bin/env bats
# Tests for oe start, and for the start command oe ready names on each line.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe against it.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/records.bash writes the host-local records under the test's own OE_STATE_DIR.
# - A bare origin holds main and feat/issue-5, and the shared checkout is a clone of it, so worktrees are real.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  load testdata/records
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  oe="${BATS_TEST_DIRNAME}/oe"
  tmp="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
  mkdir -p "${tmp}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${tmp}/bin/gh"
  chmod +x "${tmp}/bin/gh"
  export PATH="${tmp}/bin:${PATH}"
  export OE_GITHUB="${tmp}/github.json"
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  export GIT_CONFIG_GLOBAL="${tmp}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  unset OE_WORKTREE_ROOT

  git init -q --bare "${tmp}/origin.git"
  git clone -q "${tmp}/origin.git" "${tmp}/seed" 2>/dev/null
  echo base >"${tmp}/seed/README"
  git -C "${tmp}/seed" add README
  git -C "${tmp}/seed" commit -q -m base
  git -C "${tmp}/seed" push -q origin main
  git -C "${tmp}/seed" switch -q -c feat/issue-5
  echo work >"${tmp}/seed/work"
  git -C "${tmp}/seed" add work
  git -C "${tmp}/seed" commit -q -m work
  git -C "${tmp}/seed" push -q origin feat/issue-5
  head="$(git -C "${tmp}/seed" rev-parse HEAD)"

  git clone -q "${tmp}/origin.git" "${tmp}/shared"
  cd "${tmp}/shared" || return 1
  wt="${tmp}/shared-oe/issue-5"
  skills="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Saves a state where Issue 5 has its branch and an open PR 15 at the branch head, with its checks passed.
pr_15_passed_checks() {
  jq -n --arg sha "${head}" '{
    default_branch: {checks: {test: "success"}},
    issues: [{
      number: 5,
      branch: true,
      pull_requests: [{number: 15, head_sha: $sha, opened: "07:10", checks: {test: "success"}}]
    }]
  }' >"${OE_GITHUB}"
}

@test "starting an Owner records the attempt, checks out the Issue branch, and prints the Owner's whole prompt" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true}]}
JSON
  records 5 claim@07:00

  run --separate-stderr bash "${oe}" start owner o/r 5 "no PR yet"

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${skills}/pr-owner/SKILL.md" ]
  [ "${lines[1]}" = "repo o/r issue 5 base main worktree ${wt} reason no PR yet" ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(git -C "${wt}" branch --show-current)" = feat/issue-5 ]
  [ "$(records_of 5 | tail -n1)" = '{"kind":"attempt","at":"2027-01-15T08:00:00Z"}' ]
}

@test "starting an Owner with --claim claims the Issue first" {
  github <<'JSON'
{"default_branch": {"checks": {"test": "success"}}, "issues": [{"number": 5}]}
JSON

  run --separate-stderr bash "${oe}" start owner o/r 5 --claim "every dependency completed"

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${skills}/pr-owner/SKILL.md" ]
  [ "$(records_of 5 | jq -r .kind | paste -sd, -)" = claim,attempt ]
}

@test "a claim refused because the branch exists exits 4 and starts nothing" {
  github <<'JSON'
{"default_branch": {"checks": {"test": "success"}}, "issues": [{"number": 5, "branch": true}]}
JSON

  run --separate-stderr bash "${oe}" start owner o/r 5 --claim "every dependency completed"

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
  [ ! -e "${wt}" ]
  [ -z "$(records_of 5)" ]
}

@test "an Owner refused at the attempt cap exits 4 and creates no worktree" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true}]}
JSON
  records 5 claim@07:00 attempt@07:01 attempt@07:20 attempt@07:40

  run --separate-stderr bash "${oe}" start owner o/r 5 "checks failed"

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
  [ ! -e "${wt}" ]
}

@test "starting a Verifier detaches the worktree at the PR head, writes the pending status, and prints the Verifier's whole prompt" {
  records 5 claim@07:00 attempt@07:01
  pr_15_passed_checks

  run --separate-stderr bash "${oe}" start verifier o/r 5

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${skills}/pr-verify/SKILL.md" ]
  [ "${lines[1]}" = "repo o/r issue 5 sha ${head} base main worktree ${wt}" ]
  [ "$(git -C "${wt}" rev-parse HEAD)" = "${head}" ]
  [ "$(jq -r '.written_statuses[0].state' "${OE_GITHUB}")" = pending ]
}

@test "a Verifier whose brief is refused exits with the brief's code and removes the worktree it created" {
  records 5 claim@07:00 attempt@07:01
  github <<'JSON'
{"default_branch": {"checks": {"test": "success"}}, "issues": [{"number": 5, "branch": true}]}
JSON

  run --separate-stderr bash "${oe}" start verifier o/r 5

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
  [ ! -e "${wt}" ]
}

@test "invalid arguments start nothing" {
  run --separate-stderr bash "${oe}" start owner o/r five

  [ "${status}" -eq 2 ]

  run --separate-stderr bash "${oe}" start verifier o/r 5 "a reason"

  [ "${status}" -eq 2 ]
  [ ! -e "${tmp}/shared-oe" ]
}

@test "each oe ready line names the start command for its action, and leaves it empty for a wait" {
  jq -n --arg sha "${head}" '{
    default_branch: {checks: {test: "success"}},
    issues: [
      {number: 5, branch: true, pull_requests: [{number: 15, head_sha: $sha, opened: "07:10", checks: {test: "success"}}]},
      {number: 6},
      {number: 7, branch: true, pull_requests: [{number: 17, opened: "07:10", checks: {test: "in_progress"}}]}
    ]
  }' >"${OE_GITHUB}"
  records 5 claim@07:00 attempt@07:01
  records 7 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  IFS=$'\t' read -r n action _ start <<<"${lines[0]}"
  [ "${n} ${action}" = "5 start-verifier" ]
  [ "${start}" = "bash ${BATS_TEST_DIRNAME}/oe start verifier o/r 5" ]
  IFS=$'\t' read -r n action reason start <<<"${lines[1]}"
  [ "${n} ${action}" = "6 claim" ]
  [ "${start}" = "bash ${BATS_TEST_DIRNAME}/oe start owner o/r 6 --claim $(printf '%q' "${reason}")" ]
  IFS=$'\t' read -r n action _ start <<<"${lines[2]}"
  [ "${n} ${action}" = "7 wait-ci" ]
  [ -z "${start}" ]
}
