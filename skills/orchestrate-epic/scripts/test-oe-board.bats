#!/usr/bin/env bats
# Tests for oe board.
#
# - testdata/fake-herdr.sh stands in for herdr, logs every call, and answers from files the test writes.
# - Each test runs in a clone of its own, with its own git config and OE_STATE_DIR, and starts outside Herdr.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  scripts="$(cd "${BATS_TEST_DIRNAME}" && pwd)"
  oe="${scripts}/oe"
  tmp="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
  export OE_STATE_DIR="${tmp}/state"
  export FAKE_HERDR_DIR="${tmp}/herdr"
  calls="${FAKE_HERDR_DIR}/calls"
  mkdir -p "${tmp}/bin" "${FAKE_HERDR_DIR}"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-herdr.sh" "$@"\n' "${scripts}" >"${tmp}/bin/herdr"
  chmod +x "${tmp}/bin/herdr"
  export PATH="${tmp}/bin:${PATH}"
  # The user's own skills.herdr and Herdr session must not leak into a test.
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  export GIT_CONFIG_GLOBAL="${tmp}/gitconfig" GIT_CONFIG_NOSYSTEM=1
  export OE_BOARD_START_TIMEOUT=0
  # The board carries the session's time zone and locale, so each test sets them.
  export TZ=UTC LANG=C
  unset LC_ALL LC_TIME
  clone="${tmp}/clone"
  git init -q "${clone}"
  cd "${clone}" || return 1
}

# Makes this test run inside a Herdr pane, on the server at socket $1, a.sock by default.
inside_herdr() {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="${tmp}/${1:-a.sock}"
}

# Prints the process-info answer for pane $1 whose foreground runs the processes whose argv are the JSON arrays $2...
pane_info() {
  local pane="$1"
  shift
  jq -cn --arg pane "${pane}" --args '{result: {process_info: {
      foreground_process_group_id: 200,
      foreground_processes: [$ARGS.positional[] | fromjson | {argv: ., pid: 200}],
      pane_id: $pane, shell_pid: 100}, type: "pane_process_info"}}' "$@"
}

# The argv of the board of Epic 1 in o/r, as oe status shows it after oe execs it.
board_argv() {
  jq -cn --arg s "${scripts}/oe-status.sh" '["bash", $s, "o/r", "1", "--watch"]'
}

# Makes a run in any pane start the board in it.
board_starts_on_run() {
  pane_info any "$(board_argv)" '["sleep","180"]' >"${FAKE_HERDR_DIR}/board.json"
}

# Makes pane $1 sit at its shell's prompt, as after the board stopped.
pane_at_prompt() {
  jq -cn --arg pane "$1" '{result: {process_info: {foreground_process_group_id: 100,
    foreground_processes: [{argv: ["-zsh"], pid: 100}], pane_id: $pane, shell_pid: 100}, type: "pane_process_info"}}' \
    >"${FAKE_HERDR_DIR}/process-${1//:/_}.json"
}

# Makes pane $1 run a process the user started there.
pane_runs_editor() {
  pane_info "$1" '["vim","notes.md"]' >"${FAKE_HERDR_DIR}/process-${1//:/_}.json"
}

# Makes pane $1 disappear, as when the user closed it.
pane_closed() {
  rm -f "${FAKE_HERDR_DIR}/process-${1//:/_}.json"
}

# Prints the number of herdr calls that start with $1.
calls_starting() {
  [ -e "${calls}" ] || {
    echo 0
    return
  }
  grep -c "^$1" "${calls}" || true
}

# The command a board pane runs: oe status --watch for Epic 1 in o/r, from the clone, at the board's refresh interval.
# The pane's shell does not inherit the session's environment, so the command carries the session's time zone and locale,
# names the session's state directory, and names the agents' worktree root, by default the clone's sibling with -oe appended.
board_interval_seconds=180
board_command() {
  printf 'cd %s && env -u LC_ALL -u LC_TIME TZ=UTC LANG=C OE_WAIT_INTERVAL=%s OE_STATE_DIR=%s OE_WORKTREE_ROOT=%s bash %s status o/r 1 --watch' \
    "${clone}" "${board_interval_seconds}" "${OE_STATE_DIR}" "${tmp}/clone-oe" "${oe}"
}

@test "outside Herdr, oe board says the board is off and runs no herdr command, even with skills.herdr true" {
  git config skills.herdr true

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\toff\tnot inside Herdr' ]
  [ ! -e "${calls}" ]
}

