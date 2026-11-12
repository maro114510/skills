#!/usr/bin/env bash
# oe wait
#
# Blocks inside one call until oe ready's next actions change, so waiting for CI or a human costs the session no tokens.
# It reads GitHub only through oe ready, and writes only its own process record, waits/<repo-key>/<epic> in the state oe-store.sh lays out.
#
# Usage
#
#   oe wait <owner/repo> <epic-number> [--running <issue-number>]... [--max-agents <n>] [--timeout <seconds>] [--idle-since <epoch>]
#
# - --running is accepted and ignored, so a caller written for it still runs: the agents running are oe ready's running lines,
#   so an agent that ends during a wait changes its Issue's line and returns that wait.
# - --max-agents is how many agents the session can run at once, 3 by default as in the skill.
#   The session passes its running count after a start failed, so the failed Issue does not end the wait at once.
# - --timeout bounds this call, wait_timeout seconds by default.
#   The deadline is checked before each poll, so the call can run up to one poll interval past it.
# - A wait never stops another. While an earlier oe wait for the same Epic runs on this host, a new one runs oe ready once,
#   prints its output, and exits 6, because the earlier wait still returns once the next actions change.
# - --idle-since is accepted and ignored, so a caller written for the idle limit still runs; the wait never ends the session for idling.
# - OE_NOW sets the current time in epoch seconds, as in oe ready.
# - OE_WAIT_INTERVAL sets the seconds between two polls, wait_interval by default.
#
# A failed oe ready run ends nothing: the next run comes one poll interval later.
# The first oe ready run that succeeds is the baseline, and every later run is compared with it.
# A baseline that already holds an Issue to start ends the wait at once while fewer than --max-agents agents run,
# because no later run would show it as a change.
# Only each line's Issue number and action are compared, because a reason carries the seconds since a push,
# which differ on every run while nothing the session can act on has changed.
#
# Output
#
# - The output of the latest oe ready run, in oe ready's format.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | An Issue's next action changed, an Issue appeared or left, or the baseline holds an Issue to start | The new output |
# | 1 | Every GitHub read failed until the timeout | Nothing |
# | 2 | The arguments are invalid | Nothing |
# | 5 | The timeout passed with every next action unchanged | The latest output |
# | 6 | Another oe wait for the same Epic runs on this host | oe ready's output, or nothing when that read failed |
# | 137 | oe lock release killed this one | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe wait <owner/repo> <epic-number> [--running <issue-number>]... [--max-agents <n>] [--timeout <seconds>] [--idle-since <epoch>]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
repo="$1"
epic="$2"
shift 2
max_agents=3
timeout="${wait_timeout}"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --running)
    [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage "Expected --running <issue-number>"
    ;;
  --timeout)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "Expected --timeout <seconds>"
    timeout="$2"
    ;;
  --max-agents)
    [[ "${2:-}" =~ ^(0|[1-9][0-9]*)$ ]] || usage "Expected --max-agents <n>"
    max_agents="$2"
    ;;
  --idle-since)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "Expected --idle-since <epoch>"
    ;;
  *) usage "Unknown argument: $1" ;;
  esac
  shift 2
done

interval="${OE_WAIT_INTERVAL:-${wait_interval}}"
[[ "${interval}" =~ ^[0-9]+$ ]] || usage "OE_WAIT_INTERVAL must be whole seconds"
[[ -z "${OE_NOW:-}" || "${OE_NOW}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

# Records this wait for this Epic on this host, or fails when an earlier one still runs.
wait_file=""
single_wait() {
  wait_file="$(wait_record "${repo}" "${epic}")" || return 0
  if [[ -n "$(recorded_wait "${repo}" "${epic}" "$$")" ]]; then
    wait_file=""
    return 1
  fi
  mkdir -p "${wait_file%/*}" 2>/dev/null &&
    printf '%s %s\n' "$$" "$(process_start "$$")" >"${wait_file}" 2>/dev/null || true
}

# Drops this wait's record when it ends on its own, unless another wait recorded itself since.
# shellcheck disable=SC2329 # invoked by the EXIT trap below
drop_wait_record() {
  local pid _
  [[ -n "${wait_file}" ]] && read -r pid _ 2>/dev/null <"${wait_file}" && [[ "${pid}" == "$$" ]] && rm -f "${wait_file}"
  return 0
}
trap drop_wait_record EXIT
trap 'trap - EXIT; exit 143' TERM

# Prints the latest oe ready output, which is empty for an Epic without child Issues.
emit() {
  [[ -z "${current}" ]] || printf '%s\n' "${current}"
}

# Runs oe ready into $current, and fails leaving $current as it was when oe ready failed.
# oe ready's own stderr names the failed read.
poll() {
  local out
  out="$(bash "${dir}/oe-ready.sh" "${repo}" "${epic}")" || return 1
  current="${out}"
}

# Prints the Issue number and action of every line of $1, the part of oe ready's output a change is judged on.
actions() {
  cut -f1,2 <<<"$1"
}

# Succeeds when a line of $current has an action that starts an agent and fewer than max_agents agents run, so the session can start it now.
# The action decides, not a non-empty fourth field, because a wait-answer line carries an answer command there and starts nothing.
startable() {
  local agents
  agents="$(cut -f2 <<<"${current}" | grep -cx running)"
  ((agents < max_agents)) && cut -f2 <<<"${current}" | grep -qxE 'claim|start-owner|start-verifier'
}

current=""
if ! single_wait; then
  echo "oe wait: another oe wait runs for ${repo}#${epic}, and returns once the next actions change" >&2
  poll || true
  emit
  exit 6
fi
deadline=$(($(date -u +%s) + timeout))
until poll; do
  (($(date -u +%s) < deadline)) || exit 1
  sleep "${interval}"
done
baseline="$(actions "${current}")"
if startable; then
  emit
  exit 0
fi

while (($(date -u +%s) < deadline)); do
  sleep "${interval}"
  poll || continue
  if [[ "$(actions "${current}")" != "${baseline}" ]]; then
    emit
    exit 0
  fi
done
emit
exit 5
