#!/usr/bin/env bash
# oe wait
#
# Blocks inside one call until oe ready's next actions change, so waiting for CI or a human costs the session no tokens.
# It reads GitHub only through oe ready, and writes nothing.
#
# Usage
#
#   oe wait <owner/repo> <epic-number> [--running <issue-number>]... [--max-agents <n>] [--timeout <seconds>] [--idle-since <epoch>]
#
# - --running is accepted and ignored, so a caller written for it still runs: the agents running are oe ready's wait-agent lines,
#   so an agent that pushes, asks, or gives a verdict during a wait changes its Issue's line and returns that wait.
# - --max-agents is how many agents the session can run at once, 3 by default as in the skill.
#   The session passes its running count after a start failed, so the failed Issue does not end the wait at once.
# - --timeout bounds this call, wait_timeout seconds by default.
#   No pause runs past the deadline, and the deadline is checked after each poll, so the call can run up to one poll past it.
#   A poll whose reads never return ends within twice OE_READ_TIMEOUT, oe ready's read and the rate_limit read, which is one poll interval by default.
# - --idle-since is accepted and ignored, so a caller written for the idle limit still runs; the wait never ends the session for idling.
# - OE_NOW sets the current time in epoch seconds, as in oe ready.
# - OE_WAIT_INTERVAL sets the seconds between two polls, wait_interval by default.
# - OE_READ_TIMEOUT sets the seconds one GitHub read may take, as in oe ready.
#
# The polls of one call share a cache that oe ready keeps, so an open Issue is read again only when oe ready's header says it changed.
# The cache lives in a temporary directory that the call removes when it ends.
#
# A failed oe ready run ends nothing: the next run comes one poll interval later.
# The exception is a failure with the GraphQL rate limit exhausted, which another job on the same account can cause at any time:
# oe wait then shows the reset time on stderr and polls again at that time, or at the deadline when that comes first.
# It decides this from GitHub's rate_limit read, which costs no rate-limit points, and not from the failed read's message.
# The first oe ready run that succeeds is the baseline, and every later run is compared with it.
# A baseline that already holds an Issue to start ends the wait at once while fewer than --max-agents agents run,
# because no later run would show it as a change.
# A baseline that holds a hold ends it at once whatever the agents run, because the session must record the hold and show it to the person.
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
# | 1 | Every GitHub read failed until the timeout, including while a rate limit had not reset | Nothing |
# | 2 | The arguments are invalid | Nothing |
# | 5 | The timeout passed with every next action unchanged | The latest output |
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
[[ -z "${OE_READ_TIMEOUT:-}" || "${OE_READ_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || usage "OE_READ_TIMEOUT must be whole seconds above 0"

# Prints the latest oe ready output, which is empty for an Epic without child Issues.
emit() {
  [[ -z "${current}" ]] || printf '%s\n' "${current}"
}

# Prints $1 epoch seconds as a UTC time, with date -d on GNU and date -r on BSD.
utc_time() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

rate_reset=0
cache="$(mktemp -d)" || usage "mktemp failed"
trap 'rm -rf "${cache}"' EXIT

# Sets rate_reset to the epoch second at which the exhausted GraphQL bucket refills, and shows it, or to 0 when the bucket is not exhausted.
# A failed rate_limit read leaves it 0, so the failure is treated like any other.
check_rate_limit() {
  local reset
  rate_reset=0
  reset="$(gh_read api rate_limit --jq '.resources.graphql | select(.remaining == 0) | .reset' 2>/dev/null)" || return 0
  [[ "${reset}" =~ ^[0-9]+$ ]] || return 0
  rate_reset="${reset}"
  echo "oe wait: the GitHub GraphQL rate limit is exhausted; waiting until it resets at $(utc_time "${reset}")" >&2
}

# Sleeps one poll interval, or until the rate limit resets when that is later than now, and never past the deadline.
pause() {
  local now seconds="${interval}"
  now="$(date -u +%s)"
  ((rate_reset <= now)) || seconds=$((rate_reset - now))
  ((seconds <= deadline - now)) || seconds=$((deadline - now))
  ((seconds >= 0)) || seconds=0
  sleep "${seconds}"
}

# Runs oe ready into $current, and fails leaving $current as it was when oe ready failed.
# oe ready's own stderr names the failed read.
poll() {
  local out rc
  out="$(OE_READY_CACHE="${cache}" bash "${dir}/oe-ready.sh" "${repo}" "${epic}")" && rc=0 || rc=$?
  rate_reset=0
  if ((rc == 1)); then
    check_rate_limit
    return 1
  elif ((rc != 0)); then
    return 1
  fi
  current="${out}"
  return 0
}

# Prints the Issue number and action of every line of $1, the part of oe ready's output a change is judged on.
actions() {
  cut -f1,2 <<<"$1"
}

# Succeeds when a line of $current has an action that starts an agent and fewer than max_agents agents run, so the session can start it now.
# The action decides, not a non-empty fourth field, because a wait-answer line carries an answer command there and starts nothing.
# A hold line is always actionable, because oe hold starts no agent and the cap counts agents.
# The agents running are the wait-agent lines, whose working marker is live.
startable() {
  local agents
  agents="$(cut -f2 <<<"${current}" | grep -cx wait-agent)"
  cut -f2 <<<"${current}" | grep -qx hold ||
    { ((agents < max_agents)) && cut -f2 <<<"${current}" | grep -qxE 'start-owner|start-verifier'; }
}

current=""
deadline=$(($(date -u +%s) + timeout))
until poll; do
  (($(date -u +%s) < deadline)) || exit 1
  pause
done
baseline="$(actions "${current}")"
if startable; then
  emit
  exit 0
fi

while (($(date -u +%s) < deadline)); do
  pause
  poll || continue
  if [[ "$(actions "${current}")" != "${baseline}" ]]; then
    emit
    exit 0
  fi
done
emit
exit 5
