#!/usr/bin/env bash
# The skill's writes to the babysit ledger at $(git-common-dir)/babysit/<owner>/<repo>/<pr>.json.
# wait.sh owns head, heads, and api_failures; every other field is written here.
# Usage: ledger.sh path   <owner/repo> <pr>
#        ledger.sh start  <owner/repo> <pr> <token>   take the lock and reset the session fields
#        ledger.sh record <owner/repo> <pr> <token> <key> <reported|handled|parked|rerun> [--hash <h>] [--run-id <n>]
#        ledger.sh stop   <owner/repo> <pr> <token>   clear the lock
#        ledger.sh show   <owner/repo> <pr>
# start with the token that already holds the lock resumes the session without a reset.
# Exit: 0 done, 2 usage error or unwritable ledger, 3 the lock belongs to another session.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

# A heartbeat this old means its session died, so another session may take the PR over.
STALE_SECONDS=4200

die() {
  echo "$1" >&2
  exit 2
}

lost() {
  echo "$1" >&2
  exit 3
}

command -v jq >/dev/null 2>&1 || die "jq is required"

cmd="${1:-}"
repo="${2:-}"
pr="${3:-}"
case "${cmd}" in
path | start | record | stop | show) ;;
*) die "Unknown command: ${cmd:-<none>}" ;;
esac
babysit_valid_repo "${repo}" || die "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || die "Invalid pull request number: ${pr:-<none>}"
path="$(babysit_ledger_path "${repo}" "${pr}")" || die "Not inside a Git repository"

if [[ "${cmd}" == path ]]; then
  printf '%s\n' "${path}"
  exit 0
fi
ledger="$(babysit_ledger_read "${path}")" || die "Unreadable ledger: ${path}"
if [[ "${cmd}" == show ]]; then
  jq . <<<"${ledger}"
  exit 0
fi

token="${4:-}"
[[ "${token}" =~ ^[A-Za-z0-9-]+$ ]] || die "Invalid token"
now="$(babysit_now)"
owner="$(jq -r '.lock.token // ""' <<<"${ledger}")"

write() {
  babysit_ledger_write "${path}" || die "Cannot write ledger: ${path}"
}

case "${cmd}" in
start)
  if [[ "${owner}" == "${token}" ]]; then
    jq -c --argjson now "${now}" '.lock.heartbeat = $now' <<<"${ledger}" | write
    echo "resumed"
    exit 0
  fi
  if [[ -n "${owner}" ]]; then
    age=$((now - $(jq -r '.lock.heartbeat // 0' <<<"${ledger}")))
    ((age >= STALE_SECONDS)) || lost "Held by session ${owner}, heartbeat ${age}s ago"
  fi
  jq -c --argjson now "${now}" --arg token "${token}" '
    . + {started_at: $now, rounds: 0, repairs: {}, replies: {}, api_failures: 0,
         lock: {token: $token, heartbeat: $now}}' <<<"${ledger}" | write
  echo "started"
  ;;
record)
  [[ "${owner}" == "${token}" ]] || lost "Lock is not held by this session"
  key="${5:-}"
  disposition="${6:-}"
  [[ -n "${key}" ]] || die "record needs a key"
  case "${disposition}" in
  reported | handled | parked | rerun) ;;
  *) die "Invalid disposition: ${disposition:-<none>}" ;;
  esac
  shift 6
  hash=""
  run_id=""
  while (($# > 0)); do
    case "$1" in
    --hash)
      hash="${2:-}"
      shift 2 || die "--hash needs a value"
      ;;
    --run-id)
      run_id="${2:-}"
      [[ "${run_id}" =~ ^[0-9]+$ ]] || die "--run-id needs a number"
      shift 2
      ;;
    *) die "Unknown option: $1" ;;
    esac
  done
  [[ "${disposition}" != rerun || -n "${run_id}" ]] || die "rerun needs --run-id"
  # Without the body hash a comment item never counts as settled and would return on every call.
  [[ "${key}" != c:* || -n "${hash}" ]] || die "a comment key needs --hash"
  jq -c --arg key "${key}" --arg d "${disposition}" --arg hash "${hash}" --arg run "${run_id}" \
    --argjson now "${now}" '
    .items[$key] = ({disposition: $d, at: $now}
      + (if $hash != "" then {hash: $hash} else {} end)
      + (if $run != "" then {run_id: ($run | tonumber)} else {} end))
    | .lock.heartbeat = $now' <<<"${ledger}" | write
  ;;
stop)
  [[ "${owner}" == "${token}" ]] || lost "Lock is not held by this session"
  jq -c 'del(.lock)' <<<"${ledger}" | write
  ;;
esac
