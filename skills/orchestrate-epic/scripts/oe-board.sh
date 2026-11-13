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
# - The board refreshes every board_interval seconds. While the session holds the Epic's lock it draws the facts that session's latest read saved, and reads no GitHub.
#   It draws once more, from GitHub, and stops by itself once that session ends.
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
# | On this server, at its shell's prompt, with a start sent less than 10 minutes ago that the shell never confirmed | Send nothing, and wait for that start | restarted |
# | Running anything else, closed, on another server, or none | Open a new pane and start the board in it | opened |
#
# A recorded pane that runs anything else is never sent input, because the user may have taken it over.
#
# A slow start
#
# The command is typed into the pane at once, and the shell runs it when its startup finishes, after anything its startup files print, such as direnv's "is taking a while" warning.
# oe board waits board_start_timeout seconds for the board to run.
# A pane that still sits in its shell then exits 1 and says the shell has not finished starting, and the record keeps when the command was sent.
# A rerun in the next 10 minutes sends nothing again, so the command is never queued twice, and waits for the queued start.
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
# Seconds a start that was sent and never seen running counts as queued behind a slow shell.
queued_for=600
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

# The shell in the pane runs this line; repo and epic passed the checks above, so only the values need quoting.
# The pane's shell starts from the user's environment, not this session's, so the line carries what the board must share with the session:
# - TZ and the locale as this session has them, set or unset, because a lock taken before oe lock fixed both holds its start time in the taker's.
# - The state directory, which holds the lock the board stops on, and the worktree root, which the AGENT column reads.
# env sets them, because a VAR=value prefix is not valid in every shell.
unset_vars=""
set_vars=""
for var in TZ LC_ALL LC_TIME LANG; do
  if [[ -n "${!var+set}" ]]; then
    set_vars+=" ${var}=$(printf '%q' "${!var}")"
  else
    unset_vars+=" -u ${var}"
  fi
done
command_line="cd $(printf '%q' "${top}") && env${unset_vars}${set_vars} OE_WAIT_INTERVAL=${board_interval}"
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

# Writes the record of pane $1, with the epoch second $2 when the command was sent to the pane and its start is unconfirmed.
write_record() {
  mkdir -p "${record%/*}" 2>/dev/null &&
    jq -cn --arg pane "$1" --arg socket "${socket}" --arg sent "${2:-}" \
      '{pane: $pane, socket: $socket} + (if $sent == "" then {} else {sent: ($sent | tonumber)} end)' >"${record}.tmp" 2>/dev/null &&
    mv -f "${record}.tmp" "${record}" 2>/dev/null
}

# Starts the board in pane $1 and waits until it runs.
# $2 is the epoch second of a start already sent to the pane, in which case nothing is sent again.
# The shell runs the typed command only after its startup files finish, and a slow one, such as a .envrc that fetches secrets, can pass the timeout.
start_board() {
  local state i sent="${2:-}"
  if [[ -z "${sent}" ]]; then
    sent="$(date +%s)"
    herdr pane run "$1" "${command_line}" >/dev/null 2>"${err}" ||
      fail "herdr pane run in $1 failed: $(head -n1 "${err}")"
  fi
  for ((i = 0; ; i++)); do
    state="$(pane_state "$1")" || exit 1
    if [[ "${state}" == board ]]; then
      write_record "$1" || fail "cannot write the board record ${record}"
      return 0
    fi
    if ((i >= start_timeout)); then
      if [[ "${state}" == prompt ]]; then
        write_record "$1" "${sent}" || true
        fail "the board did not start in pane $1 within ${start_timeout}s: the pane's shell has not finished starting, as with a slow startup file or .envrc, and the board starts when it does; run oe board again to wait for it"
      fi
      fail "the board did not start in pane $1 within ${start_timeout}s"
    fi
    sleep 1
  done
}

if [[ -r "${record}" ]]; then
  recorded_pane="$(jq -r '.pane // empty' "${record}" 2>/dev/null)"
  recorded_socket="$(jq -r '.socket // empty' "${record}" 2>/dev/null)"
  recorded_sent="$(jq -r '.sent // empty' "${record}" 2>/dev/null)"
  # Pane IDs belong to one server, so a pane recorded on another one is never asked about.
  if [[ -n "${recorded_pane}" && "${recorded_socket}" == "${socket}" ]]; then
    state="$(pane_state "${recorded_pane}")" || exit 1
    case "${state}" in
    board)
      printf 'board\treused\t%s\n' "${recorded_pane}"
      exit 0
      ;;
    prompt)
      # A command sent lately and never seen running is still queued behind the shell's startup.
      [[ "${recorded_sent}" =~ ^[0-9]+$ ]] && (($(date +%s) - recorded_sent < queued_for)) || recorded_sent=""
      start_board "${recorded_pane}" "${recorded_sent}"
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
if ! write_record "${pane}"; then
  fail "cannot write the board record ${record}"
fi
start_board "${pane}"
printf 'board\topened\t%s\n' "${pane}"
