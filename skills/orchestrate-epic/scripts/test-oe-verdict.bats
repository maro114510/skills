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
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  head_of_pr_15=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb15
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Saves a state where Issue 5 has its open PR 15 passed its checks.
pr_15_passed_checks() {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"test": "success"}}]
  }]
}
JSON
}

# Prints the oe/verify states written on SHA $1, newest first, one per line.
verdicts_on() {
  jq -r --arg sha "$1" '.written_statuses[]? | select(.sha == $sha and .context == "oe/verify") | .state' "${OE_GITHUB}"
}

# Prints the oe/verify statuses written on SHA $1 as JSON, newest first.
statuses_on() {
  jq -c --arg sha "$1" '[.written_statuses[]? | select(.sha == $sha and .context == "oe/verify")]' "${OE_GITHUB}"
}

# Prints the conversation comments on pull request $1 as JSON.
pr_comments() {
  jq -c --argjson n "$1" '[.issues[].pull_requests[]? | select(.number == $n) | .comments // [] | .[]]' "${OE_GITHUB}"
}

# Prints the body of pull request $1.
pr_body() {
  jq -r --argjson n "$1" '.issues[].pull_requests[]? | select(.number == $n) | .body // ""' "${OE_GITHUB}"
}

# Prints the findings block of pull request $1, from its start marker line to its end marker line.
findings_block() {
  pr_body "$1" | sed -n '/^<!-- oe:findings -->$/,/^<!-- oe:findings-end -->$/p'
}

# Prints how many findings blocks the body of pull request $1 holds.
findings_blocks() {
  pr_body "$1" | grep -c '^<!-- oe:findings -->$'
}

# Sets the body of pull request 15 to $1.
pr_15_body() {
  jq --arg body "$1" '.issues[0].pull_requests[0].body = $body' "${OE_GITHUB}" >"${OE_GITHUB}.new"
  mv "${OE_GITHUB}.new" "${OE_GITHUB}"
}

# Prints the action that oe ready gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

# Prints every file under the state directory with the hash of its content, one per line.
state_files() {
  [ ! -d "${OE_STATE_DIR}" ] || find "${OE_STATE_DIR}" -type f -exec git hash-object {} + | sort
}

@test "a success verdict on the PR head shows up on that SHA with no comment, and a push leaves the new head without a verdict" {
  pr_15_passed_checks
  before="$(state_files)"

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> [behavior] ran it; observed ok"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}")" = success ]
  [ "$(pr_comments 15)" = "[]" ]
  [ "$(state_files)" = "${before}" ]
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

@test "a failure verdict writes its findings as one block in the PR body with its SHA and state, posts no comment, and oe ready starts an Owner to repair it" {
  pr_15_passed_checks
  pr_15_body "Closes #5"
  before="$(state_files)"

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 2 -> failed: bats test-timeout.bats; observed exit 0 after 30s"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}")" = failure ]
  [ "$(pr_comments 15)" = "[]" ]
  [ "$(findings_blocks 15)" -eq 1 ]
  block="$(findings_block 15)"
  case "${block}" in
  *"criterion 2 -> failed: bats test-timeout.bats; observed exit 0 after 30s"*) ;;
  *) return 1 ;;
  esac
  case "${block}" in
  *"failure on ${head_of_pr_15}"*) ;;
  *) return 1 ;;
  esac
  case "$(pr_body 15)" in
  "Closes #5"*) ;;
  *) return 1 ;;
  esac
  [ "$(state_files)" = "${before}" ]

  run bash "${oe}" ready o/r 1

  [ "$(action_of 5)" = start-owner ]
  case "${lines[0]}" in
  *"failure verdict"*) ;;
  *) return 1 ;;
  esac
}

@test "a second verdict on the same PR replaces the block, so one block remains and the rest of the body stays" {
  pr_15_passed_checks
  pr_15_body "Closes #5"
  bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 1 -> failed: ran it; observed exit 1" >/dev/null

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 2 -> failed: ran it; observed exit 3"

  [ "${status}" -eq 0 ]
  [ "$(findings_blocks 15)" -eq 1 ]
  block="$(findings_block 15)"
  case "${block}" in
  *"criterion 2 -> failed: ran it; observed exit 3"*) ;;
  *) return 1 ;;
  esac
  case "${block}" in
  *"criterion 1"*) return 1 ;;
  *) ;;
  esac
  case "$(pr_body 15)" in
  "Closes #5"*) ;;
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
}

@test "a success verdict that holds an unconfirmed criterion keeps only that line in the block and posts no comment" {
  pr_15_passed_checks
  before="$(state_files)"

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> [behavior] ran it; observed ok
criterion 2 -> unconfirmed: a person must look at the screen"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}")" = success ]
  [ "$(pr_comments 15)" = "[]" ]
  [ "$(findings_blocks 15)" -eq 1 ]
  block="$(findings_block 15)"
  case "${block}" in
  *"success on ${head_of_pr_15}"*"criterion 2 -> unconfirmed: a person must look at the screen"*) ;;
  *) return 1 ;;
  esac
  case "${block}" in
  *"criterion 1"*) return 1 ;;
  *) ;;
  esac
  [ "$(state_files)" = "${before}" ]
}

