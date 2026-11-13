#!/usr/bin/env bats
# Tests for oe status.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe status against them.
# - testdata/fake-gh.sh stands in for gh and answers every read from that state; the gh wrapper logs every call.
# - testdata/records.bash writes the host-local records under the test's own OE_STATE_DIR.
# - Every test runs at 08:00 on the same day, in its own temporary directory.
# - While a session holds the Epic's lock, oe status draws the facts that session saved with oe ready --save and reads no GitHub,
#   so a test of that view calls session_reads after the session takes the lock.
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

# Starts agent $2, owner or verifier, on Issue $1 the way oe start leaves it:
# a running session holds the Epic's lock, and the agent's worktree exists, on the Issue branch for an Owner and detached for a Verifier.
# The test's working directory becomes the clone the session runs in.
agent_running() {
  local wt="${tmp}/clone-oe/issue-$1"
  git init -q "${tmp}/clone"
  git -C "${tmp}/clone" -c user.name=test -c user.email=test@example.com commit -q --no-verify --allow-empty -m base
  if [ "$2" = owner ]; then
    git -C "${tmp}/clone" worktree add -q -b "feat/issue-$1" "${wt}"
  else
    git -C "${tmp}/clone" worktree add -q --detach "${wt}"
  fi
  cd "${tmp}/clone" || return 1
  sleep 600 >/dev/null 2>&1 3>&- &
  sessions+=("$!")
  OE_SESSION_PID="$!" bash "${oe}" lock acquire o/r 1 >/dev/null
}

# Has the session that holds the lock read GitHub once, as its oe wait does, and forgets the calls that read made.
session_reads() {
  bash "${oe}" ready o/r 1 --save >/dev/null
  : >"${calls}"
}

# Starts a session that is not this shell's child and holds the Epic's lock, and leaves its process ID in $session.
# The arguments are a command prefix for oe lock acquire, such as env with variables.
# teardown ends it through the file if the test stops early.
detached_session() {
  session="$(
    sleep 600 >/dev/null 2>&1 3>&- &
    echo "$!"
  )"
  echo "${session}" >"${tmp}/detached-session"
  OE_SESSION_PID="${session}" "$@" bash "${oe}" lock acquire o/r 1 >/dev/null
}

# Replaces sleep with a script that runs the shell code $1 at the first sleep of --watch and $2 at the second, then returns at once.
between_refreshes() {
  {
    echo '#!/usr/bin/env bash'
    echo "n=\"\$(cat '${tmp}/sleeps' 2>/dev/null || echo 0)\""
    echo "echo \$((n + 1)) >'${tmp}/sleeps'"
    echo "case \"\$n\" in"
    echo "0) $1 ;;"
    echo "1) ${2:-:} ;;"
    echo 'esac'
  } >"${tmp}/bin/sleep"
  chmod +x "${tmp}/bin/sleep"
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

@test "with nothing waiting on the owner, the first line counts the Issues by state and the next says nothing waits, above the table" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "closed": true},
    {"number": 6, "branch": true,
      "pull_requests": [{"number": 60, "opened": "07:10", "checks": {"test": "in_progress"}}]},
    {"number": 7, "blocked_by": [{"number": 6, "state": "open"}]}
  ]
}
JSON
  records 6 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Epic #1: 1 done, 1 in progress, 1 waiting, 0 waiting on you" ]
  [ "${lines[1]}" = "Nothing waits on you." ]
  printf '%s\n' "${lines[2]}" | grep -q '^ISSUE  *STEP '
}

