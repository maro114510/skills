#!/usr/bin/env bats
# Tests for oe continue returning a parked Issue to the loop on its own branch.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe against them.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - git config skills.lang sets the reader's language, through the environment, so the user's config never leaks in.
# - Every comment oe writes is by the OWNER at 08:00, and every test runs at 08:00.
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
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=skills.lang GIT_CONFIG_VALUE_0=en
}

# Saves the GitHub state of Issue 5: its branch, and a pull request with a failure verdict, so a repair signal is present.
# A Major finding from coderabbitai, written at 07:50, sits on the pull request.
github_with_failure() {
  cat >"${OE_GITHUB}" <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:50", "body": "Major: fix this."}]}]
    }]
  }]
}
JSON
}

# The head the branch of Issue 5 has in github_with_failure.
head50=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb50

# Leaves Issue 5 with 3 attempts that each moved the branch head, the first of them using coderabbitai's round.
attempt_cap() {
  records 5 claim@07:00 attempt@07:01#h1 attempt@07:20#h2 attempt@07:40#h3
}

# Leaves Issue 5 with 3 Owner starts in a row that left the branch head as it is.
starts_without_push() {
  records 5 claim@07:00 "attempt@07:01#${head50}" "attempt@07:20#${head50}" "attempt@07:40#${head50}"
}

# Prints the action that oe ready gives Issue 5.
action_of_5() {
  bash "${oe}" ready o/r 1 | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = 5 ]; then
      echo "${action}"
    fi
  done
}

# Prints how many comments Issue 5 has in the saved GitHub state.
comment_count() {
  jq '.issues[0].comments // [] | length' "${OE_GITHUB}"
}

@test "an Issue parked at the attempt cap starts an Owner on the same branch after continue" {
  github_with_failure
  attempt_cap
  [ "$(action_of_5)" = parked ]

  run bash "${oe}" continue o/r 5

  [ "${status}" -eq 0 ]
  [ "$(action_of_5)" = start-owner ]
  [ "$(jq -r '.issues[0].branch' "${OE_GITHUB}")" = true ]
}

@test "an Issue parked by starts without a push starts an Owner on the same branch after continue" {
  github_with_failure
  starts_without_push
  [ "$(action_of_5)" = parked ]

  run bash "${oe}" continue o/r 5

  [ "${status}" -eq 0 ]
  [ "$(action_of_5)" = start-owner ]
}

@test "continue without an instruction writes nothing to GitHub" {
  github_with_failure
  attempt_cap
  before="$(cat "${OE_GITHUB}")"

  run bash "${oe}" continue o/r 5

  [ "${status}" -eq 0 ]
  [ "$(cat "${OE_GITHUB}")" = "${before}" ]
  [ "$(comment_count)" -eq 0 ]
}

@test "continue with an instruction writes one comment, and oe records returns the instruction to the next Owner" {
  github_with_failure
  attempt_cap

  run bash "${oe}" continue o/r 5 "Keep the public API; only fix the failing check"

  [ "${status}" -eq 0 ]
  [ "$(comment_count)" -eq 1 ]
  body="$(jq -r '.issues[0].comments[0].body' "${OE_GITHUB}")"
  [ "${body%%$'\n'*}" = "<!-- oe:answer -->" ]
  [ "${body}" != "${body#*$'\n'Keep the public API; only fix the failing check$'\n'}" ]
  record="$(bash "${oe}" records o/r 5 | jq -c 'select(.kind == "continue")')"
  [ "$(jq -r .instruction <<<"${record}")" = "Keep the public API; only fix the failing check" ]
  [ "$(jq -r .url <<<"${record}")" = "https://github.com/o/r/issues/5#issuecomment-1" ]
  [ "$(action_of_5)" = start-owner ]
}

@test "continue without an instruction leaves a continue record with no instruction" {
  github_with_failure
  attempt_cap

  run bash "${oe}" continue o/r 5

  [ "${status}" -eq 0 ]
  [ "$(bash "${oe}" records o/r 5 | jq -c 'select(.kind == "continue") | keys')" = '["at","kind"]' ]
}

@test "continue gives a bot back the round its earlier attempt used" {
  github_with_failure
  records 5 claim@07:00 "attempt@07:01#h1" "attempt@07:20#h2"
  printf '%s\n' '{"kind":"attempt","at":"2027-01-15T07:40:00Z","head":"h3","bots":["coderabbitai"]}' >>"$(record_file 5)"
  # The failure verdict repairs, but the bot's round is used, so its finding is not named in the reason.
  [ "$(bash "${oe}" ready o/r 1 | awk -F '\t' '$1 == 5 { print $3 }')" = "3 attempts used; still: failure verdict on bbbbbbb" ]

  run bash "${oe}" continue o/r 5

  [ "${status}" -eq 0 ]
  reason="$(bash "${oe}" ready o/r 1 | awk -F '\t' '$1 == 5 { print $3 }')"
  [ "${reason}" = "attempt 1 of 3: failure verdict on bbbbbbb; major finding from coderabbitai" ]
}

@test "oe attempt admits an Owner start after continue, and counts it as the first attempt" {
  github_with_failure
  attempt_cap
  run bash "${oe}" attempt o/r 5
  [ "${status}" -eq 4 ]

  run bash "${oe}" continue o/r 5
  [ "${status}" -eq 0 ]
  run bash "${oe}" attempt o/r 5

  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'attempt\t1\t3')" ]
}

@test "an Issue with attempts left is refused and nothing is recorded" {
  github_with_failure
  records 5 claim@07:00 attempt@07:01#h1
  before="$(records_of 5)"

  run bash "${oe}" continue o/r 5 "go on"

  [ "${status}" -eq 4 ]
  [ "$(records_of 5)" = "${before}" ]
  [ "$(comment_count)" -eq 0 ]
}

@test "a second continue is refused because the first one reset the count" {
  github_with_failure
  attempt_cap
  bash "${oe}" continue o/r 5

  run bash "${oe}" continue o/r 5

  [ "${status}" -eq 4 ]
}

@test "a GitHub read that fails records nothing" {
  github_with_failure
  attempt_cap
  before="$(records_of 5)"

  GH_FAIL=graphql run bash "${oe}" continue o/r 5

  [ "${status}" -eq 1 ]
  [ "$(records_of 5)" = "${before}" ]
}

@test "oe ready prints the continue command on an Issue parked at the cap, and none on any other park" {
  github_with_failure
  attempt_cap
  bash "${oe}" ready o/r 1 | awk -F '\t' '$1 == 5 { print $4 }' >"${BATS_TEST_TMPDIR}/command"
  [ "$(<"${BATS_TEST_TMPDIR}/command")" = "bash '${oe}' continue o/r 5 [<instruction>]" ]

  # A head with no checks ten minutes after its push is parked too, but no continue helps it.
  cat >"${OE_GITHUB}" <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10"}]}]
}
JSON
  records 5 claim@07:00
  run bash "${oe}" ready o/r 1
  [ "$(printf '%s\n' "${lines[@]}" | awk -F '\t' '$1 == 5 { print $2 }')" = parked ]
  [ -z "$(printf '%s\n' "${lines[@]}" | awk -F '\t' '$1 == 5 { print $4 }')" ]
}

@test "a blank instruction and an invalid repository are refused" {
  github_with_failure
  attempt_cap

  run bash "${oe}" continue o/r 5 "   "
  [ "${status}" -eq 2 ]
  run bash "${oe}" continue not-a-repo 5
  [ "${status}" -eq 2 ]
  run bash "${oe}" continue o/r five
  [ "${status}" -eq 2 ]
}
