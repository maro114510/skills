#!/usr/bin/env bats
# Tests for oe hold.
#
# - testdata/fake-gh.sh stands in for gh, answers every read from the test's GitHub state, and applies every write to it.
# - git config skills.lang sets the reader's language, through the environment, so the user's config never leaks in.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=skills.lang GIT_CONFIG_VALUE_0=en
  printf '%s\n' '{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "state": "closed", "opened": "07:10"}]}]}' >"${OE_GITHUB}"
}

# Prints how many comments Issue 5 has in the saved GitHub state.
comment_count() {
  jq '.issues[0].comments // [] | length' "${OE_GITHUB}"
}

@test "a hold posts its reason as one marked Issue comment, and oe ready then waits on the person with that reason" {
  run --separate-stderr bash "${oe}" hold o/r 5 "PR #50 was closed without merging"

  [ "${status}" -eq 0 ]
  [ "${output}" = $'hold\thttps://github.com/o/r/issues/5#issuecomment-1' ]
  [ "$(comment_count)" -eq 1 ]
  [ "$(jq -r '.issues[0].comments[0].body' "${OE_GITHUB}")" = "<!-- oe:hold -->
### The orchestrate-epic session holds this Issue for the person

PR #50 was closed without merging

---
Answer in the orchestrate-epic session's conversation. The session records the answer, and the next agent reads it and resumes the work." ]
  run bash "${oe}" ready o/r 1
  IFS=$'\t' read -r n action reason _ <<<"${lines[0]}"
  [ "${n} ${action}" = "5 wait-answer" ]
  [ "${reason}" = 'hold https://github.com/o/r/issues/5#issuecomment-1 has no answer yet:\nPR #50 was closed without merging' ]
}

@test "the command oe ready prints for a hold line posts the hold" {
  run bash "${oe}" ready o/r 1
  IFS=$'\t' read -r _ action _ command <<<"${lines[0]}"
  [ "${action}" = hold ]

  eval "${command}" >/dev/null

  [ "$(comment_count)" -eq 1 ]
  [ "$(jq -r '.issues[0].comments[0].body' "${OE_GITHUB}" | sed -n 4p)" = "PR #50 was closed without merging" ]
}

@test "in Japanese the hold has a Japanese heading" {
  export GIT_CONFIG_VALUE_0=ja

  run --separate-stderr bash "${oe}" hold o/r 5 "PR #50 was closed without merging"

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.issues[0].comments[0].body' "${OE_GITHUB}" | sed -n 2p)" = "### orchestrate-epicのセッションがこのIssueを人の判断待ちにしました" ]
}

@test "an empty reason or a bad argument writes nothing" {
  run --separate-stderr bash "${oe}" hold o/r 5 "  "
  [ "${status}" -eq 2 ]
  run --separate-stderr bash "${oe}" hold o/r five "reason"
  [ "${status}" -eq 2 ]

  [ "$(comment_count)" -eq 0 ]
}

@test "a failed write exits 1" {
  GH_FAIL="/comments" run --separate-stderr bash "${oe}" hold o/r 5 "reason"

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}
