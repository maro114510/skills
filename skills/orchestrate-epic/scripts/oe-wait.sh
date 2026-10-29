#!/usr/bin/env bash
# oe wait
#
# Blocks inside one call until oe ready's output changes, so waiting for CI or a human costs the session no tokens.
# It reads GitHub only through oe ready, and writes nothing.
#
# Usage
#
#   oe wait <owner/repo> <epic-number> [--running <issue-number>]... [--timeout <seconds>] [--idle-since <epoch>]
#
# - --running is passed to oe ready, and also means an agent is still running.
# - --timeout bounds this call, wait_timeout seconds by default.
# - --idle-since is when the caller last saw the output change, or when the session started, in epoch seconds.
#   With no --running, the session is idle once idle_limit seconds have passed since then.
# - OE_NOW sets the current time in epoch seconds, as in oe ready.
# - OE_WAIT_INTERVAL sets the seconds between two polls, wait_interval by default.
#
# The first oe ready run is the baseline, and every later run is compared with it.
#
# Output
#
# - The output of the latest oe ready run, in oe ready's format.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | The output changed | The new output |
# | 1 | A GitHub read failed | Nothing |
# | 2 | The arguments are invalid | Nothing |
# | 3 | oe ready ended the session: the default branch head has no checks after no_checks_grace | The end line |
# | 5 | The timeout passed with the output unchanged | The unchanged output |
# | 6 | The session is idle: no agent runs and idle_limit has passed since --idle-since | The unchanged output, as the session's summary |
#
# After exit 6 the session ends, and a rerun of orchestrate-epic resumes from GitHub, where every state lives.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe wait <owner/repo> <epic-number> [--running <issue-number>]... [--timeout <seconds>] [--idle-since <epoch>]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
repo="$1"
epic="$2"
shift 2
running=()
timeout="${wait_timeout}"
idle_since=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --running)
    [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage "Expected --running <issue-number>"
    running+=(--running "$2")
    ;;
  --timeout)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "Expected --timeout <seconds>"
    timeout="$2"
    ;;
  --idle-since)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "Expected --idle-since <epoch>"
    idle_since="$2"
    ;;
  *) usage "Unknown argument: $1" ;;
  esac
  shift 2
done

interval="${OE_WAIT_INTERVAL:-${wait_interval}}"
[[ "${interval}" =~ ^[0-9]+$ ]] || usage "OE_WAIT_INTERVAL must be whole seconds"
[[ -z "${OE_NOW:-}" || "${OE_NOW}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

now() {
  printf '%s' "${OE_NOW:-$(date -u +%s)}"
}

# Prints the latest oe ready output, which is empty for an Epic without child Issues.
emit() {
  [[ -z "${current}" ]] || printf '%s\n' "${current}"
}

# Runs oe ready into $current, and ends the wait when oe ready ended the session or failed.
# oe ready's own stderr names the failed read.
poll() {
  local rc
  current="$(bash "${dir}/oe-ready.sh" "${repo}" "${epic}" ${running[@]+"${running[@]}"})"
  rc=$?
  case "${rc}" in
  0) ;;
  3)
    emit
    exit 3
    ;;
  *) exit 1 ;;
  esac
}

# Ends the wait with the current output when the session is idle.
end_if_idle() {
  if [[ -n "${idle_since}" && ${#running[@]} -eq 0 ]] && (($(now) - idle_since >= idle_limit)); then
    emit
    exit 6
  fi
}

current=""
poll
baseline="${current}"
end_if_idle

deadline=$(($(date -u +%s) + timeout))
while (($(date -u +%s) < deadline)); do
  sleep "${interval}"
  poll
  if [[ "${current}" != "${baseline}" ]]; then
    emit
    exit 0
  fi
  end_if_idle
done
emit
exit 5
