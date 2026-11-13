#!/usr/bin/env bash
# oe status
#
# Shows the progress of every child Issue of an Epic, for an engineer at a terminal, while a session runs and after it ends.
# While a running session holds the Epic's lock, it draws the facts that session's latest oe ready saved on this host and reads no GitHub.
# With no session holding the lock, it reads GitHub itself, only through oe ready. It writes nothing anywhere.
#
# Usage
#
#   oe status <owner/repo> <epic-number> [--watch]
#
# - Run it from the clone the session runs in, so the AGENT column can find the agents' worktrees.
# - --watch redraws the view every wait_interval seconds.
#   At a terminal it first clears the screen, so nothing the pane's shell printed while it started stays, and shows one line while the first read runs.
#   The refresh that finds no running session holding the Epic's lock draws the view once and exits 0,
#   so a board left open after its session ended, crashed or not, and a board started with no session, stop reading GitHub.
#   A failed read is retried at the next refresh, and stays on the view until a read succeeds.
# - OE_NOW sets the current time in epoch seconds, and OE_WAIT_INTERVAL the seconds between refreshes, as in oe wait.
# - OE_STATUS_REFRESHES, for tests, ends --watch after that many refreshes.
#
# Output
#
# The first line counts the child Issues by their step, after a running agent replaces the step as the STEP column says.
#
# | Count | Steps |
# |---|---|
# | done | done |
# | waiting on you | wait-answer, parked, wait-engineer, wait-update, wait-merge |
# | waiting | wait-dependencies, wait-base |
# | in progress | Any other, running included |
#
# Under it, each Issue waiting on the owner shows three lines, sorted by Issue number, or one line says nothing waits:
#
# - `- #<n>` and what the owner does next
# - The URL to do it at: the Issue for a question, else the pull request, or the Issue without one
# - `why:` and oe ready's reason
#
# Then a table with one row per child Issue, sorted by Issue number. A column without a value shows -.
#
# | Column | Holds |
# |---|---|
# | ISSUE | The Issue number |
# | STEP | running while an agent runs, so that agent's own attempt shows instead of the next one; else the next action oe ready gives the Issue, which names the step it is in |
# | PR | The pull request opened from its branch after the latest claim |
# | CI | The CI state of that pull request's open head |
# | VERDICT | The oe/verify state on that head |
# | ATTEMPTS | Owner attempts since the latest claim, out of max_attempts |
# | AGENT | owner or verifier while a running session holds the Epic's lock and that agent's worktree exists |
# | SINCE | Time since the Issue entered its step, as facts in oe-ready.jq defines it |
# | REASON | For a running agent, its attempt or start out of the cap; else oe ready's reason for the step |
#
# - Under the table, each Issue whose head has a failure verdict shows that verdict's findings, one line each.
# - Under that, one line says when the facts were read, marked stale when older than facts_stale seconds:
#   `Facts read <time> ago by the session` while a session holds the lock, or `Read from GitHub just now` without one.
# - Under that, a failed read of the session adds `Read failed <time> ago: <reason>`, which stays until a later read succeeds.
#   In --watch, a failed read of oe status itself, with no session, adds a line of its own under the last view.
# - A session that has saved no facts since it took the lock shows no Issues, and the view says it has read nothing yet.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | The view was shown | The view |
# | 1 | A GitHub read or the record store read failed with no session holding the lock, without --watch | Nothing |
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

# Sets facts to the facts of every child Issue, one JSON object per line, and read_at, read_by, and read_failure.
# A session that holds the lock gives the facts it saved since it took the lock, and no GitHub read runs.
# Fails with the reason on stderr when the facts cannot be had.
read_facts() {
  local record taken
  facts=""
  read_failure=""
  if [[ "${held}" == yes ]]; then
    read_by=session
    taken="$(lock_started "${repo}" "${epic}" | jq -R 'try fromdateiso8601 catch 0')" || taken=0
    record="$(facts_read "${repo}" "${epic}")" || record=""
    if [[ -z "${record}" ]] || ! jq -e --argjson taken "${taken:-0}" '.wrote >= $taken' >/dev/null 2>&1 <<<"${record}"; then
      read_at=""
      return 0
    fi
    read_at="$(jq -r '.at // empty' <<<"${record}")"
    read_failure="$(jq -r '.failure // empty | "\(.at)\t\(.reason)"' <<<"${record}")"
    facts="$(jq -c '.lines[]' <<<"${record}")" || return 1
  else
    read_by=github
    facts="$(bash "${dir}/oe-ready.sh" "${repo}" "${epic}" --facts)" || return 1
    read_at="${now}"
  fi
}

