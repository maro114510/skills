#!/usr/bin/env bats
# Tests for oe update.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe against them.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/fake-github.jq lists every field of the state and its default.
# - testdata/records.bash writes and reads the host-local records under the test's own OE_STATE_DIR.
# - A pull request's head SHA is named by its number unless head_sha sets it: PR 50's is 38 b's then 50,
#   and the head GitHub pushes when it updates PR 50's branch is 38 f's then 50.
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
  export OE_UPDATE_INTERVAL=0
  head_of_pr_50=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb50
  updated_head_of_pr_50=ffffffffffffffffffffffffffffffffffffff50
}

# Saves a state where Issue 4's PR 40 merged into main at 07:30, and Issue 5's open PR 50,
# with the fields in the JSON object $1, passed its checks on a head that lacks that merge.
pr_50_lacks_sibling() {
  local extra="${1:-}"
  [ -n "${extra}" ] || extra='{}'
  records 5 claim@07:00 attempt@07:01
  jq -n --argjson extra "${extra}" '{
    default_branch: {checks: {test: "success"}},
    issues: [
      {number: 4, closed: true, pull_requests: [{number: 40, state: "merged", opened: "07:05", merged: "07:30"}]},
      {number: 5, branch: true, pull_requests: [{number: 50, opened: "07:10", checks: {test: "success"},
        verdicts: ["success"], missing_merges: [40]} + $extra]}
    ]
  }' >"${OE_GITHUB}"
}

# Prints the head SHA of PR 50 in the GitHub state.
head_of_50() {
  jq -r '.issues[].pull_requests[]? | select(.number == 50) | .head_sha // "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb50"' "${OE_GITHUB}"
}

# Prints the update records of Issue 5 on this host, one JSON object per line.
update_records() {
  records_of 5 | jq -c 'select(.kind == "update")'
}

@test "an update of the listed head records the request, merges the base into the branch, and prints the new head" {
  pr_50_lacks_sibling

  run --separate-stderr bash "${oe}" update o/r 5 "${head_of_pr_50}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "update"$'\t'"50"$'\t'"${updated_head_of_pr_50}" ]
  [ "$(head_of_50)" = "${updated_head_of_pr_50}" ]
  [ "$(update_records)" = '{"kind":"update","at":"2027-01-15T08:00:00Z","sha":"'"${head_of_pr_50}"'"}' ]
}

@test "after an update, oe ready waits for CI on the new head instead of keeping the old verdict" {
  pr_50_lacks_sibling
  run bash "${oe}" ready o/r 1
  [ "$(cut -f2 <<<"${lines[1]}")" = update ]

  run bash "${oe}" update o/r 5 "${head_of_pr_50}"
  [ "${status}" -eq 0 ]

  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  [ "$(cut -f2 <<<"${lines[1]}")" = wait-ci ]
}

@test "a head that moved since oe ready read it is not updated and records nothing" {
  pr_50_lacks_sibling '{"head_sha": "cccccccccccccccccccccccccccccccccccccccc"}'

  run --separate-stderr bash "${oe}" update o/r 5 "${head_of_pr_50}"

  [ "${status}" -eq 4 ]
  [ "$(head_of_50)" = cccccccccccccccccccccccccccccccccccccccc ]
  [ -z "$(update_records)" ]
}

@test "a branch with no open pull request is not updated and records nothing" {
  pr_50_lacks_sibling '{"state": "closed"}'

  run --separate-stderr bash "${oe}" update o/r 5 "${head_of_pr_50}"

  [ "${status}" -eq 4 ]
  [ -z "$(update_records)" ]
}

@test "an update GitHub refuses exits 1 with its error and keeps the record that counts toward parking" {
  pr_50_lacks_sibling '{"update_refusal": "merge conflict between base and head (HTTP 422)"}'

  run --separate-stderr bash "${oe}" update o/r 5 "${head_of_pr_50}"

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"merge conflict"*) ;;
  *) return 1 ;;
  esac
  [ "$(head_of_50)" = "${head_of_pr_50}" ]
  [ "$(update_records | wc -l | tr -d ' ')" = 1 ]
}

@test "a head GitHub does not move within the timeout exits 5 and keeps the record" {
  pr_50_lacks_sibling '{"update_stalls": true}'

  OE_UPDATE_TIMEOUT=0 run --separate-stderr bash "${oe}" update o/r 5 "${head_of_pr_50}"

  [ "${status}" -eq 5 ]
  [ "$(update_records | wc -l | tr -d ' ')" = 1 ]
}

@test "a failed read of the pull request exits 1 and records nothing" {
  pr_50_lacks_sibling

  GH_FAIL=/pulls run --separate-stderr bash "${oe}" update o/r 5 "${head_of_pr_50}"

  [ "${status}" -eq 1 ]
  [ -z "$(update_records)" ]
}

@test "invalid arguments exit 2 and change nothing" {
  pr_50_lacks_sibling

  for args in "o/r 5" "o/r five ${head_of_pr_50}" "o/r 5 not-a-sha" "bad 5 ${head_of_pr_50}" "o/r 5 ${head_of_pr_50} extra"; do
    # shellcheck disable=SC2086 # one argument per word
    run --separate-stderr bash "${oe}" update ${args}

    [ "${status}" -eq 2 ]
  done
  [ "$(head_of_50)" = "${head_of_pr_50}" ]
  [ -z "$(update_records)" ]
}
