#!/usr/bin/env bats
# Tests for oe status.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe status against them.
# - testdata/fake-gh.sh stands in for gh and answers every read from that state; the gh wrapper logs every call.
# - testdata/records.bash writes the host-local records under the test's own OE_STATE_DIR.
# - Every test runs at 08:00 on the same day, in its own temporary directory.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  load testdata/records
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  oe="${BATS_TEST_DIRNAME}/oe"
  tmp="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
  calls="${tmp}/gh-calls"
  mkdir -p "${tmp}/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' \
    "${calls}" "${BATS_TEST_DIRNAME}" >"${tmp}/bin/gh"
  chmod +x "${tmp}/bin/gh"
  export PATH="${tmp}/bin:${PATH}"
  export OE_GITHUB="${tmp}/github.json"
  unset OE_WORKTREE_ROOT OE_GITHUB_NEXT
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  sessions=()
  cd "${tmp}" || return 1
}

teardown() {
  for pid in ${sessions[@]+"${sessions[@]}"}; do
    { kill "${pid}" && wait "${pid}"; } 2>/dev/null || true
  done
  if [ -e "${tmp}/detached-session" ]; then
    kill "$(cat "${tmp}/detached-session")" 2>/dev/null || true
  fi
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Saves, from stdin, the state that replaces the current one at the second Epic read.
github_at_second_read() {
  export OE_GITHUB_NEXT="${tmp}/github-next.json"
  cat >"${OE_GITHUB_NEXT}"
}

# Appends a verdict record on the SHA $2 with the state $3 and the findings $4 to Issue $1, written at 07:30.
verdict_record() {
  jq -cn --arg sha "$2" --arg state "$3" --arg findings "$4" \
    '{kind: "verdict", at: "2027-01-15T07:30:00Z", sha: $sha, state: $state, findings: $findings}' >>"$(record_file "$1")"
}

# Prints the row of Issue $1 from the output, or nothing.
row_of() {
  printf '%s\n' "${lines[@]}" | while read -r issue rest; do
    if [ "${issue}" = "#$1" ]; then
      printf '%s %s\n' "${issue}" "${rest}"
    fi
  done
}

# Prints column $2 of the row of Issue $1, counting ISSUE as column 1.
# Every column but the last, REASON, is one word.
column_of() {
  row_of "$1" | head -n1 | {
    read -r issue step pr ci verdict attempts agent since reason
    case "$2" in
    1) echo "${issue}" ;;
    2) echo "${step}" ;;
    3) echo "${pr}" ;;
    4) echo "${ci}" ;;
    5) echo "${verdict}" ;;
    6) echo "${attempts}" ;;
    7) echo "${agent}" ;;
    8) echo "${since}" ;;
    9) echo "${reason}" ;;
    esac
  }
}

# Saves a state where Issue 5 has PR 50 whose checks passed and whose head got a failure verdict,
# Issue 6 has PR 60 still running a check, and Issue 7 waits on the open Issue 5.
three_issues() {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "branch": true,
      "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]},
    {"number": 6, "branch": true,
      "pull_requests": [{"number": 60, "opened": "07:10", "checks": {"test": "in_progress"}}]},
    {"number": 7, "blocked_by": [{"number": 5, "state": "open"}]}
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01
  verdict_record 5 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb50 failure $'criterion 1 -> none\ncriterion 2 -> [behavior] bats passed'
  records 6 claim@07:00 attempt@07:02
}

