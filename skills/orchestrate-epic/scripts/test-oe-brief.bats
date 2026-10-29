#!/usr/bin/env bats
# Tests for oe brief.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe against it.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/fake-github.jq lists every field of the state and its default.
# - An agent's worktree is a real Git repository under the test's temporary directory, so its HEAD is a real SHA.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
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

  wt="${tmp}/issue-5"
  git init -q -b feat/issue-5 "${wt}"
  echo work >"${wt}/work"
  git -C "${wt}" add work
  git -C "${wt}" commit -q -m work
  head="$(git -C "${wt}" rev-parse HEAD)"
}

# Detaches the worktree's HEAD at its current commit, as oe worktree add --detach leaves it.
detached_worktree() {
  git -C "${wt}" switch -q --detach
}

# Saves a state where Issue 5 is claimed and its open PR 15, whose head is $1, passed its checks.
pr_15_passed_checks_at() {
  jq -n --arg sha "$1" '{
    default_branch: {checks: {test: "success"}},
    issues: [{
      number: 5,
      branch: true,
      comments: [
        {by: "OWNER", at: "07:00", body: "<!-- oe:claim -->"},
        {by: "OWNER", at: "07:01", body: "<!-- oe:attempt -->"}
      ],
      pull_requests: [{number: 15, head_sha: $sha, opened: "07:10", checks: {test: "success"}}]
    }]
  }' >"${OE_GITHUB}"
}

# Prints the oe/verify states written on SHA $1, newest first, one per line.
verify_statuses_on() {
  jq -r --arg sha "$1" '.written_statuses[]? | select(.sha == $sha and .context == "oe/verify") | .state' "${OE_GITHUB}"
}

# Prints the action that oe ready gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

@test "a Verifier brief names the worktree head and writes one pending verify status on it" {
  detached_worktree
  pr_15_passed_checks_at "${head}"

  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "repo o/r issue 5 sha ${head} base main worktree ${wt}" ]
  [ "$(verify_statuses_on "${head}")" = pending ]
}

@test "a second Verifier brief on the same head reaches the start limit, and oe ready parks the Issue" {
  detached_worktree
  pr_15_passed_checks_at "${head}"
  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"
  [ "${status}" -eq 0 ]

  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"
  [ "${status}" -eq 0 ]
  run bash "${oe}" ready o/r 1

  [ "$(action_of 5)" = parked ]
}

@test "a Verifier brief past the start limit is refused and writes nothing" {
  detached_worktree
  pr_15_passed_checks_at "${head}"
  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"
  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"

  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
  [ "$(verify_statuses_on "${head}" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a Verifier brief whose worktree head is not the PR head is refused and writes nothing" {
  detached_worktree
  pushed_head=dddddddddddddddddddddddddddddddddddddddd
  pr_15_passed_checks_at "${pushed_head}"

  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
  [ -z "$(verify_statuses_on "${head}")" ]
  [ -z "$(verify_statuses_on "${pushed_head}")" ]
}

@test "a Verifier brief for a worktree on a branch is refused and writes nothing" {
  pr_15_passed_checks_at "${head}"

  run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"

  [ "${status}" -eq 2 ]
  [ -z "${output}" ]
  [ -z "$(verify_statuses_on "${head}")" ]
}

@test "a Verifier brief whose status write fails prints no brief" {
  detached_worktree
  pr_15_passed_checks_at "${head}"

  GH_FAIL="/statuses/${head}" run --separate-stderr bash "${oe}" brief verifier o/r 5 "${wt}"

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  [ -z "$(verify_statuses_on "${head}")" ]
}

@test "an Owner brief names the base branch, the worktree, and the reason, and writes nothing" {
  pr_15_passed_checks_at "${head}"
  before="$(cat "${OE_GITHUB}")"

  run --separate-stderr bash "${oe}" brief owner o/r 5 "${wt}" "attempt 2 of 3: a check failed"

  [ "${status}" -eq 0 ]
  [ "${output}" = "repo o/r issue 5 base main worktree ${wt} reason attempt 2 of 3: a check failed" ]
  [ "$(cat "${OE_GITHUB}")" = "${before}" ]
}

@test "an Owner brief for a worktree on another Issue's branch is refused" {
  git -C "${wt}" switch -q -c feat/issue-6
  pr_15_passed_checks_at "${head}"

  run --separate-stderr bash "${oe}" brief owner o/r 5 "${wt}" "no PR yet"

  [ "${status}" -eq 2 ]
  [ -z "${output}" ]
}