@test "a success verdict with no unconfirmed criterion removes the block an earlier verdict wrote and keeps the rest of the body" {
  pr_15_passed_checks
  pr_15_body "Closes #5"
  bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 1 -> failed: ran it; observed exit 1" >/dev/null

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> [behavior] ran it; observed ok"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}" | head -n 1)" = success ]
  [ "$(findings_blocks 15)" -eq 0 ]
  [ "$(pr_body 15)" = "Closes #5" ]
}

@test "a criterion quoting a closing keyword, a mention, a task item, or the end marker appears in the block in a form that takes no effect" {
  pr_15_passed_checks
  end_marker="<!-- oe:findings-end -->"

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<EOF
Closes #1 -> failed: ran it; observed open
@alice approves -> failed: ran it; observed none
- [ ] the box is checked -> failed: ran it; observed unchecked
${end_marker} stays -> failed: ran it; observed gone
\`\`\`\` fence -> failed: ran it; observed broken
EOF

  [ "${status}" -eq 0 ]
  [ "$(findings_blocks 15)" -eq 1 ]
  body="$(pr_body 15)"
  # The end marker the criterion quotes is not one: only the block's own ends the block.
  [ "$(grep -c -- "${end_marker}" <<<"${body}")" -eq 1 ]
  [ "$(tail -n 1 <<<"${body}")" = "${end_marker}" ]
  if grep -Eiq '(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]' <<<"${body}"; then return 1; fi
  if grep -q '@alice' <<<"${body}"; then return 1; fi
  # Every quoted line sits inside one fenced code block, so no line renders as a task item.
  fence="$(grep -E '^`{3,}' <<<"${body}" | head -n 1)"
  [ "${#fence}" -gt 4 ]
  inside="$(awk -v f="${fence}" '$0 == f { n++; next } n == 1' <<<"${body}")"
  [ "$(grep -c -- '-> failed:' <<<"${inside}")" -eq 5 ]
  [ "$(grep -c -- '-> failed:' <<<"${body}")" -eq 5 ]
}

@test "findings beyond the size cap are cut at a line, and the block says how many lines were cut" {
  pr_15_passed_checks
  padding="$(printf '%0300d' 0)"
  long="$(for i in $(seq 1 200); do echo "criterion ${i} -> failed: ran it; observed ${padding}"; done)"

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"${long}"

  [ "${status}" -eq 0 ]
  block="$(findings_block 15)"
  [ "${#block}" -lt 30000 ]
  grep -q '^criterion 1 -> failed' <<<"${block}"
  if grep -q '^criterion 200 -> failed' <<<"${block}"; then return 1; fi
  grep -Eq '[1-9][0-9]* more lines were cut' <<<"${block}"
}

@test "findings whose PR body write failed leave the SHA without a verdict and exit 1" {
  pr_15_passed_checks

  GH_FAIL="PATCH" run --separate-stderr bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 1 -> failed: ran it; observed exit 1"

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"findings"*) ;;
  *) return 1 ;;
  esac
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
  [ "$(pr_comments 15)" = "[]" ]
}

@test "a failed read of the PR body leaves the SHA without a verdict and exits 1" {
  pr_15_passed_checks

  GH_FAIL="pulls/15" run --separate-stderr bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> [behavior] ran it; observed ok"

  [ "${status}" -eq 1 ]
  [ -z "$(verdicts_on "${head_of_pr_15}")" ]
}

# Prints the description of the newest oe/verify status written on SHA $1.
description_on() {
  statuses_on "$1" | jq -r '.[0].description'
}

@test "a success verdict whose findings hold only manual lines is written as success and says nothing was verified" {
  pr_15_passed_checks

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> manual: needs a person to look at the screen"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}")" = success ]
  [ "$(description_on "${head_of_pr_15}")" = "Verifier success on PR #15, but nothing was verified" ]
  run bash "${oe}" ready o/r 1
  [ "$(action_of 5)" = wait-merge ]
}

@test "a success verdict whose findings hold only none lines is written as success and says nothing was verified" {
  pr_15_passed_checks

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> none"

  [ "${status}" -eq 0 ]
  [ "$(verdicts_on "${head_of_pr_15}")" = success ]
  [ "$(description_on "${head_of_pr_15}")" = "Verifier success on PR #15, but nothing was verified" ]
}

@test "a success verdict with one behavior line among none lines keeps the plain description" {
  pr_15_passed_checks

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> none
criterion 2 -> [behavior] ran it; observed ok"

  [ "${status}" -eq 0 ]
  [ "$(description_on "${head_of_pr_15}")" = "Verifier success on PR #15" ]
}

@test "a success verdict with one static line keeps the plain description" {
  pr_15_passed_checks

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" success <<<"criterion 1 -> [static] README.md:18"

  [ "${status}" -eq 0 ]
  [ "$(description_on "${head_of_pr_15}")" = "Verifier success on PR #15" ]
}

@test "a failure verdict keeps the plain description whatever lines its findings hold" {
  pr_15_passed_checks

  run bash "${oe}" verdict o/r 5 "${head_of_pr_15}" failure <<<"criterion 1 -> none"

  [ "${status}" -eq 0 ]
  [ "$(description_on "${head_of_pr_15}")" = "Verifier failure on PR #15" ]
}
