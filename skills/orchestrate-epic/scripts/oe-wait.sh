#!/usr/bin/env bash
# oe wait
#
# Blocks inside one call until oe ready's next actions change, so waiting for CI or a human costs the session no tokens.
# It reads GitHub only through oe ready --save, which also saves the facts of each read for oe status, and writes only its own process record,
# waits/<repo-key>/<epic> in the state oe-store.sh lays out, the facts record, facts/<repo-key>/<epic>,
# and with a notification command set, the notices record, notices/<repo-key>/<epic>.
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
# Notifications
#
# With git config skills.notify set, every oe ready run that shows an item needing the person runs that command through sh -c,
# with a one-line message as $1 and a link as $2, its output discarded, so the person learns of it without watching the session.
# With it unset or empty, oe wait notifies nobody and writes no notices record.
#
# | Item | When | Link |
# |---|---|---|
# | A question | An Issue's action is wait-answer | The Issue |
# | A park | An Issue's action is parked | The Issue |
# | An Issue waiting for a person | An Issue's action is wait-engineer | The Issue |
# | An Issue waiting for a merge | An Issue's action is wait-merge | The Issue |
# | Failed reads | notify_failed_reads oe ready runs in a row failed to read GitHub | The Epic |
# | The session's end | Every Issue is done, or oe ready failed with an error other than a failed read, which ends the session | The Epic |
#
# - Each item is notified when it first appears, and again every notify_repeat seconds while it remains.
# - The notices record keeps when each item was last notified, across oe wait calls, and drops an item once a successful read no longer shows it,
#   so an item that comes back is notified again at once.
# - The command runs before the next poll; a command that fails is reported on stderr and changes no exit code.
# - Herdr is one example setting: git config skills.notify 'herdr notification show "$1" --body "$2"'.
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

notify_command="$(git config --get skills.notify 2>/dev/null)" || notify_command=""
notice_file=""
if [[ -n "${notify_command}" ]]; then
  notice_file="$(notice_record "${repo}" "${epic}")" || notice_file=""
fi
epic_link="https://github.com/${repo}/issues/${epic}"
failed_reads=0

# Notifies the person of each item on stdin that is new or was last notified notify_repeat seconds ago or more.
# Each stdin line is an item's key, message, and link, separated by tabs.
# With $1 prune, the notices record keeps only these items; with $1 keep, it also keeps the items it held.
# The record is written before any call, so a record that cannot be written sends no notice instead of one at every poll.
notify() {
  local mode="$1" now old new="" due="" keys="" key message link last line
  [[ -n "${notice_file}" ]] || return 0
  now="${OE_NOW:-$(date -u +%s)}"
  old="$(cat "${notice_file}" 2>/dev/null)"
  while IFS=$'\t' read -r key message link; do
    [[ -n "${key}" ]] || continue
    keys+="${key}"$'\n'
    last="$(awk -F'\t' -v k="${key}" '$1 == k { print $2; exit }' <<<"${old}")"
    if [[ "${last}" =~ ^[0-9]+$ ]] && ((now - last < notify_repeat)); then
      new+="${key}"$'\t'"${last}"$'\n'
    else
      new+="${key}"$'\t'"${now}"$'\n'
      due+="${message}"$'\t'"${link}"$'\n'
    fi
  done
  if [[ "${mode}" == keep ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      grep -qxF "${line%%$'\t'*}" <<<"${keys}" || new+="${line}"$'\n'
    done <<<"${old}"
  fi
  if ! { mkdir -p "${notice_file%/*}" && printf '%s' "${new}" >"${notice_file}.$$" && mv -f "${notice_file}.$$" "${notice_file}"; } 2>/dev/null; then
    rm -f "${notice_file}.$$"
    echo "oe wait: cannot write ${notice_file}; no notification sent" >&2
    return 0
  fi
  while IFS=$'\t' read -r message link; do
    [[ -n "${message}" ]] || continue
    sh -c "${notify_command}" oe-notify "${message}" "${link}" </dev/null >/dev/null 2>&1 ||
      echo "oe wait: the notification command in git config skills.notify failed" >&2
  done <<<"${due}"
}

# Prints, for notify, each item of $current that needs the person.
waiting_items() {
  local n action reason _ message
  while IFS=$'\t' read -r n action reason _; do
    case "${action}" in
    wait-answer) message="Issue #${n} in ${repo} has a question for you" ;;
    parked) message="Issue #${n} in ${repo} is parked: ${reason}" ;;
    wait-engineer) message="Issue #${n} in ${repo} waits for you: ${reason}" ;;
    wait-merge) message="Issue #${n} in ${repo} waits for your merge: ${reason}" ;;
    *) continue ;;
    esac
    printf '%s/%s\t%s\t%s\n' "${n}" "${action}" "${message}" "https://github.com/${repo}/issues/${n}"
  done <<<"${current}"
  if [[ -n "${current}" ]] && ! cut -f2 <<<"${current}" | grep -qvx "done"; then
    printf 'end\tEpic #%s in %s is done; the session ends\t%s\n' "${epic}" "${repo}" "${epic_link}"
  fi
}

# Runs oe ready into $current, and fails leaving $current as it was when oe ready failed.
# oe ready's own stderr names the failed read.
poll() {
  local out rc
  out="$(bash "${dir}/oe-ready.sh" "${repo}" "${epic}" --save)" && rc=0 || rc=$?
  if ((rc == 1)); then
    failed_reads=$((failed_reads + 1))
    ((failed_reads < notify_failed_reads)) || [[ -z "${notice_file}" ]] ||
      printf 'reads\toe cannot read GitHub for Epic #%s in %s: %s reads in a row failed\t%s\n' \
        "${epic}" "${repo}" "${failed_reads}" "${epic_link}" | notify keep
    return 1
  elif ((rc != 0)); then
    [[ -z "${notice_file}" ]] ||
      printf 'end\toe ready failed for Epic #%s in %s with exit %s; the session ends\t%s\n' \
        "${epic}" "${repo}" "${rc}" "${epic_link}" | notify keep
    return 1
  fi
  current="${out}"
  failed_reads=0
  if [[ -n "${notice_file}" ]]; then
    waiting_items | notify prune
  fi
  return 0
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