@test "an open question shows under the first line with the action, the Issue's URL, and why it stopped" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "branch": true,
      "comments": [{"by": "OWNER", "at": "07:05", "body": "<!-- oe:question -->\nWhich option?"}],
      "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]}
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Epic #1: 0 done, 0 in progress, 0 waiting, 1 waiting on you" ]
  [ "${lines[1]}" = "- #5 Answer the Owner's question in the session's conversation or with a comment on the Issue" ]
  [ "${lines[2]}" = "  https://github.com/o/r/issues/5" ]
  [ "${lines[3]}" = '  why: question https://github.com/o/r/issues/5#issuecomment-1 has no answer yet:\nWhich option?' ]
  printf '%s\n' "${lines[4]}" | grep -q '^ISSUE  *STEP '
}

@test "a parked Issue with a PR shows under the first line with the action, the PR's URL, and why it stopped" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "branch": true,
      "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]}
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01 attempt@07:20 attempt@07:40

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Epic #1: 0 done, 0 in progress, 0 waiting, 1 waiting on you" ]
  [ "${lines[1]}" = "- #5 Fix it by hand, or delete its branch so the AI starts over" ]
  [ "${lines[2]}" = "  https://github.com/o/r/pull/50" ]
  [ "${lines[3]}" = "  why: 3 attempts used; still: failure verdict on bbbbbbb" ]
}

@test "an Issue waiting for an engineer or for the merge shows under the first line, in Issue order" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "branch": true,
      "pull_requests": [{"number": 50, "state": "closed", "opened": "07:10"}]},
    {"number": 6, "branch": true,
      "pull_requests": [{"number": 60, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]}
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01
  records 6 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Epic #1: 0 done, 0 in progress, 0 waiting, 2 waiting on you" ]
  [ "${lines[1]}" = "- #5 Close the Issue, reopen the PR, or delete its branch so the AI starts over" ]
  [ "${lines[2]}" = "  https://github.com/o/r/pull/50" ]
  [ "${lines[3]}" = "  why: PR #50 closed without merging" ]
  [ "${lines[4]}" = "- #6 Review the PR, run its manual checks, and merge it" ]
  [ "${lines[5]}" = "  https://github.com/o/r/pull/60" ]
  [ "${lines[6]}" = "  why: success verdict on bbbbbbb" ]
}

@test "an Issue whose Owner runs shows that Owner and its current attempt instead of the next action, and counts in progress" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true}]
}
JSON
  # The Owner's attempt record is written before it starts, and it has pushed no PR yet.
  records 5 claim@07:00 attempt@07:01
  agent_running 5 owner
  session_reads

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Epic #1: 0 done, 1 in progress, 0 waiting, 0 waiting on you" ]
  [ "$(column_of 5 2)" = running ]
  [ "$(column_of 5 6)" = 1/3 ]
  [ "$(column_of 5 7)" = owner ]
  [ "$(column_of 5 9)" = "Owner attempt 1 of 3" ]
}

@test "an Issue whose Verifier runs its last start shows that Verifier and its start, not a park waiting on the owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["pending", "pending"]}]}]
}
JSON
  records 5 claim@07:00 attempt@07:01
  agent_running 5 verifier
  session_reads

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Epic #1: 0 done, 1 in progress, 0 waiting, 0 waiting on you" ]
  [ "$(column_of 5 2)" = running ]
  [ "$(column_of 5 7)" = verifier ]
  [ "$(column_of 5 9)" = "Verifier start 2 of 2 on bbbbbbb" ]
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

@test "a head waiting for its branch update waits on the owner at the pull request, and counts from its push" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 4, "closed": true, "pull_requests": [{"number": 40, "state": "merged", "opened": "07:05", "merged": "07:30"}]},
    {"number": 5, "branch": true,
      "pull_requests": [{"number": 50, "opened": "07:10", "pushed": "07:20", "checks": {"test": "success"},
        "verdicts": ["success"], "missing_merges": [40]}]}
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "Epic #1: 1 done, 0 in progress, 0 waiting, 1 waiting on you" ]
  [ "${lines[1]}" = "- #5 Update the PR's branch with its base branch" ]
  [ "${lines[2]}" = "  https://github.com/o/r/pull/50" ]
  [ "${lines[3]}" = "  why: bbbbbbb lacks sibling PR #40, merged into the base branch" ]
  [ "$(column_of 5 2)" = wait-update ]
  [ "$(column_of 5 8)" = 40m ]
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

