#!/usr/bin/env bats
# Tests for oe start, the working marker it writes, and the start command oe ready names on each line.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe against it.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - A bare origin holds main and feat/issue-5, and the shared checkout is a clone of it, so worktrees are real.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
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
  # A test sets only the session ID variables it needs, so the caller's environment never reaches a record.
  unset OE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID DSH_SESSION_ID

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

# Prints the working marker lines in Issue 5's body in the saved GitHub state.
marker_lines() {
  jq -r '.issues[0].body // ""' "${OE_GITHUB}" | grep '^<!-- oe:working ' || true
}

@test "starting an Owner checks out the Issue branch, writes the working marker at the end of the body, and prints the whole prompt" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "body": "## Requirements\n\n- Do it."}]}
JSON

  run --separate-stderr bash "${oe}" start owner o/r 5 "no PR yet"

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${skills}/pr-owner/SKILL.md" ]
  [ "${lines[1]}" = "repo o/r issue 5 base main worktree ${wt} reason no PR yet" ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(git -C "${wt}" branch --show-current)" = feat/issue-5 ]
  [ "$(jq -r '.issues[0].body' "${OE_GITHUB}")" = "## Requirements

- Do it.

<!-- oe:working role=owner at=2027-01-15T08:00:00Z -->" ]
}

@test "starting a Verifier writes a marker with the SHA it checks out" {
  pr_15_passed_checks

  run --separate-stderr bash "${oe}" start verifier o/r 5

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${skills}/pr-verify/SKILL.md" ]
  [ "${lines[1]}" = "repo o/r issue 5 sha ${head} base main worktree ${wt}" ]
  [ "$(git -C "${wt}" rev-parse HEAD)" = "${head}" ]
  [ "$(marker_lines)" = "<!-- oe:working role=verifier at=2027-01-15T08:00:00Z sha=${head} -->" ]
}

@test "a new start replaces the earlier marker and keeps the rest of the body" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "body": "Body.\n\n<!-- oe:working role=owner at=2027-01-15T06:00:00Z -->"}]}
JSON

  run --separate-stderr bash "${oe}" start owner o/r 5 "no PR yet"

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.issues[0].body' "${OE_GITHUB}")" = "Body.

<!-- oe:working role=owner at=2027-01-15T08:00:00Z -->" ]
}

@test "the marker names the session ID from each harness variable, the first set winning" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true}]}
JSON

  for var in OE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID DSH_SESSION_ID; do
    env "${var}=from-${var}" bash "${oe}" start owner o/r 5 "no PR yet" >/dev/null
    [ "$(marker_lines)" = "<!-- oe:working role=owner at=2027-01-15T08:00:00Z session=from-${var} -->" ]
  done

  env OE_SESSION_ID=first DSH_SESSION_ID=fourth bash "${oe}" start owner o/r 5 "no PR yet" >/dev/null
  [ "$(marker_lines)" = "<!-- oe:working role=owner at=2027-01-15T08:00:00Z session=first -->" ]
}

@test "a session ID that could break the marker line is left off" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true}]}
JSON

  for id in $'bad\nid' 'a b' 'x -->'; do
    OE_SESSION_ID="${id}" run --separate-stderr bash "${oe}" start owner o/r 5 "no PR yet"
    [ "${status}" -eq 0 ]
    [ "$(marker_lines)" = "<!-- oe:working role=owner at=2027-01-15T08:00:00Z -->" ]
  done
}

@test "oe ready waits for the agent an Owner start left, until it pushes" {
  github <<'JSON'
{"issues": [{"number": 5}]}
JSON

  run --separate-stderr bash "${oe}" start owner o/r 5 "no PR yet"
  [ "${status}" -eq 0 ]

  run bash "${oe}" ready o/r 1
  [ "$(printf '%s\n' "${lines[@]}" | awk -F '\t' '$1 == 5 { print $2 }')" = wait-agent ]
}

@test "starting an Owner for an Issue whose branch is not on origin creates it locally from the base" {
  github <<'JSON'
{"issues": [{"number": 6}]}
JSON

  run --separate-stderr bash "${oe}" start owner o/r 6 --claim "no PR yet"

  [ "${status}" -eq 0 ]
  [ "$(git -C "${tmp}/shared-oe/issue-6" branch --show-current)" = feat/issue-6 ]
  [ "$(git -C "${tmp}/shared-oe/issue-6" rev-parse HEAD)" = "$(git -C "${tmp}/seed" rev-parse main)" ]
  run git -C "${tmp}/origin.git" rev-parse --verify --quiet refs/heads/feat/issue-6
  [ "${status}" -ne 0 ]
}

@test "oe start reads and writes no file under the state directory" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true}]}
JSON
  mkdir -p "${OE_STATE_DIR}"
  chmod 000 "${OE_STATE_DIR}"

  run --separate-stderr bash "${oe}" start owner o/r 5 "no PR yet"
  chmod 755 "${OE_STATE_DIR}"

  [ "${status}" -eq 0 ]
  [ -z "$(ls -A "${OE_STATE_DIR}")" ]
}

@test "a start whose marker write fails exits 1, prints no prompt, and removes the worktree" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true}]}
JSON

  GH_FAIL="-X PATCH" run --separate-stderr bash "${oe}" start owner o/r 5 "no PR yet"

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  [ ! -e "${wt}" ]
}

@test "a Verifier whose brief is refused exits with the brief's code, writes no marker, and removes the worktree it created" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true}]}
JSON

  run --separate-stderr bash "${oe}" start verifier o/r 5

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
  [ ! -e "${wt}" ]
  [ -z "$(marker_lines)" ]
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
    issues: [
      {number: 5, branch: true, pull_requests: [{number: 15, head_sha: $sha, opened: "07:10", checks: {test: "success"}}]},
      {number: 6},
      {number: 7, branch: true, pull_requests: [{number: 17, opened: "07:10", checks: {test: "in_progress"}}]}
    ]
  }' >"${OE_GITHUB}"

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  IFS=$'\t' read -r n action _ start <<<"${lines[0]}"
  [ "${n} ${action}" = "5 start-verifier" ]
  [ "${start}" = "bash '${BATS_TEST_DIRNAME}/oe' start verifier o/r 5" ]
  IFS=$'\t' read -r n action reason start <<<"${lines[1]}"
  [ "${n} ${action}" = "6 start-owner" ]
  [ "${start}" = "bash '${BATS_TEST_DIRNAME}/oe' start owner o/r 6 '${reason}'" ]
  IFS=$'\t' read -r n action _ start <<<"${lines[2]}"
  [ "${n} ${action}" = "7 wait-ci" ]
  [ -z "${start}" ]
}
