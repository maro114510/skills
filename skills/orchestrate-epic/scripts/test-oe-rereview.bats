#!/usr/bin/env bats
# Tests for oe rereview.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe against them.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/fake-github.jq lists every field of the state and its default.
# - testdata/records.bash writes and reads the host-local records under the test's own OE_STATE_DIR.
# - Every comment oe writes is by the OWNER at 08:00.
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
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Saves a state where Issue 5 is claimed and its open pull request 50 is ready for a re-review.
claimed_with_open_pr() {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON
}

# Prints the bodies of the comments on pull request $1 in the saved GitHub state, oldest first.
pr_comment_bodies() {
  jq -r --argjson n "$1" '.issues[] | .pull_requests[]? | select(.number == $n) | (.comments // [])[] | .body' "${OE_GITHUB}"
}

# Prints how many comments pull request $1 has in the saved GitHub state.
pr_comment_count() {
  jq --argjson n "$1" '.issues[] | .pull_requests[]? | select(.number == $n) | (.comments // []) | length' "${OE_GITHUB}"
}

@test "asking the bots to review again writes one marked comment per bot the latest attempt used" {
  claimed_with_open_pr
  records 5 claim@07:00
  printf '%s\n' '{"kind":"attempt","at":"2027-01-15T07:30:00Z","bots":["coderabbitai","chatgpt-codex-connector"]}' >>"$(record_file 5)"

  run bash "${oe}" rereview o/r 5

  [ "${status}" -eq 0 ]
  [ "${output}" = $'rereview\t2' ]
  [ "$(pr_comment_count 50)" -eq 2 ]
  [ "$(pr_comment_bodies 50 | grep -c '^<!-- oe:rereview -->$')" -eq 2 ]
  [ "$(pr_comment_bodies 50 | grep -c '^@coderabbitai review$')" -eq 1 ]
  [ "$(pr_comment_bodies 50 | grep -c '^@codex review$')" -eq 1 ]
}

@test "an attempt that used no bot round writes no comment" {
  claimed_with_open_pr
  records 5 claim@07:00 attempt@07:30

  run bash "${oe}" rereview o/r 5

  [ "${status}" -eq 0 ]
  [ "${output}" = $'rereview\t0' ]
  [ "$(pr_comment_count 50)" -eq 0 ]
}

@test "a branch without an open pull request writes nothing" {
  github <<'JSON'
{
  "issues": [{"number": 5, "branch": true}]
}
JSON
  records 5 claim@07:00
  printf '%s\n' '{"kind":"attempt","at":"2027-01-15T07:30:00Z","bots":["coderabbitai"]}' >>"$(record_file 5)"

  run --separate-stderr bash "${oe}" rereview o/r 5

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
}

@test "an unreadable record file fails without a comment" {
  claimed_with_open_pr
  records 5 claim@07:00
  echo 'not json' >>"$(record_file 5)"

  run --separate-stderr bash "${oe}" rereview o/r 5

  [ "${status}" -eq 1 ]
  [ "$(pr_comment_count 50)" -eq 0 ]
}

@test "a bot that is not listed fails without a comment" {
  claimed_with_open_pr
  records 5 claim@07:00
  printf '%s\n' '{"kind":"attempt","at":"2027-01-15T07:30:00Z","bots":["stylebot"]}' >>"$(record_file 5)"

  run --separate-stderr bash "${oe}" rereview o/r 5

  [ "${status}" -eq 1 ]
  [ "$(pr_comment_count 50)" -eq 0 ]
}