@test "while a session holds the Epic's lock, the view shows the facts it saved and makes no gh call" {
  three_issues
  detached_session
  session_reads

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ ! -s "${calls}" ]
  [ "$(column_of 5 2)" = wait-merge ] || [ "$(column_of 5 2)" = start-owner ] || [ "$(column_of 5 2)" = parked ]
  [ "$(column_of 6 2)" = wait-ci ]
  [ "$(column_of 7 2)" = wait-dependencies ]
}

@test "the view shows when the facts were read, and marks them stale after facts_stale seconds" {
  three_issues
  detached_session
  session_reads

  OE_NOW=$((OE_NOW + 120)) run --separate-stderr bash "${oe}" status o/r 1
  [ "${status}" -eq 0 ]
  printf '%s\n' "${lines[@]}" | grep -qx 'Facts read 2m ago by the session\.'

  OE_NOW=$((OE_NOW + 301)) run --separate-stderr bash "${oe}" status o/r 1
  [ "${status}" -eq 0 ]
  printf '%s\n' "${lines[@]}" | grep -qx 'Facts read 5m ago by the session (stale: older than 5m)\.'
  [ ! -s "${calls}" ]
}

@test "with no session, the view reads GitHub and says so" {
  three_issues

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ -s "${calls}" ]
  printf '%s\n' "${lines[@]}" | grep -qx 'Read from GitHub just now\.'
}

@test "a session that saved no read since it took the lock shows no Issues and says so, without a gh call" {
  three_issues
  # A read saved by an earlier session is older than this session's lock.
  bash "${oe}" ready o/r 1 --save >/dev/null
  : >"${calls}"
  OE_NOW=$((OE_NOW + 60)) detached_session

  OE_NOW=$((OE_NOW + 120)) run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ ! -s "${calls}" ]
  printf '%s\n' "${lines[@]}" | grep -qx 'The session has saved no read of GitHub yet\.'
  [ -z "$(row_of 5)" ]
}

@test "a failed read of the session stays on the view with the last facts until a read succeeds" {
  three_issues
  detached_session
  session_reads

  OE_NOW=$((OE_NOW + 180)) GH_FAIL=subIssues run --separate-stderr bash "${oe}" ready o/r 1 --save
  [ "${status}" -eq 1 ]
  : >"${calls}"

  OE_NOW=$((OE_NOW + 240)) run --separate-stderr bash "${oe}" status o/r 1
  [ "${status}" -eq 0 ]
  [ ! -s "${calls}" ]
  [ "$(column_of 6 2)" = wait-ci ]
  printf '%s\n' "${lines[@]}" | grep -qx 'Facts read 4m ago by the session\.'
  printf '%s\n' "${lines[@]}" | grep -q '^Read failed 1m ago: '

  OE_NOW=$((OE_NOW + 300)) bash "${oe}" ready o/r 1 --save >/dev/null
  OE_NOW=$((OE_NOW + 300)) run --separate-stderr bash "${oe}" status o/r 1
  [ "${status}" -eq 0 ]
  printf '%s\n' "${lines[@]}" | grep -qx 'Facts read 0s ago by the session\.'
  run ! bash -c 'printf "%s\n" "$@" | grep -q "^Read failed"' _ "${lines[@]}"
}

@test "--watch with no session holding the Epic's lock draws once and exits 0" {
  three_issues

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=5 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ISSUE ')" -eq 1 ]
  [ "$(grep -c 'epic=1' "${calls}")" -eq 1 ]
}

