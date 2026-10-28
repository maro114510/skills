#!/usr/bin/env bats
# Tests for the oe subcommands that write on GitHub: claim, attempt, and question.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe against it.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - testdata/fake-github.jq lists every field of the state and its default.
# - The default branch head is "a" repeated 40 times.
# - Every comment oe writes is by the OWNER at 08:00.
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

@test "claiming an Issue without a branch creates it at the default branch head and writes a claim record" {
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
  [ "$(comment_count 5)" -eq 1 ]
  case "$(last_comment 5)" in
  '<!-- oe:claim -->'*) ;;
  *) return 1 ;;
  esac
}

@test "claiming an Issue whose branch already exists fails and leaves the ref and the comments unchanged" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "branch_sha": "cccccccccccccccccccccccccccccccccccccccc",
    "comments": [{"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"}]
  }]
}
JSON

  run bash "${oe}" claim o/r 5

  [ "${status}" -eq 4 ]
  [ "$(issue_field 5 branch_sha)" = '"cccccccccccccccccccccccccccccccccccccccc"' ]
  [ "$(comment_count 5)" -eq 1 ]
}

@test "a failed read of the default branch head creates no branch and writes no record" {
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
  [ "$(comment_count 5)" -eq 0 ]
}

@test "after a claim, oe ready starts the first Owner attempt" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "comments": [
      {"by": "OWNER", "at": "06:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "06:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "06:02", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "06:03", "body": "<!-- oe:attempt -->"}
    ]
  }]
}
JSON
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
