#!/usr/bin/env bash
# Parks an item: records it as parked with the reason a human needs, then shows a macOS notification when
# osascript is available. A missing or failing osascript never stops the park.
# Usage: park.sh <owner/repo> <pr> --session <token> --key <item key> --reason <text> [--hash <body hash>]
# A comment key needs its --hash, so the item returns only when the comment text changes.
# The reason may hold comment text, so it reaches osascript as an argument and never as script.
# Prints {"parked":true,"key":...,"notified":true|false}. Test hook BABYSIT_OSASCRIPT replaces osascript.
# Exit: 0 parked, 2 usage error or an unwritable ledger, 3 the lock is not ours.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

OSASCRIPT="${BABYSIT_OSASCRIPT:-osascript}"
MAX_REASON=200

usage() {
  echo "$1" >&2
  echo "Usage: park.sh <owner/repo> <pr> --session <token> --key <item key> --reason <text> [--hash <body hash>]" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

repo="${1:-}"
pr="${2:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 2
token=""
key=""
reason=""
hash=""
while (($# > 0)); do
  case "$1" in
  --session) token="${2:-}" ;;
  --key) key="${2:-}" ;;
  --reason) reason="${2:-}" ;;
  --hash) hash="${2:-}" ;;
  *) usage "Unknown option: $1" ;;
  esac
  (($# >= 2)) || usage "$1 needs a value"
  shift 2
done
[[ "${token}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
[[ "${key}" == k:* || "${key}" == x:* || "${key}" == c:* ]] || usage "--key needs an item key"
[[ "${key}" != c:* || -n "${hash}" ]] || usage "a comment key needs --hash"
[[ "${reason}" =~ [^[:space:]] ]] || usage "--reason is required"

# One line, no control characters, and a bounded length, for both the ledger and the notification.
reason="$(printf '%s' "${reason}" | tr '[:cntrl:]' ' ' | cut -c "1-${MAX_REASON}")"

args=("${repo}" "${pr}" "${token}" "${key}" parked --reason "${reason}")
[[ -z "${hash}" ]] || args+=(--hash "${hash}")
bash "${script_dir}/ledger.sh" record "${args[@]}" || exit $?

notified=false
if command -v "${OSASCRIPT}" >/dev/null 2>&1; then
  if "${OSASCRIPT}" -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' -e 'end run' \
    "${reason}" "babysit parked ${repo}#${pr}" >/dev/null 2>&1 </dev/null; then
    notified=true
  fi
fi
jq -nc --arg key "${key}" --argjson notified "${notified}" '{parked: true, key: $key, notified: $notified}'
