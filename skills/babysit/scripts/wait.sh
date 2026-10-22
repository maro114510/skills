#!/usr/bin/env bash
# Blocks until a pull request has a new, unhandled actionable item, then prints it as one JSON line.
# Polls pr-state.sh every 60 seconds, compares each snapshot with the ledger, and prints
# {"event":"idle"} once --max minutes pass with nothing to act on. It never marks an item handled;
# the skill records each disposition with ledger.sh before calling wait again.
# Usage: wait.sh <owner/repo> <pr> --max <minutes> --session <token> [--mode watch|drive] [--snapshot <file>]
#   --snapshot reads a normalized pr-state snapshot from <file> on every poll instead of querying GitHub.
# --max is shortened so the call returns at the 8-hour session mark, where the limit event fires.
# The skill must hold the lock through `ledger.sh start` first.
# Exit: 0 one event printed, 1 the API failed 5 times in a row, 2 usage error, 3 the lock is not ours.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/babysit/scripts/common.sh
source "${script_dir}/common.sh"

POLL_SECONDS="${BABYSIT_POLL_SECONDS:-60}"
SESSION_SECONDS=28800
BACKOFF_FIRST=30
BACKOFF_MAX=480
MAX_FAILURES=5
PR_STATE="${BABYSIT_PR_STATE:-${script_dir}/pr-state.sh}"
SLEEP="${BABYSIT_SLEEP:-sleep}"

usage() {
  echo "$1" >&2
  echo "Usage: wait.sh <owner/repo> <pr> --max <minutes> --session <token> [--mode watch|drive] [--snapshot <file>]" >&2
  exit 2
}

lost() {
  echo "$1" >&2
  exit 3
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

repo="${1:-}"
pr="${2:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 2
max=""
token=""
mode="watch"
snapshot=""
while (($# > 0)); do
  case "$1" in
  --max) max="${2:-}" ;;
  --session) token="${2:-}" ;;
  --mode) mode="${2:-}" ;;
  --snapshot) snapshot="${2:-}" ;;
  *) usage "Unknown option: $1" ;;
  esac
  (($# >= 2)) || usage "$1 needs a value"
  shift 2
done
[[ "${max}" =~ ^[0-9]+$ ]] || usage "--max needs whole minutes"
[[ "${token}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
[[ "${mode}" == watch || "${mode}" == drive ]] || usage "--mode is watch or drive"
[[ -z "${snapshot}" || -r "${snapshot}" ]] || usage "Cannot read snapshot: ${snapshot}"
path="$(babysit_ledger_path "${repo}" "${pr}")" || usage "Not inside a Git repository"

# Prints the ledger after checking that this session still holds its lock.
read_owned_ledger() {
  local ledger
  ledger="$(babysit_ledger_read "${path}")" || lost "Unreadable ledger: ${path}"
  [[ "$(jq -r '.lock.token // ""' <<<"${ledger}")" == "${token}" ]] || lost "Lock is not held by this session"
  printf '%s\n' "${ledger}"
}

fetch() {
  if [[ -n "${snapshot}" ]]; then
    jq -ce . "${snapshot}"
  else
    "${PR_STATE}" "${repo}" "${pr}"
  fi
}

now="$(babysit_now)"
ledger="$(read_owned_ledger)" || exit 3
deadline=$((now + max * 60))
started="$(jq -r '.started_at // ""' <<<"${ledger}")"
if [[ "${started}" =~ ^[0-9]+$ ]] && ((started + SESSION_SECONDS < deadline)); then
  deadline=$((started + SESSION_SECONDS))
fi

while true; do
  now="$(babysit_now)"
  ledger="$(read_owned_ledger)" || exit 3
  if snap="$(fetch)" && [[ -n "${snap}" ]]; then
    result="$(printf '%s\n%s\n' "${snap}" "${ledger}" |
      jq -sc --arg now "${now}" --arg mode "${mode}" -f "${script_dir}/evaluate.jq")" ||
      usage "Snapshot is not a normalized pr-state snapshot"
    # Re-read, so a ledger.sh write made during the fetch survives; only wait's own fields change.
    ledger="$(read_owned_ledger)" || exit 3
    printf '%s\n%s\n' "${ledger}" "${result}" |
      jq -sc --argjson now "${now}" '.[0] + .[1].ledger + {api_failures: 0} | .lock.heartbeat = $now' |
      babysit_ledger_write "${path}" || usage "Cannot write ledger: ${path}"
    event="$(jq -c '.event' <<<"${result}")"
    if [[ "${event}" != null ]]; then
      printf '%s\n' "${event}"
      exit 0
    fi
    pause="${POLL_SECONDS}"
  else
    ledger="$(read_owned_ledger)" || exit 3
    failures=$(($(jq -r '.api_failures // 0' <<<"${ledger}") + 1))
    jq -c --argjson f "${failures}" --argjson now "${now}" \
      '.api_failures = $f | .lock.heartbeat = $now' <<<"${ledger}" |
      babysit_ledger_write "${path}" || usage "Cannot write ledger: ${path}"
    if ((failures >= MAX_FAILURES)); then
      echo "GitHub API failed ${failures} times in a row" >&2
      exit 1
    fi
    pause=$((BACKOFF_FIRST << (failures - 1)))
    ((pause <= BACKOFF_MAX)) || pause="${BACKOFF_MAX}"
  fi
  if ((now >= deadline)); then
    jq -nc --arg repo "${repo}" --argjson pr "${pr}" '{event: "idle", repo: $repo, pr: $pr}'
    exit 0
  fi
  ((pause <= deadline - now)) || pause=$((deadline - now))
  "${SLEEP}" "${pause}"
done