@test "inside Herdr without skills.herdr, oe board says the board is off and runs no herdr command" {
  inside_herdr

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\toff\tgit config skills.herdr is not true' ]
  [ ! -e "${calls}" ]
}

@test "inside Herdr with skills.herdr false, oe board says the board is off and runs no herdr command" {
  inside_herdr
  git config skills.herdr false

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\toff\tgit config skills.herdr is not true' ]
  [ ! -e "${calls}" ]
}

@test "inside Herdr, a skills.herdr that is not a boolean exits 2 naming the key, and runs no herdr command" {
  inside_herdr
  git config skills.herdr ture

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 2 ]
  [ -z "${output}" ]
  case "${stderr}" in
  *skills.herdr*) ;;
  *) return 1 ;;
  esac
  [ ! -e "${calls}" ]
}

@test "inside Herdr with skills.herdr true, the first run opens a pane below the session's pane without focus and starts the board in it" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\topened\tw1:p9' ]
  [ "$(calls_starting 'pane split')" -eq 1 ]
  split="$(grep '^pane split' "${calls}")"
  for part in "--current" "--direction down" "--cwd ${clone}" "--no-focus"; do
    case " ${split} " in
    *" ${part} "*) ;;
    *) return 1 ;;
    esac
  done
  grep -qxF "pane run w1:p9 $(board_command)" "${calls}"
}

@test "the board reads the state directory and the worktree root this session resolves, not the ones the pane's shell would" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  unset OE_STATE_DIR
  export XDG_STATE_HOME="${tmp}/xdg"
  export OE_WORKTREE_ROOT="${tmp}/worktrees"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  grep -qxF "pane run w1:p9 cd ${clone} && env -u LC_ALL -u LC_TIME TZ=UTC LANG=C OE_WAIT_INTERVAL=${board_interval_seconds} OE_STATE_DIR=${tmp}/xdg/orchestrate-epic OE_WORKTREE_ROOT=${tmp}/worktrees bash ${oe} status o/r 1 --watch" "${calls}"
}

@test "the board keeps the session's time zone and locale, which its lock check reads, and unsets those the session leaves unset" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  export TZ=Asia/Tokyo LC_TIME=ja_JP.UTF-8
  unset LC_ALL LANG

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  grep -qF "pane run w1:p9 cd ${clone} && env -u LC_ALL -u LANG TZ=Asia/Tokyo LC_TIME=ja_JP.UTF-8 OE_WAIT_INTERVAL=" "${calls}"
}

@test "a second run while the board runs opens no second pane" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  bash "${oe}" board o/r 1 >/dev/null

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\treused\tw1:p9' ]
  [ "$(calls_starting 'pane split')" -eq 1 ]
  [ "$(calls_starting 'pane run')" -eq 1 ]
}

@test "a rerun after the board stopped starts it again in the same pane" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  bash "${oe}" board o/r 1 >/dev/null
  pane_at_prompt w1:p9
  : >"${calls}"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\trestarted\tw1:p9' ]
  [ "$(calls_starting 'pane split')" -eq 0 ]
  grep -qxF "pane run w1:p9 $(board_command)" "${calls}"
}

@test "a recorded pane that runs something else gets no input, and a new pane opens for the board" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  bash "${oe}" board o/r 1 >/dev/null
  pane_runs_editor w1:p9
  echo w1:p10 >"${FAKE_HERDR_DIR}/split-pane"
  : >"${calls}"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\topened\tw1:p10' ]
  [ "$(calls_starting 'pane run w1:p9')" -eq 0 ]
  grep -qxF "pane run w1:p10 $(board_command)" "${calls}"
}

@test "a recorded pane that was closed is replaced by a new pane" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  bash "${oe}" board o/r 1 >/dev/null
  pane_closed w1:p9
  echo w1:p10 >"${FAKE_HERDR_DIR}/split-pane"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\topened\tw1:p10' ]
  [ "$(calls_starting 'pane split')" -eq 2 ]
}

@test "a pane recorded on another Herdr server is never touched, and a new pane opens on this one" {
  inside_herdr a.sock
  git config skills.herdr true
  board_starts_on_run
  bash "${oe}" board o/r 1 >/dev/null
  inside_herdr b.sock
  echo w1:p10 >"${FAKE_HERDR_DIR}/split-pane"
  : >"${calls}"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\topened\tw1:p10' ]
  run ! grep -q 'w1:p9' "${calls}"
}