# Prints the whole view once, or fails with the reason on stderr and prints nothing.
render() {
  local line n head started since rows="" findings="" found action agent needs="" age note=""
  local done_n=0 progress_n=0 waiting_n=0 owner_n=0
  now="${OE_NOW:-$(date -u +%s)}"
  read_facts || return 1
  root="$(worktree_root)" && root="$(cd "${root}" 2>/dev/null && pwd -P)" || root=""

  while read -r line; do
    [[ -n "${line}" ]] || continue
    n="$(jq -r .number <<<"${line}")" || return 1
    agent="$(agent_of "${n}")"
    # A running agent's own attempt already counts, so oe ready's next action would describe the attempt after it.
    if [[ "${agent}" != - && "$(jq -r .action <<<"${line}")" != "done" ]]; then
      line="$(jq -c --arg agent "${agent}" --argjson max "${max_attempts}" --argjson vmax "${max_verifier_starts}" '
        .action = "running"
        | .reason = (if $agent == "owner" then "Owner attempt \(.attempts // 0) of \($max)"
            else "Verifier start \(.starts // 0) of \($vmax) on \((.head // "")[0:7])" end)' <<<"${line}")" || return 1
    fi
    action="$(jq -r .action <<<"${line}")" || return 1
    case "${action}" in
    done) done_n=$((done_n + 1)) ;;
    wait-answer | parked | wait-engineer | wait-update | wait-merge)
      owner_n=$((owner_n + 1))
      needs+="$(jq -r --arg repo "${repo}" '
        {"wait-answer": "Answer the Owner'\''s question in the session'\''s conversation or with a comment on the Issue",
          "parked": "Fix it by hand, or delete its branch so the AI starts over",
          "wait-engineer": "Close the Issue, reopen the PR, or delete its branch so the AI starts over",
          "wait-update": "Update the PR'\''s branch with its base branch",
          "wait-merge": "Review the PR, run its manual checks, and merge it"}[.action] as $todo
        | (if .action != "wait-answer" and .pr then "pull/\(.pr)" else "issues/\(.number)" end) as $path
        | "- #\(.number) \($todo)\n  https://github.com/\($repo)/\($path)\n  why: \(.reason)"' \
        <<<"${line}")"$'\n' || return 1
      ;;
    wait-dependencies | wait-base) waiting_n=$((waiting_n + 1)) ;;
    *) progress_n=$((progress_n + 1)) ;;
    esac
    started="$(jq -r '.started // empty' <<<"${line}")" || return 1
    since=-
    [[ -z "${started}" ]] || since="$(duration "$((now - started))")"
    rows+="$(jq -r --arg agent "${agent}" --arg since "${since}" --argjson max "${max_attempts}" \
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

  printf 'Epic #%s: %s done, %s in progress, %s waiting, %s waiting on you\n' \
    "${epic}" "${done_n}" "${progress_n}" "${waiting_n}" "${owner_n}"
  if ((owner_n > 0)); then
    printf '%s\n' "${needs}"
  else
    printf 'Nothing waits on you.\n\n'
  fi

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
  if [[ -z "${read_at}" ]]; then
    printf '\nThe session has saved no read of GitHub yet.\n'
  else
    age=$((now - read_at))
    if [[ "${read_by}" == github ]]; then
      note="Read from GitHub just now"
    else
      note="Facts read $(duration "${age}") ago by the session"
      ((age <= facts_stale)) || note+=" (stale: older than $(duration "${facts_stale}"))"
    fi
    printf '\n%s.\n' "${note}"
  fi
  if [[ -n "${read_failure}" ]]; then
    IFS=$'\t' read -r n found <<<"${read_failure}"
    printf 'Read failed %s ago: %s\n' "$(duration "$((now - n))")" "${found}"
  fi
}

# The lock is read before each view, because a session that holds it gives the facts it saved and a read of GitHub is skipped.
held=no
! lock_held "${repo}" "${epic}" || held=yes

if ((! watch)); then
  view="$(render)" || exit 1
  printf '%s\n' "${view}"
  exit 0
fi

# The first read takes seconds, and the screen shows only what the pane's shell printed until then.
[[ ! -t 1 ]] || printf '\033[H\033[2J%s\n' "oe status: reading Epic #${epic} of ${repo} ..."

count=0
view=""
while :; do
  if view_new="$(render)"; then
    view="${view_new}"
    [[ ! -t 1 ]] || printf '\033[H\033[2J'
    printf '%s\n' "${view}"
    # Only a drawn view ends the watch, so a failed read with no session is retried like any other.
    [[ "${held}" == yes ]] || exit 0
  else
    # The failure stays under the last view until a later read succeeds.
    reason="oe status: the read failed at $(date -u +%FT%TZ); retrying at the next refresh"
    echo "${reason}" >&2
    [[ ! -t 1 ]] || printf '\033[H\033[2J'
    printf '%s\n' "${view:+${view}$'\n'}${reason}"
  fi
  count=$((count + 1))
  [[ -z "${refreshes}" || "${count}" -lt "${refreshes}" ]] || exit 0
  sleep "${interval}"
  held=no
  ! lock_held "${repo}" "${epic}" || held=yes
done