@test "--watch while a session holds the Epic's lock shows what the session saved next, without reading GitHub itself" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "in_progress"}}]}]
}
JSON
  records 5 claim@07:00 attempt@07:01
  detached_session
  session_reads
  # The session's oe wait reads again between the two refreshes, after the checks passed.
  sed 's/in_progress/success/' "${OE_GITHUB}" >"${tmp}/github-passed.json"
  between_refreshes "OE_GITHUB='${tmp}/github-passed.json' bash '${oe}' ready o/r 1 --save >/dev/null 2>&1; : >'${calls}'"

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=2 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  [ ! -s "${calls}" ]
  steps="$(row_of 5 | while read -r _ step _; do echo "${step}"; done)"
  [ "${steps}" = $'wait-ci\nstart-verifier' ]
}

@test "--watch that saw a session hold the Epic's lock reads GitHub once after the session ends, draws it, and exits 0" {
  three_issues
  detached_session
  session_reads
  between_refreshes "kill ${session}"

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=10 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ISSUE ')" -eq 2 ]
  [ "$(grep -c 'epic=1' "${calls}")" -eq 1 ]
}

@test "--watch whose read after its session ended fails keeps the failure under the last view, retries, and exits 0 after it draws" {
  three_issues
  detached_session
  session_reads
  cat >"${tmp}/bin/gh" <<GH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${calls}"
[ ! -e "${tmp}/gh-down" ] || exit 1
exec bash "${BATS_TEST_DIRNAME}/testdata/fake-gh.sh" "\$@"
GH
  between_refreshes "kill ${session}; touch '${tmp}/gh-down'" "rm -f '${tmp}/gh-down'"

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=10 run --separate-stderr bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  # The first view, the same view with the failure under it, and the last view.
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ISSUE ')" -eq 3 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^oe status: the read failed')" -eq 1 ]
  [[ "${stderr}" == *"oe status: the read failed"* ]]
}

@test "--watch under another TZ and locale shows the facts while the holder that took the lock under UTC and C runs, and reads once after it ends" {
  three_issues
  detached_session env -u LC_ALL -u LC_TIME TZ=UTC LANG=C
  session_reads
  between_refreshes "kill ${session}"

  OE_WAIT_INTERVAL=0 OE_STATUS_REFRESHES=10 run --separate-stderr env TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 bash "${oe}" status o/r 1 --watch

  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ISSUE ')" -eq 2 ]
  [ "$(grep -c 'epic=1' "${calls}")" -eq 1 ]
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
  session_reads

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 7)" = verifier ]
  [ "$(column_of 6 7)" = - ]

  { kill "${session}" && wait "${session}"; } 2>/dev/null || true
  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 7)" = - ]
}

@test "under another TZ and locale, the agent column names the role while the holder that took the lock under UTC and C runs" {
  three_issues
  git init -q "${tmp}/clone"
  git -C "${tmp}/clone" -c user.name=test -c user.email=test@example.com commit -q --no-verify --allow-empty -m base
  git -C "${tmp}/clone" worktree add -q --detach "${tmp}/clone-oe/issue-5"
  cd "${tmp}/clone" || return 1
  detached_session env -u LC_ALL -u LC_TIME TZ=UTC LANG=C
  session_reads

  run --separate-stderr env TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 7)" = verifier ]
}

@test "an Issue whose PR moved during the read shows as read-again and the other Issues are shown as usual" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [
    {"number": 5, "branch": true,
      "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]},
    {"number": 6}
  ]
}
JSON
  records 5 claim@07:00 attempt@07:01

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 2)" = read-again ]
  [ "$(column_of 6 2)" = claim ]
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

@test "a default branch head with no checks past the grace shows each Issue's step and no end line" {
  github <<'JSON'
{
  "default_branch": {"pushed": "07:00"},
  "issues": [{"number": 5}]
}
JSON

  run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 0 ]
  [ "$(column_of 5 2)" = claim ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^end:')" -eq 0 ]
}

@test "a failed GitHub read exits 1 and prints nothing" {
  three_issues

  GH_FAIL=subIssues run --separate-stderr bash "${oe}" status o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}
