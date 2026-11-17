#!/usr/bin/env bats
# Tests for oe update, and for how oe-starts.jq reads its records.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe against them.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/fake-github-write.jq makes an accepted update replace the head with one that has no checks and no verdict.
# - A real update starts the new head's checks only under an identity whose pushes start workflows. No test can show that,
#   so the Design Doc names it as an accepted risk.
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
  head50="$(printf 'b%.0s' {1..38})50"
}

# Saves a state where Issue 4's PR 40 merged, and Issue 5's open PR 50 passed its checks and lacks that merge.
# $1 is a JSON object merged into PR 50.
lagging() {
  jq -n --argjson extra "${1:-{\}}" '{
    default_branch: {checks: {test: "success"}},
    issues: [
      {number: 4, closed: true, pull_requests: [{number: 40, state: "merged", opened: "07:05", merged: "07:30"}]},
      {number: 5, branch: true, pull_requests: [({number: 50, opened: "07:10", checks: {test: "success"},
        verdicts: ["success"], missing_merges: [40]} + $extra)]}
    ]
  }' >"${OE_GITHUB}"
}

# Prints the attempts that oe ready --facts shows for Issue $1.
attempts_of() {
  bash "${oe}" ready o/r 1 --facts | jq -r --argjson n "$1" 'select(.number == $n) | .attempts'
}

@test "an update moves the head to one without checks or verdict, and writes no comment" {
  lagging
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" update o/r 5

  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'updated\t50\t%s' "${head50}")" ]
  [ "$(jq -c .branch_updates "${OE_GITHUB}")" = "[50]" ]
  [ "$(jq '.issues[1].pull_requests[0] | has("verdicts")' "${OE_GITHUB}")" = false ]
  [ "$(jq '.issues[1] | has("comments")' "${OE_GITHUB}")" = false ]
}

@test "an update records the head it replaces, and spends no attempt" {
  lagging
  records 5 claim@07:00 "attempt@07:01#${head50}"

  run --separate-stderr bash "${oe}" update o/r 5

  [ "${status}" -eq 0 ]
  [ "$(records_of 5 | jq -sc 'map(.kind)')" = '["claim","attempt","update"]' ]
  [ "$(records_of 5 | jq -sr 'last | .head')" = "${head50}" ]

  [ "$(attempts_of 5)" = 0 ]
}

@test "an Owner start that pushed before the update still counts, and one that pushed nothing still does not" {
  lagging
  records 5 claim@07:00 "attempt@07:01#cccccccccccccccccccccccccccccccccccccccc"
  run --separate-stderr bash "${oe}" update o/r 5
  [ "${status}" -eq 0 ]
  [ "$(attempts_of 5)" = 1 ]

  lagging
  rm -rf "${OE_STATE_DIR}/records"
  records 5 claim@07:00 "attempt@07:01#${head50}"
  run --separate-stderr bash "${oe}" update o/r 5
  [ "${status}" -eq 0 ]
  [ "$(attempts_of 5)" = 0 ]
}

@test "repeating an update on the same head writes one record" {
  lagging
  records 5 claim@07:00 "attempt@07:01#${head50}"
  bash "${oe}" update o/r 5 >/dev/null
  lagging
  # GitHub accepted the update but the read still shows the old head
  run --separate-stderr bash "${oe}" update o/r 5

  [ "${status}" -eq 0 ]
  [ "$(records_of 5 | jq -s '[.[] | select(.kind == "update")] | length')" = 1 ]
}

@test "a branch whose merge conflicts is refused with exit 4 and the PR is left for an Owner" {
  lagging '{"conflicting": true}'
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" update o/r 5

  [ "${status}" -eq 4 ]
  [ -z "${output}" ]
  [ "$(jq -c '.branch_updates // []' "${OE_GITHUB}")" = "[]" ]
  run bash "${oe}" ready o/r 1
  [ "$(printf '%s\n' "${lines[@]}" | awk -F '\t' '$1 == 5 { print $2 }')" = start-owner ]
}

@test "an Issue branch without an open pull request is refused with exit 4" {
  printf '%s\n' '{"issues": [{"number": 5, "branch": true}]}' >"${OE_GITHUB}"
  records 5 claim@07:00

  run --separate-stderr bash "${oe}" update o/r 5

  [ "${status}" -eq 4 ]
  [ "$(records_of 5 | jq -s "[.[] | select(.kind == \"update\")] | length")" = 0 ]
}

@test "a failed GitHub read exits 1 and writes no record" {
  lagging
  records 5 claim@07:00 attempt@07:01

  GH_FAIL=/pulls run --separate-stderr bash "${oe}" update o/r 5

  [ "${status}" -eq 1 ]
  [ "$(records_of 5 | jq -s "[.[] | select(.kind == \"update\")] | length")" = 0 ]
}

@test "a failed update call exits 1" {
  lagging
  records 5 claim@07:00 attempt@07:01

  GH_FAIL=update-branch run --separate-stderr bash "${oe}" update o/r 5

  [ "${status}" -eq 1 ]
}

@test "invalid arguments exit 2" {
  run --separate-stderr bash "${oe}" update o/r
  [ "${status}" -eq 2 ]
  run --separate-stderr bash "${oe}" update o/r five
  [ "${status}" -eq 2 ]
}