@test "every Issue shows its step, PR, CI result, verdict, attempts, agent, time in step, and reason" {
  three_issues

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  printf '%s\n' "${lines[@]}" | grep -q '^ISSUE  *STEP  *PR  *CI  *VERDICT  *ATTEMPTS  *AGENT  *SINCE  *REASON$'

  [ "$(column_of 5 2)" = start-owner ]
  [ "$(column_of 5 3)" = "#50" ]
  [ "$(column_of 5 4)" = passed ]
  [ "$(column_of 5 5)" = failure ]
  [ "$(column_of 5 6)" = 1/3 ]
  [ "$(column_of 5 7)" = - ]
  # start-owner counts from the latest attempt, at 07:01.
  [ "$(column_of 5 8)" = 59m ]
  [ "$(column_of 5 9)" = "attempt 2 of 3: failure verdict on bbbbbbb" ]

  [ "$(column_of 6 2)" = wait-ci ]
  [ "$(column_of 6 3)" = "#60" ]
  [ "$(column_of 6 4)" = pending ]
  [ "$(column_of 6 5)" = - ]
  [ "$(column_of 6 6)" = 1/3 ]
  [ "$(column_of 6 7)" = - ]
  # wait-ci counts from the push of the head, at 07:10.
  [ "$(column_of 6 8)" = 50m ]
  [ "$(column_of 6 9)" = "checks pending on bbbbbbb: test" ]

  [ "$(column_of 7 2)" = wait-dependencies ]
  [ "$(column_of 7 3)" = - ]
  [ "$(column_of 7 4)" = - ]
  [ "$(column_of 7 5)" = - ]
  [ "$(column_of 7 6)" = 0/3 ]
  [ "$(column_of 7 7)" = - ]
  [ "$(column_of 7 8)" = - ]
  [ "$(column_of 7 9)" = "#5 open" ]
}

@test "an Issue whose PR head has a failure verdict shows that verdict's findings, and no finding of an older head" {
  three_issues
  verdict_record 5 cccccccccccccccccccccccccccccccccccccccc failure 'stale finding on an older head'
  # The record for the current head is written last, as when a later verdict follows an earlier one.
  verdict_record 5 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb50 failure $'criterion 1 -> none\ncriterion 2 -> [behavior] bats passed'

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  printf '%s\n' "${lines[@]}" | grep -qx '#5 failure verdict on bbbbbbb:'
  printf '%s\n' "${lines[@]}" | grep -qx '  criterion 1 -> none'
  printf '%s\n' "${lines[@]}" | grep -qx '  criterion 2 -> \[behavior\] bats passed'
  case "${output}" in
  *"stale finding"* | *"#6 failure verdict"*) return 1 ;;
  *) ;;
  esac
}

@test "waiting for an answer counts from the question, and waiting for the merge from the push of the head" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "branch": true,
      "comments": [{"by": "OWNER", "at": "07:05", "body": "<!-- oe:question -->\nWhich option?"}],
      "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]},
    {"number": 6, "branch": true,
      "pull_requests": [{"number": 60, "opened": "07:10", "pushed": "07:15", "checks": {"test": "success"}, "verdicts": ["success"]}]}
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01
  records 6 claim@07:00 attempt@07:01
  # Later events that start no step: the PR opened after the question, and the verdict recorded after the push.
  verdict_record 6 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb60 success 'criterion 1 -> [behavior] bats passed'

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 2)" = wait-answer ]
  [ "$(column_of 5 8)" = 55m ]
  [ "$(column_of 6 2)" = wait-merge ]
  [ "$(column_of 6 8)" = 45m ]
}

@test "oe status makes only GET calls to GitHub and leaves the host-local state unchanged" {
  three_issues
  before="$(cd "${OE_STATE_DIR}" && find . -type f | sort | xargs cat)"

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ -s "${calls}" ]
  [ "$(cd "${OE_STATE_DIR}" && find . -type f | sort | xargs cat)" = "${before}" ]
  [ ! -e "${OE_STATE_DIR}/locks.git" ]
  run ! grep -Eq -- '(^| )(-X|--method|POST)( |$)' "${calls}"
}

@test "--watch shows a state change on its next refresh" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "in_progress"}}]}]
}
JSON
  github_at_second_read <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]}]
}
JSON
  records 5 claim@07:00 attempt@07:01

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=2 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  steps="$(row_of 5 | while read -r _ step _; do echo "${step}"; done)"
  [ "${steps}" = $'wait-ci\nstart-verifier' ]
}

