#!/usr/bin/env bats
# Tests for the oe subcommands that write records: claim, attempt, and question.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe against them.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/fake-github.jq lists every field of the state and its default.
# - testdata/records.bash writes and reads the host-local records under the test's own OE_STATE_DIR.
# - The default branch head is "a" repeated 40 times.
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

# Prints field $2 of Issue $1 in the saved GitHub state.
issue_field() {
  jq -c --argjson n "$1" ".issues[] | select(.number == \$n) | .$2" "${OE_GITHUB}"
}

# Prints the number of comments on Issue $1 in the saved GitHub state.
comment_count() {
  jq --argjson n "$1" '.issues[] | select(.number == $n) | .comments // [] | length' "${OE_GITHUB}"
}

# Prints the body of the newest comment on Issue $1 in the saved GitHub state.
last_comment() {
  jq -r --argjson n "$1" '.issues[] | select(.number == $n) | .comments | last | .body' "${OE_GITHUB}"
}

# Prints the action that oe ready gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

# oe claim

@test "claiming an Issue without a branch creates it at the default branch head, records the claim on this host, and posts no comment" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" claim o/r 5

  [ "${status}" -eq 0 ]
  [ "$(issue_field 5 branch)" = true ]
  [ "$(issue_field 5 branch_sha)" = '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' ]
  [ "$(comment_count 5)" -eq 0 ]
  [ "$(records_of 5)" = '{"kind":"claim","at":"2027-01-15T08:00:00Z"}' ]
}

@test "claiming an Issue whose branch already exists exits 4 and leaves the ref, the comments, and the records unchanged" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true, "branch_sha": "cccccccccccccccccccccccccccccccccccccccc"}]
}
JSON
  records 5 claim@07:00

  run bash "${oe}" claim o/r 5

  [ "${status}" -eq 4 ]
  [ "$(issue_field 5 branch_sha)" = '"cccccccccccccccccccccccccccccccccccccccc"' ]
  [ "$(comment_count 5)" -eq 0 ]
  [ "$(records_of 5)" = '{"kind":"claim","at":"2027-01-15T07:00:00Z"}' ]
}

@test "a failed read of the default branch head creates no branch and records nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}]
}
JSON

  GH_FAIL=/git/ref/heads/ run --separate-stderr bash "${oe}" claim o/r 5

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"default branch"*) ;;
  *) return 1 ;;
  esac
  [ "$(issue_field 5 branch)" = null ]
  [ -z "$(records_of 5)" ]
}

@test "after a claim, oe ready starts the first Owner attempt even when an earlier claim used every attempt" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}]
}
JSON
  records 5 claim@06:00 attempt@06:01 attempt@06:02 attempt@06:03
  run bash "${oe}" claim o/r 5
  [ "${status}" -eq 0 ]

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  case "${lines[0]}" in
  *"attempt 1 of 3"*) ;;
  *) return 1 ;;
  esac
}

@test "without OE_STATE_DIR, a claim records under XDG_STATE_HOME and leaves the checkout it runs in unchanged" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}]
}
JSON
  unset OE_STATE_DIR
  export XDG_STATE_HOME="${BATS_TEST_TMPDIR}/xdg"
  checkout="${BATS_TEST_TMPDIR}/checkout"
  git init -q "${checkout}"

  cd "${checkout}"
  run bash "${oe}" claim o/r 5

  [ "${status}" -eq 0 ]
  [ -z "$(git -C "${checkout}" status --porcelain --ignored)" ]
  case "$(record_file 5)" in
  "${XDG_STATE_HOME}/orchestrate-epic/records/"*) ;;
  *) return 1 ;;
  esac
  [ "$(records_of 5)" = '{"kind":"claim","at":"2027-01-15T08:00:00Z"}' ]
}

@test "without OE_STATE_DIR and XDG_STATE_HOME, a claim records under ~/.local/state" {
  case "$(command -v jq)" in
  */mise/shims/*) skip "jq is a mise shim, which fails once HOME moves" ;;
  esac
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5}]
}
JSON
  unset OE_STATE_DIR XDG_STATE_HOME
  export HOME="${BATS_TEST_TMPDIR}/home"

  run bash "${oe}" claim o/r 5

  [ "${status}" -eq 0 ]
  case "$(record_file 5)" in
  "${HOME}/.local/state/orchestrate-epic/records/"*) ;;
  *) return 1 ;;
  esac
  [ "$(records_of 5)" = '{"kind":"claim","at":"2027-01-15T08:00:00Z"}' ]
}

# oe attempt

@test "an Issue with two attempts since its claim gets a third attempt record and no comment" {
  github <<'JSON'
{
  "issues": [{"number": 5, "branch": true}]
}
JSON
  records 5 claim@07:00 attempt@07:01 attempt@07:30

  run bash "${oe}" attempt o/r 5

  [ "${status}" -eq 0 ]
  [ "${output}" = $'attempt\t3\t3' ]
  [ "$(comment_count 5)" -eq 0 ]
  [ "$(records_of 5 | tail -n1)" = '{"kind":"attempt","at":"2027-01-15T08:00:00Z"}' ]
}

@test "the fourth attempt since the claim is refused and nothing is recorded" {
  github <<'JSON'
{
  "issues": [{"number": 5, "branch": true}]
}
JSON
  records 5 claim@07:00 attempt@07:01 attempt@07:20 attempt@07:40

  run bash "${oe}" attempt o/r 5

  [ "${status}" -eq 4 ]
  [ "$(records_of 5 | wc -l)" -eq 4 ]
}

@test "attempts before the latest claim do not count toward the cap" {
  github <<'JSON'
{
  "issues": [{"number": 5, "branch": true}]
}
JSON
  records 5 claim@06:00 attempt@06:01 attempt@06:20 attempt@06:40 claim@07:00

  run bash "${oe}" attempt o/r 5

  [ "${status}" -eq 0 ]
  [ "${output}" = $'attempt\t1\t3' ]
  [ "$(records_of 5 | wc -l)" -eq 6 ]
}

@test "an unreadable record file fails the attempt and leaves the file unchanged" {
  github <<'JSON'
{
  "issues": [{"number": 5, "branch": true}]
}
JSON
  records 5 claim@07:00
  echo 'not json' >>"$(record_file 5)"
  before="$(cat "$(record_file 5)")"

  run --separate-stderr bash "${oe}" attempt o/r 5

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"record"*) ;;
  *) return 1 ;;
  esac
  [ "$(cat "$(record_file 5)")" = "${before}" ]
}

# oe question

@test "a posted question carries the marker and makes oe ready wait for the answer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true
  }]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run bash "${oe}" question o/r 5 <<<"Should the cache key include the locale?"
  [ "${status}" -eq 0 ]
  [ "$(last_comment 5)" = $'<!-- oe:question -->\nShould the cache key include the locale?' ]

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "an empty question is refused and nothing is posted" {
  github <<'JSON'
{
  "issues": [{"number": 5, "branch": true}]
}
JSON

  run bash "${oe}" question o/r 5 <<<"   "

  [ "${status}" -eq 2 ]
  [ "$(comment_count 5)" -eq 0 ]
}
