#!/usr/bin/env bash
# oe status
#
# Shows the progress of every child Issue of an Epic, for an engineer at a terminal, while a session runs and after it ends.
# It reads GitHub only through oe ready, and this host's lock and records, and writes nothing anywhere.
#
# Usage
#
#   oe status <owner/repo> <epic-number> [--watch]
#
# - Run it from the clone the session runs in, so the AGENT column can find the agents' worktrees.
# - --watch redraws the view every wait_interval seconds until interrupted.
#   A failed read is reported on stderr and retried at the next refresh.
#   Once a refresh has found a running session holding the Epic's lock, the first refresh that finds none draws the last view and exits 0,
#   so a board left open after its session ended, crashed or not, stops reading GitHub.
# - OE_NOW sets the current time in epoch seconds, and OE_WAIT_INTERVAL the seconds between refreshes, as in oe wait.
# - OE_STATUS_REFRESHES, for tests, ends --watch after that many refreshes.
#
# Output
#
# A table with one row per child Issue, sorted by Issue number. A column without a value shows -.
#
# | Column | Holds |
# |---|---|
# | ISSUE | The Issue number |
# | STEP | The next action oe ready gives the Issue, which names the step it is in |
# | PR | The pull request opened from its branch after the latest claim |
# | CI | The CI state of that pull request's open head |
# | VERDICT | The oe/verify state on that head |
# | ATTEMPTS | Owner attempts since the latest claim, out of max_attempts |
# | AGENT | owner or verifier while a running session holds the Epic's lock and that agent's worktree exists |
# | SINCE | Time since the Issue entered its step, as facts in oe-ready.jq defines it |
# | REASON | oe ready's reason for the step |
#
# - Under the table, each Issue whose head has a failure verdict shows that verdict's findings, one line each.
# - When oe ready ends the session for a default branch head without checks, the view is its end line alone.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | The view was shown | The view |
# | 1 | A GitHub read or the record store read failed, without --watch | Nothing |
# | 2 | The arguments are invalid | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe status <owner/repo> <epic-number> [--watch]" >&2
  exit 2
}

[[ $# -eq 2 || $# -eq 3 ]] || usage "Expected <owner/repo> <epic-number> [--watch]"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
[[ $# -eq 2 || "$3" == --watch ]] || usage "Unknown argument: $3"
repo="$1"
epic="$2"
watch=$(($# == 3))
interval="${OE_WAIT_INTERVAL:-${wait_interval}}"
[[ "${interval}" =~ ^[0-9]+$ ]] || usage "OE_WAIT_INTERVAL must be whole seconds"
refreshes="${OE_STATUS_REFRESHES:-}"
[[ -z "${refreshes}" || "${refreshes}" =~ ^[1-9][0-9]*$ ]] || usage "OE_STATUS_REFRESHES must be a positive integer"
[[ -z "${OE_NOW:-}" || "${OE_NOW}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

# Prints the seconds in $1 as minutes under an hour, and hours and minutes above, such as 45s, 30m, or 26h5m.
duration() {
  local s="$1"
  ((s >= 0)) || s=0
  if ((s < 60)); then
    printf '%ss' "${s}"
  elif ((s < 3600)); then
    printf '%sm' "$((s / 60))"
  else
    printf '%sh%sm' "$((s / 3600))" "$((s % 3600 / 60))"
  fi
}

# Prints the agent running for Issue $1: owner, verifier, or -.
# oe worktree checks out the Issue branch for an Owner, and detaches at its head for a Verifier.
agent_of() {
  local wt="${root}/issue-$1"
  if [[ "${held}" != yes || -z "${root}" ]] ||
    [[ "$(git -C "${wt}" rev-parse --show-toplevel 2>/dev/null)" != "${wt}" ]]; then
    printf -- '-'
  elif git -C "${wt}" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    printf owner
  else
    printf verifier
  fi
}

# Prints the whole view once, or fails with the reason on stderr and prints nothing.
render() {
  local facts rc now line n head started since rows="" findings="" found
  facts="$(bash "${dir}/oe-ready.sh" "${repo}" "${epic}" --facts)"
  rc=$?
  if ((rc == 3)); then
    printf 'end: %s\n' "${facts#end$'\t'}"
    return 0
  fi
  ((rc == 0)) || return 1
  now="${OE_NOW:-$(date -u +%s)}"
  held=no
  ! lock_held "${repo}" "${epic}" || held=yes
  root="$(worktree_root)" && root="$(cd "${root}" 2>/dev/null && pwd -P)" || root=""

  while read -r line; do
    [[ -n "${line}" ]] || continue
    n="$(jq -r .number <<<"${line}")" || return 1
    started="$(jq -r '.started // empty' <<<"${line}")" || return 1
    since=-
    [[ -z "${started}" ]] || since="$(duration "$((now - started))")"
    rows+="$(jq -r --arg agent "$(agent_of "${n}")" --arg since "${since}" --argjson max "${max_attempts}" \
      '["#\(.number)", .action, (if .pr then "#\(.pr)" else "-" end), (.ci // "-"),
        (if .verdict == null or .verdict == "none" then "-" else .verdict end),
        (if .attempts == null then "-" else "\(.attempts)/\($max)" end), $agent, $since, .reason] | join("\t")' \
      <<<"${line}")"$'\n' || return 1
    if [[ "$(jq -r '.verdict == "failure"' <<<"${line}")" == true ]]; then
      head="$(jq -r .head <<<"${line}")"
      found="$(records_read "${repo}" "${n}" | jq -r --arg sha "${head}" \
        '[.[] | select(.kind == "verdict" and .sha == $sha and .state == "failure")] | last | .findings // empty')" ||
        return 1
      [[ -z "${found}" ]] || findings+=$'\n'"#${n} failure verdict on ${head:0:7}:"$'\n'"  ${found//$'\n'/$'\n'  }"$'\n'
    fi
  done <<<"${facts}"

  # Every column but the last is padded to its widest value, so a reason with spaces stays one column.
  printf 'ISSUE\tSTEP\tPR\tCI\tVERDICT\tATTEMPTS\tAGENT\tSINCE\tREASON\n%s' "${rows}" | awk -F '\t' '
    { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (i < NF && length($i) > width[i]) width[i] = length($i) } n[NR] = NF }
    END {
      for (r = 1; r <= NR; r++) {
        out = ""
        for (i = 1; i < n[r]; i++) out = out sprintf("%-" width[i] "s  ", cell[r, i])
        print out cell[r, n[r]]
      }
    }'
  printf '%s' "${findings}"
}

if ((! watch)); then
  view="$(render)" || exit 1
  printf '%s\n' "${view}"
  exit 0
fi

count=0
seen=0
while :; do
  # The lock is read before the view, so the last view is drawn after the session ended.
  ended=0
  if lock_held "${repo}" "${epic}"; then
    seen=1
  elif ((seen)); then
    ended=1
  fi
  if view="$(render)"; then
    [[ ! -t 1 ]] || printf '\033[H\033[2J'
    printf '%s\n' "${view}"
  else
    echo "oe status: the read failed at $(date -u +%FT%TZ); retrying at the next refresh" >&2
  fi
  ((! ended)) || exit 0
  count=$((count + 1))
  [[ -z "${refreshes}" || "${count}" -lt "${refreshes}" ]] || exit 0
  sleep "${interval}"
done