@test "--watch that saw a session hold the Epic's lock shows one more view after the session ends, then exits 0" {
  three_issues
  # The session is not this shell's child, so it is reaped as soon as it ends and stops counting as running.
  # teardown ends it through the file if the test stops early.
  session="$(
    sleep 600 >/dev/null 2>&1 3>&- &
    echo "$!"
  )"
  echo "${session}" >"${tmp}/detached-session"
  OE_SESSION_PID="${session}" bash "${oe}" lock acquire o/r 1 >/dev/null
  # The session ends during the second refresh's Epic read.
  cat >"${tmp}/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${calls}"
[ "\$(grep -c 'epic=1' "${calls}")" -ne 2 ] || kill ${session}
exec bash "${BATS_TEST_DIRNAME}/testdata/fake-gh.sh" "\$@"
EOF
  # Refresh 1 sees the session, refresh 2 reads while it ends, and refresh 3 finds it gone and is the last.
  views_until_end=3

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=10 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ISSUE ')" -eq "${views_until_end}" ]
}

@test "--watch whose first read after its session ended fails retries, and exits 0 after it draws the last view" {
  three_issues
  session="$(
    sleep 600 >/dev/null 2>&1 3>&- &
    echo "$!"
  )"
  echo "${session}" >"${tmp}/detached-session"
  OE_SESSION_PID="${session}" bash "${oe}" lock acquire o/r 1 >/dev/null
  # The session ends during the second refresh's Epic read, and the third refresh's Epic read fails.
  cat >"${tmp}/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${calls}"
reads="\$(grep -c 'epic=1' "${calls}")"
[ "\${reads}" -ne 2 ] || kill ${session}
[ "\${reads}" -ne 3 ] || exit 1
exec bash "${BATS_TEST_DIRNAME}/testdata/fake-gh.sh" "\$@"
EOF
  # Refreshes 1 and 2 draw views, refresh 3 fails, and refresh 4 draws the last view.
  views_until_end=3

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=10 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ISSUE ')" -eq "${views_until_end}" ]
  [ "$(grep -c 'epic=1' "${calls}")" -eq 4 ]
}

@test "--watch without a session holding the Epic's lock keeps refreshing" {
  three_issues

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=3 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ISSUE ')" -eq 3 ]
}

@test "the agent column names the role whose worktree exists while a running session holds the Epic's lock" {
  three_issues
  export GIT_CONFIG_GLOBAL="${tmp}/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git init -q "${tmp}/clone"
  git -C "${tmp}/clone" commit -q --allow-empty -m base
  # oe worktree puts Issue 5's Verifier worktree here, detached at the PR head.
  git -C "${tmp}/clone" worktree add -q --detach "${tmp}/clone-oe/issue-5"
  cd "${tmp}/clone" || return 1
  sleep 600 >/dev/null 2>&1 3>&- &
  session="$!"
  sessions+=("${session}")
  OE_SESSION_PID="${session}" bash "${oe}" lock acquire o/r 1 >/dev/null

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 7)" = verifier ]
  [ "$(column_of 6 7)" = - ]

  { kill "${session}" && wait "${session}"; } 2>/dev/null || true
  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 7)" = - ]
}

@test "under a failed check on the default branch, every Issue waits for it as in oe ready, without reading the Issues" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "failure"}},
  "issues": [{"number": 5, "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]}]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 2)" = wait-base ]
  [ "$(column_of 5 3)" = - ]
  [ "$(column_of 5 9)" = "checks failed on main head aaaaaaa: test" ]
}

@test "a default branch head with no checks past the grace shows the end of the session and no Issue" {
  github <<'JSON'
{
  "default_branch": {"pushed": "07:00"},
  "issues": [{"number": 5}]
}
JSON

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  printf '%s\n' "${lines[@]}" | grep -q '^end: no checks on main head aaaaaaa'
  [ -z "$(row_of 5)" ]
}

@test "a failed GitHub read exits 1 and prints nothing" {
  three_issues

  GH_FAIL=subIssues run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}
