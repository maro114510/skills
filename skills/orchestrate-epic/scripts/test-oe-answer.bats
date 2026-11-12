#!/usr/bin/env bats
# Tests for oe question recording the person's answer, given in the session's conversation, on the Issue.
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
  printf '%s\n' '{"default_branch": {"checks": {"test": "success"}}, "issues": [{"number": 5, "branch": true}]}' >"${OE_GITHUB}"
  records 5 claim@07:00 attempt@07:01
}

# Writes an Owner's question with options A and B on Issue 5 through oe question.
ask() {
  bash "${oe}" question o/r 5 >/dev/null <<'EOF'
Decision: The nightly export fails on a full folder: how should it respond?

Context:
- Goal: the sales team reads yesterday's orders each morning.
- Stage: the export runs nightly but has no error handling.
- Why now: last night the folder filled up, and nobody was told.

Criteria:
- Failures are noticed quickly.

Options:
- A. Email the team on failure
  - Noticed within minutes; deletes nothing.
- B. Leave it as is
  - No work; failures found the next morning.

Recommendation: A, email the team; it meets the criterion.

Agreement: Shall I email the team on failure? If not, which option?
EOF
}

# Prints how many comments Issue 5 has in the saved GitHub state.
comment_count() {
  jq '.issues[0].comments // [] | length' "${OE_GITHUB}"
}

# Prints the body of the newest comment on Issue 5 in the saved GitHub state.
last_comment() {
  jq -r '.issues[0].comments | last | .body' "${OE_GITHUB}"
}

# Prints the action that oe ready gives Issue 5.
action_of_5() {
  bash "${oe}" ready o/r 1 | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = 5 ]; then
      echo "${action}"
    fi
  done
}

@test "an answer by an option's letter is written on the Issue, and oe ready reads it as the engineer's answer" {
  ask
  [ "$(action_of_5)" = wait-answer ]

  run bash "${oe}" question o/r 5 --answer b

  [ "${status}" -eq 0 ]
  [ "${output%%$'\t'*}" = answer ]
  [ "$(comment_count)" -eq 2 ]
  body="$(last_comment)"
  [ "${body%%$'\n'*}" = "<!-- oe:answer -->" ]
  [ "${body}" != "${body#*$'\n'B. Leave it as is$'\n'}" ]
  [ "${body}" != "${body#*https://github.com/o/r/issues/5#issuecomment-1}" ]
  [ "$(action_of_5)" = start-owner ]
}

@test "a free-text answer is written as given, and oe ready reads it as the engineer's answer" {
  ask

  run bash "${oe}" question o/r 5 --answer "Email the team, and keep files for 30 days"

  [ "${status}" -eq 0 ]
  body="$(last_comment)"
  [ "${body%%$'\n'*}" = "<!-- oe:answer -->" ]
  [ "${body}" != "${body#*$'\n'Email the team, and keep files for 30 days$'\n'}" ]
  [ "$(action_of_5)" = start-owner ]
}

@test "a letter that no option has is refused and writes nothing" {
  ask

  run bash "${oe}" question o/r 5 --answer C

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 1 ]
}

@test "an empty answer is refused and writes nothing" {
  ask

  run bash "${oe}" question o/r 5 --answer "  "

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 1 ]
}

@test "an Issue without a question gets no answer" {
  run bash "${oe}" question o/r 5 --answer A

  [ "${status}" -eq 3 ]
  [ "$(comment_count)" -eq 0 ]
}
