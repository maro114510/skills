#!/usr/bin/env bash
# Takes one look at a pull request and reports it, writing nothing: not the ledger, not GitHub.
# Usage: check.sh <owner/repo> <pr> [--mode watch|drive] [--snapshot <file>]
# Output: one JSON object with status (READY, NOT_READY, MERGED, or CLOSED), the event wait would
# return now or null, the READY blockers, the pending items, and the parked, reported, and handled items.
# Outside a Git repository there is no ledger, so every item counts as new.
# Exit: 0 reported, 1 the GitHub API failed, 2 usage error.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/babysit/scripts/common.sh
source "${script_dir}/common.sh"

PR_STATE="${BABYSIT_PR_STATE:-${script_dir}/pr-state.sh}"

usage() {
  echo "$1" >&2
  echo "Usage: check.sh <owner/repo> <pr> [--mode watch|drive] [--snapshot <file>]" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

repo="${1:-}"
pr="${2:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 2
mode="watch"
snapshot=""
while (($# > 0)); do
  case "$1" in
  --mode) mode="${2:-}" ;;
  --snapshot) snapshot="${2:-}" ;;
  *) usage "Unknown option: $1" ;;
  esac
  (($# >= 2)) || usage "$1 needs a value"
  shift 2
done
[[ "${mode}" == watch || "${mode}" == drive ]] || usage "--mode is watch or drive"

ledger='{}'
if path="$(babysit_ledger_path "${repo}" "${pr}")"; then
  ledger="$(babysit_ledger_read "${path}")" || usage "Unreadable ledger: ${path}"
fi

if [[ -n "${snapshot}" ]]; then
  [[ -r "${snapshot}" ]] || usage "Cannot read snapshot: ${snapshot}"
  snap="$(jq -ce . "${snapshot}")" || usage "Snapshot is not JSON: ${snapshot}"
else
  snap="$("${PR_STATE}" "${repo}" "${pr}")" || {
    echo "Could not read the pull request from GitHub" >&2
    exit 1
  }
fi

printf '%s\n%s\n' "${snap}" "${ledger}" |
  jq -s --arg now "$(babysit_now)" --arg mode "${mode}" -f "${script_dir}/evaluate.jq" |
  jq '{status, event, blockers, pending, report}' ||
  usage "Snapshot is not a normalized pr-state snapshot"