@test "a split that herdr refuses exits 1 with herdr's error" {
  inside_herdr
  git config skills.herdr true
  echo server_not_running >"${FAKE_HERDR_DIR}/split-fails"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  case "${stderr}" in
  *server_not_running*) ;;
  *) return 1 ;;
  esac
}

@test "a board command that does not start exits 1 naming the pane" {
  inside_herdr
  git config skills.herdr true

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  case "${stderr}" in
  *w1:p9*) ;;
  *) return 1 ;;
  esac
}

@test "inside Herdr with skills.herdr true and no herdr on PATH, oe board exits 1" {
  inside_herdr
  git config skills.herdr true
  # Every directory that holds a herdr leaves PATH, the real one's included.
  without=""
  IFS=: read -ra dirs <<<"${PATH}"
  for p in "${dirs[@]}"; do
    [ -x "${p}/herdr" ] || without="${without:+${without}:}${p}"
  done
  PATH="${without}"
  run ! command -v herdr

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "a pane whose shell starts slower than the start timeout exits 1 naming the slow shell, and a rerun sends nothing again and waits for the queued start" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  echo 2 >"${FAKE_HERDR_DIR}/slow-shell"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  case "${stderr}" in
  *w1:p9*"has not finished starting"*) ;;
  *) return 1 ;;
  esac
  [ "$(calls_starting 'pane run')" -eq 1 ]

  OE_BOARD_START_TIMEOUT=10 run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\trestarted\tw1:p9' ]
  [ "$(calls_starting 'pane run')" -eq 1 ]
  [ "$(calls_starting 'pane split')" -eq 1 ]
}

@test "a start sent over 10 minutes ago and never seen running is sent again" {
  inside_herdr
  git config skills.herdr true
  board_starts_on_run
  echo 99 >"${FAKE_HERDR_DIR}/slow-shell"
  run bash "${oe}" board o/r 1
  [ "${status}" -eq 1 ]
  record="$(echo "${OE_STATE_DIR}"/boards/*/1)"
  jq -c '.sent = 1' "${record}" >"${record}.new" && mv "${record}.new" "${record}"
  rm -f "${FAKE_HERDR_DIR}/slow-shell" "${FAKE_HERDR_DIR}"/pending-*

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = $'board\trestarted\tw1:p9' ]
  [ "$(calls_starting 'pane run')" -eq 2 ]
}

@test "a start that times out in a pane that is not at its prompt gives the plain error, not the slow shell one" {
  inside_herdr
  git config skills.herdr true
  # The pane is taken over right after the run, so it never shows the board or its prompt again.
  board_starts_on_run
  jq -c '.result.process_info.foreground_process_group_id = 200 | .result.process_info.foreground_processes = [{argv: ["vim"], pid: 200}]' \
    "${FAKE_HERDR_DIR}/board.json" >"${FAKE_HERDR_DIR}/board.new" && mv "${FAKE_HERDR_DIR}/board.new" "${FAKE_HERDR_DIR}/board.json"

  run --separate-stderr bash "${oe}" board o/r 1

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"has not finished starting"*) return 1 ;;
  *) ;;
  esac
}

@test "oe status --watch clears a terminal that holds the pane's startup output and shows a line at once, while the first read runs" {
  command -v python3 >/dev/null || skip "python3 is needed for a terminal"
  # A shell whose .envrc is slow prints this before it runs the board's command.
  printf '#!/usr/bin/env bash\nsleep 1\nexit 1\n' >"${tmp}/bin/gh"
  chmod +x "${tmp}/bin/gh"

  run python3 - "${oe}" <<'PY'
import os, pty, select, sys, time
oe = sys.argv[1]
noise = "direnv: ([direnv export zsh]) is taking a while to execute. Use CTRL-C to give up."
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(OE_WAIT_INTERVAL="0", OE_STATUS_REFRESHES="1")
    os.execvp("bash", ["bash", "-c", 'echo "$1"; exec bash "$2" status o/r 1 --watch', "bash", noise, oe])
out = b""
start = time.time()
first_line_at = None
while time.time() - start < 20:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        if first_line_at is None and b"reading Epic #1 of o/r" in out:
            first_line_at = time.time() - start
os.waitpid(pid, 0)
text = out.decode(errors="replace")
clear = "\x1b[H\x1b[2J"
assert clear in text, "the screen was never cleared"
before, after = text.split(clear, 1)
assert noise in before and noise not in after, "startup output remains after the clear"
assert first_line_at is not None and first_line_at < 0.9, "no line before the first read ended: %r" % first_line_at
print("ok")
PY

  [ "${status}" -eq 0 ]
  [ "${output}" = ok ]
}
