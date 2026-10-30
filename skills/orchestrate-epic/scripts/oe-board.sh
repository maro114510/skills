#!/usr/bin/env bash
# oe board
#
# Opens the Epic's board: a Herdr pane, below the session's pane, that runs oe status --watch.
# It runs no herdr command unless the session runs inside Herdr and git config skills.herdr is true.
#
# Usage
#
#   oe board <owner/repo> <epic-number>
#
# - Run it from the clone the session runs in: the board runs there, and skills.herdr is read there.
# - The board refreshes every board_interval seconds, and stops by itself once the session holding the Epic's lock ends.
# - OE_BOARD_START_TIMEOUT, for tests, sets the seconds to wait for the board to start, board_start_timeout by default.
#
# Where the board goes
#
# The pane of each Epic's board is recorded in the host-local state that oe-store.sh describes, with the Herdr server it is on.
# A later run uses the first row that fits, so one Epic never gets a second board while its pane is usable:
#
# | Recorded pane | Action | Output state |
# |---|---|---|
# | On this server and running this Epic's board | Leave it | reused |
# | On this server and at its shell's prompt, as after the board stopped | Start the board in it | restarted |
# | Running anything else, closed, on another server, or none | Open a new pane and start the board in it | opened |
#
# A recorded pane that runs anything else is never sent input, because the user may have taken it over.
#
# Output
#
# One line, separated by tabs: board, the state, and the pane, or board, off, and the reason the board is off.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | The board runs, or it is off | The line |
# | 1 | herdr failed, the board did not start, or the record could not be written | Nothing |
# | 2 | The arguments are invalid, or git config skills.herdr is not a boolean | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe board <owner/repo> <epic-number>" >&2
  exit 2
}

fail() {
  echo "oe board: $1" >&2
  exit 1
}

off() {
  printf 'board\toff\t%s\n' "$1"
  exit 0
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
repo="$1"
epic="$2"
start_timeout="${OE_BOARD_START_TIMEOUT:-${board_start_timeout}}"
[[ "${start_timeout}" =~ ^[0-9]+$ ]] || usage "OE_BOARD_START_TIMEOUT must be whole seconds"

# Outside Herdr nothing else is read, so a run there behaves as if this command did not exist.
[[ "${HERDR_ENV:-}" == 1 ]] || off "not inside Herdr"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

enabled="$(git config --type=bool --get skills.herdr 2>"${err}")"
case $? in
0) [[ "${enabled}" == true ]] || off "git config skills.herdr is not true" ;;
1) off "git config skills.herdr is not true" ;;
*)
  echo "oe board: git config skills.herdr must be true or false: $(head -n1 "${err}")" >&2
  exit 2
  ;;
esac

command -v herdr >/dev/null 2>&1 || fail "herdr is not on PATH"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "the current directory is in no clone"
roots="$(worktree_root)" || fail "the current directory is in no clone"
socket="${HERDR_SOCKET_PATH:-}"
record="$(state_dir)/boards/$(repo_key "${repo}")/${epic}"

# The shell in the pane runs this line; repo and epic passed the checks above, so only the paths need quoting.
# - The pane's shell starts from the user's environment, not this session's, so the line names the state directory,
#   which holds the lock the board stops on, and the worktree root, which the AGENT column reads, as this session resolves them.
# - env sets them, because a VAR=value prefix is not valid in every shell.
command_line="cd $(printf '%q' "${top}") && env OE_WAIT_INTERVAL=${board_interval}"
command_line+=" OE_STATE_DIR=$(printf '%q' "$(state_dir)") OE_WORKTREE_ROOT=$(printf '%q' "${roots}")"
command_line+=" bash $(printf '%q' "${dir}/oe") status ${repo} ${epic} --watch"

# Prints what pane $1 runs: board when this Epic's board, prompt when only its shell, and other otherwise.
# Prints gone when herdr does not know the pane, and fails with herdr's error otherwise.
pane_state() {
  local info
  if ! info="$(herdr pane process-info --pane "$1" 2>"${err}")"; then
    if [[ "$(jq -r '.error.code // empty' "${err}" 2>/dev/null)" == pane_not_found ]]; then
      printf gone
      return 0
    fi
    echo "herdr pane process-info failed: $(head -n1 "${err}")" >&2
    return 1
  fi
  # oe execs oe-status.sh, so the board's process shows that script with oe status's arguments.
  jq -r --arg script "${dir}/oe-status.sh" --arg repo "${repo}" --arg epic "${epic}" '
    .result.process_info as $p
    | if any($p.foreground_processes[]; .argv[1:5] == [$script, $repo, $epic, "--watch"]) then "board"
      elif $p.foreground_process_group_id == $p.shell_pid then "prompt"
      else "other" end' <<<"${info}" 2>/dev/null || {
    echo "herdr pane process-info for $1 unreadable" >&2
    return 1
  }
}

# Starts the board in pane $1 and waits until it runs.
start_board() {
  local state i
  herdr pane run "$1" "${command_line}" >/dev/null 2>"${err}" ||
    fail "herdr pane run in $1 failed: $(head -n1 "${err}")"
  for ((i = 0; ; i++)); do
    state="$(pane_state "$1")" || exit 1
    [[ "${state}" != board ]] || return 0
    ((i < start_timeout)) || fail "the board did not start in pane $1 within ${start_timeout}s"
    sleep 1
  done
}

if [[ -r "${record}" ]]; then
  recorded_pane="$(jq -r '.pane // empty' "${record}" 2>/dev/null)"
  recorded_socket="$(jq -r '.socket // empty' "${record}" 2>/dev/null)"
  # Pane IDs belong to one server, so a pane recorded on another one is never asked about.
  if [[ -n "${recorded_pane}" && "${recorded_socket}" == "${socket}" ]]; then
    state="$(pane_state "${recorded_pane}")" || exit 1
    case "${state}" in
    board)
      printf 'board\treused\t%s\n' "${recorded_pane}"
      exit 0
      ;;
    prompt)
      start_board "${recorded_pane}"
      printf 'board\trestarted\t%s\n' "${recorded_pane}"
      exit 0
      ;;
    *) ;;
    esac
  fi
fi

opened="$(herdr pane split --current --direction down --ratio 0.7 --cwd "${top}" --no-focus 2>"${err}")" ||
  fail "herdr pane split failed: $(head -n1 "${err}")"
pane="$(jq -r '.result.pane.pane_id // empty' <<<"${opened}" 2>/dev/null)"
[[ "${pane}" =~ ^[A-Za-z0-9:_-]+$ ]] || fail "herdr pane split gave no readable pane"
# The label only helps the user find the pane, so a failure to set it changes nothing else.
herdr pane rename "${pane}" "oe ${repo}#${epic}" >/dev/null 2>&1 || true

# The record is written before the board starts, so a rerun finds this pane even if the start fails.
if ! { mkdir -p "${record%/*}" 2>/dev/null &&
  jq -cn --arg pane "${pane}" --arg socket "${socket}" '{pane: $pane, socket: $socket}' >"${record}.tmp" 2>/dev/null &&
  mv -f "${record}.tmp" "${record}" 2>/dev/null; }; then
  fail "cannot write the board record ${record}"
fi
start_board "${pane}"
printf 'board\topened\t%s\n' "${pane}"
