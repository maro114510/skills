#!/usr/bin/env bash
# The skill's writes to the babysit ledger at $(git-common-dir)/babysit/<owner>/<repo>/<pr>.json.
# wait.sh owns head, heads, and api_failures; every other field is written here.
# Usage: ledger.sh path   <owner/repo> <pr>
#        ledger.sh start  <owner/repo> <pr> <token>   take the lock and reset the session fields
#        ledger.sh record <owner/repo> <pr> <token> <key> <reported|handled|parked|rerun> [--hash <h>] [--run-id <n>] [--reason <text>]
#        ledger.sh stop   <owner/repo> <pr> <token>   clear the lock
#        ledger.sh show   <owner/repo> <pr>
# Drive mode writes, each of which also refreshes the heartbeat:
#        ledger.sh touch       <owner/repo> <pr> <token>
#        ledger.sh own-push    <owner/repo> <pr> <token> <sha>   list a push before it goes out
#        ledger.sh count-push  <owner/repo> <pr> <token> [<check key>...]   one round, and one repair per check key
#        ledger.sh reply-begin <owner/repo> <pr> <token> <thread|conversation> --hash <h>   list a reply before posting
#        ledger.sh reply-done  <owner/repo> <pr> <token> <thread|conversation> --hash <h> --id <comment id>
#        ledger.sh replies     <owner/repo> <pr> <thread|conversation>   print the agent replies counted on a thread
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
path | start | record | stop | show | replies | touch | own-push | count-push | reply-begin | reply-done) ;;
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

valid_thread() {
  [[ "$1" =~ ^[A-Za-z0-9_=-]+$ ]]
}

if [[ "${cmd}" == replies ]]; then
  valid_thread "${4:-}" || die "Invalid thread: ${4:-<none>}"
  jq -r --arg t "$4" '.replies[$t] // 0' <<<"${ledger}"
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
  reason=""
  while (($# > 0)); do
    case "$1" in
    --hash)
      hash="${2:-}"
      shift 2 || die "--hash needs a value"
      ;;
    --reason)
      reason="${2:-}"
      shift 2 || die "--reason needs a value"
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
    --arg reason "${reason}" --argjson now "${now}" '
    .items[$key] = ({disposition: $d, at: $now}
      + (if $hash != "" then {hash: $hash} else {} end)
      + (if $reason != "" then {reason: $reason} else {} end)
      + (if $run != "" then {run_id: ($run | tonumber)} else {} end))
    | .lock.heartbeat = $now' <<<"${ledger}" | write
  ;;
stop)
  [[ "${owner}" == "${token}" ]] || lost "Lock is not held by this session"
  jq -c 'del(.lock)' <<<"${ledger}" | write
  ;;
touch | own-push | count-push | reply-begin | reply-done)
  [[ "${owner}" == "${token}" ]] || lost "Lock is not held by this session"
  # Every drive write is a sign of life, so it ends by moving the heartbeat.
  write_beating() {
    jq -c --argjson now "${now}" '.lock.heartbeat = $now' | write
  }
  case "${cmd}" in
  touch)
    write_beating <<<"${ledger}"
    ;;
  own-push)
    sha="${5:-}"
    [[ "${sha}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "own-push needs a full commit sha"
    jq -c --arg sha "${sha}" '.own.pushes = ((.own.pushes // []) + [$sha])' <<<"${ledger}" | write_beating
    ;;
  count-push)
    shift 4
    keys="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))')"
    jq -c --argjson keys "${keys}" '
      .rounds = ((.rounds // 0) + 1)
      | reduce $keys[] as $k (.; .repairs[$k] = ((.repairs[$k] // 0) + 1))' <<<"${ledger}" | write_beating
    ;;
  reply-begin | reply-done)
    thread="${5:-}"
    valid_thread "${thread}" || die "Invalid thread: ${thread:-<none>}"
    shift 5
    hash=""
    comment_id=""
    while (($# > 0)); do
      case "$1" in
      --hash) hash="${2:-}" ;;
      --id) comment_id="${2:-}" ;;
      *) die "Unknown option: $1" ;;
      esac
      (($# >= 2)) || die "$1 needs a value"
      shift 2
    done
    [[ -n "${hash}" ]] || die "${cmd} needs --hash"
    if [[ "${cmd}" == reply-begin ]]; then
      jq -c --arg hash "${hash}" --arg thread "${thread}" \
        '.own.replies = ((.own.replies // []) + [{hash: $hash, id: null, thread: $thread}])' \
        <<<"${ledger}" | write_beating
    else
      [[ -n "${comment_id}" ]] || die "reply-done needs --id"
      jq -e --arg hash "${hash}" 'any((.own.replies // [])[]; .hash == $hash and .id == null)' <<<"${ledger}" >/dev/null ||
        die "No pending reply with that hash"
      # The first pending entry with the hash takes the id, and the reply counts against its thread.
      jq -c --arg hash "${hash}" --arg id "${comment_id}" --arg thread "${thread}" '
        (.own.replies | map(.hash == $hash and .id == null) | index(true)) as $i
        | .own.replies[$i].id = $id
        | .replies[$thread] = ((.replies[$thread] // 0) + 1)' <<<"${ledger}" | write_beating
    fi
    ;;
  esac
  ;;
esac
