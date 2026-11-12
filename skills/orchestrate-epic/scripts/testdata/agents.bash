# shellcheck shell=bash
# Test helpers that leave an agent running the way oe start leaves it, loaded by a bats suite with `load testdata/agents`.
#
# - A suite loads testdata/records first, sets OE_STATE_DIR to a directory of its own test, and calls stop_sessions in teardown.
# - The first helper call makes a clone under the test's directory the working directory, so oe finds the worktree root from it.
# - The session is a process the test starts, holding the lock of Epic 1 in o/r.

# Makes a clone the working directory, with its agents' worktrees under OE_WORKTREE_ROOT, once per test.
in_clone() {
  local clone="${BATS_TEST_TMPDIR}/clone"
  if [[ ! -d "${clone}/.git" ]]; then
    git init -q "${clone}"
  fi
  export OE_WORKTREE_ROOT="${BATS_TEST_TMPDIR}/clone-oe"
  cd "${clone}" || return 1
}

# Starts a process that stands for the session, and has it take the lock of Epic 1 in o/r.
# Sets session_pid and session_token for session_acquires_again.
session_holds_lock() {
  in_clone
  sleep 600 >/dev/null 2>&1 3>&- &
  session_pid=$!
  echo "${session_pid}" >>"${BATS_TEST_TMPDIR}/sessions"
  session_token="$(OE_SESSION_PID="${session_pid}" bash "${BATS_TEST_DIRNAME}/oe" lock acquire o/r 1 | sed -n 's/^token=//p')"
}

# Has the session that session_holds_lock started acquire its lock again with its token, as after a resume.
session_acquires_again() {
  OE_SESSION_PID="${session_pid}" bash "${BATS_TEST_DIRNAME}/oe" lock acquire o/r 1 "${session_token}" >/dev/null
}

# Leaves agent $2, owner or verifier, running on Issue $1, as oe start leaves it:
# a run record written at $3, HH:MM on the day of the test, or at OE_NOW without it, and the agent's worktree.
agent_runs() {
  local at="${3:-}"
  in_clone
  [[ -n "${at}" ]] && at="2027-01-15T${at}:00Z" || at="$(jq -nr --argjson t "${OE_NOW}" '$t | todate')"
  mkdir -p "$(dirname "$(record_file "$1")")"
  jq -cn --arg at "${at}" --arg role "$2" '{kind: "run", at: $at, role: $role}' >>"$(record_file "$1")"
  git init -q "${OE_WORKTREE_ROOT}/issue-$1"
}

# Ends agent on Issue $1 the way the session does once the agent ends: its worktree goes away.
agent_ends() {
  rm -rf "${OE_WORKTREE_ROOT}/issue-$1"
}

# Stops every session a test started.
stop_sessions() {
  [[ -e "${BATS_TEST_TMPDIR}/sessions" ]] || return 0
  while read -r pid; do
    { kill "${pid}" && wait "${pid}"; } 2>/dev/null || true
  done <"${BATS_TEST_TMPDIR}/sessions"
}
