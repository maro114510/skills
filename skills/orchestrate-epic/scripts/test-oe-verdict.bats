#!/usr/bin/env bats
# Tests for oe verdict.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe against it.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/fake-github.jq lists every field of the state and its default.
# - A pull request's head SHA is named by its number unless head_sha sets it: PR 15's is 38 b's then 15.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  head_of_pr_15=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb15
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Saves a state where Issue 5 is claimed and its open PR 15 passed its checks.
pr_15_passed_checks() {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"test": "success"}}]
  }]
}
JSON
}

# Prints the oe/verify states written on SHA $1, newest first, one per line.
verdicts_on() {
  jq -r --arg sha "$1" '.written_statuses[]? | select(.sha == $sha and .context == "oe/verify") | .state' "${OE_GITHUB}"
}

# Prints the conversation comments on pull request $1 as JSON.
pr_comments() {
  jq -c --argjson n "$1" '[.issues[].pull_requests[]? | select(.number == $n) | .comments // [] | .[]]' "${OE_GITHUB}"
}

# Prints the action that oe ready gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

@test "a success verdict on the PR head shows up on that SHA, and a push leaves the new head without a verdict" {
  pr_15_passed_checks

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> [behavior] ran it; observed ok"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}")" = success ]
  run bash "${oe}" ready o/r 1
  [ "$(action_of 5)" = wait-merge ]

  pushed_head=dddddddddddddddddddddddddddddddddddddddd
  jq --arg sha "${pushed_head}" '.issues[0].pull_requests[0].head_sha = $sha' "${OE_GITHUB}" >"${OE_GITHUB}.new"
  mv "${OE_GITHUB}.new" "${OE_GITHUB}"

  run bash "${oe}" ready o/r 1

  [ "$(action_of 5)" = start-verifier ]
  [ -z "$(verdicts_on "${pushed_head}")" ]
  [ "$(verdicts_on "${head_of_pr_15}")" = success ]
}

@test "a failure verdict posts its findings as a marked PR comment that the status links to, and oe ready starts a repair Owner" {
  pr_15_passed_checks

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 2 -> none: no test exercises the timeout"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}")" = failure ]
  [ "$(pr_comments 15 | jq length)" -eq 1 ]
  body="$(pr_comments 15 | jq -r '.[0].body')"
  case "${body}" in
  '<!-- oe:verdict -->'*"${head_of_pr_15}"*"criterion 2 -> none: no test exercises the timeout"*) ;;
  *) return 1 ;;
  esac
  link="$(jq -r '.written_statuses[0].target_url' "${OE_GITHUB}")"
  [ "${link}" = "https://github.com/o/r/pull/15#issuecomment-1" ]

  run bash "${oe}" ready o/r 1

  [ "$(action_of 5)" = start-owner ]
  case "${lines[0]}" in
  *"failure verdict"*) ;;
  *) return 1 ;;
  esac
}

@test "a verdict for a SHA that is no longer the PR head writes nothing and exits non-zero" {
  pr_15_passed_checks
  stale_head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

  run --separate-stderr bash "${oe}" verdict o/r 5 "${stale_head}" success <<<"criterion 1 -> [behavior] ok"

  [ "${status}" -eq 4 ]
  [ -z "$(verdicts_on "${stale_head}")" ]
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
  [ "$(pr_comments 15)" = "[]" ]
}

@test "a verdict for an Issue with no open PR writes nothing and exits non-zero" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"}],
    "pull_requests": [{"number": 15, "state": "closed", "opened": "07:10"}]
  }]
}
JSON

  run --separate-stderr bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> [behavior] ok"

  [ "${status}" -eq 4 ]
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
  [ "$(pr_comments 15)" = "[]" ]
}

@test "a verdict with empty findings is refused and writes nothing" {
  pr_15_passed_checks

  run --separate-stderr bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"   "

  [ "${status}" -eq 2 ]
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
  [ "$(pr_comments 15)" = "[]" ]
}

@test "a verdict state other than success or failure is refused and writes nothing" {
  pr_15_passed_checks

  run --separate-stderr bash "${oe}" verdict o/r 5 "${head_of_pr_15}" pending <<<"criterion 1 -> none"

  [ "${status}" -eq 2 ]
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
}

@test "a failed read of the pull request list writes nothing" {
  pr_15_passed_checks

  GH_FAIL="/pulls?" run --separate-stderr bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> ok"

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"pull request"*) ;;
  *) return 1 ;;
  esac
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
  [ "$(pr_comments 15)" = "[]" ]
}

@test "a failed findings comment leaves the SHA without a verdict" {
  pr_15_passed_checks

  GH_FAIL="/issues/15/comments" run --separate-stderr bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 1 -> none"

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"findings"*) ;;
  *) return 1 ;;
  esac
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
}
