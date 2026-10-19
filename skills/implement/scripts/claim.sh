#!/usr/bin/env bash
# Claims a GitHub Issue for one session through the Git ref refs/claims/issue-<N>, and lists branches
# that already carry its number. The ref points to a blob holding the owner; list claims with
# `git for-each-ref refs/claims` and read one with `git cat-file -p refs/claims/issue-<N>`.
# Usage: claim.sh acquire <issue> [<token>]
#        claim.sh takeover <issue> <token>
#        claim.sh release <issue> <token>
#        claim.sh status <issue>
# Run from inside the repository. Set CLAIM_PID to the harness process, normally the calling shell's $PPID.
# Inside a herdr pane, the claim also records the pane and its agent session, so state= can tell whether
# the owner session is still running; herdr and jq are optional, and without them state= is unknown.
# Exit: 0 claimed, released, or free, 10 claimed and matching branches exist, 20 held by another session, 2 error.
# status takes no token, so its exit 20 means held by any session, this one included; compare owner_token.
set -uo pipefail

cmd="${1:-}"
issue="${2:-}"
token="${3:-}"

die() {
  echo "$1" >&2
  exit 2
}

case "${cmd}" in
acquire | takeover | release | status) ;;
*) die "Unknown command: ${cmd:-<none>}" ;;
esac
[[ "${issue}" =~ ^[1-9][0-9]*$ ]] || die "Invalid issue number: ${issue:-<none>}"
[[ -z "${token}" || "${token}" =~ ^[A-Za-z0-9-]+$ ]] || die "Invalid token"
[[ "${cmd}" == acquire || "${cmd}" == status || -n "${token}" ]] || die "${cmd} needs a token"
git rev-parse --git-dir >/dev/null 2>&1 || die "Not inside a Git repository"

ref="refs/claims/issue-${issue}"
pid="${CLAIM_PID:-${PPID}}"
# The all-zero object name tells update-ref that the ref must not exist yet; its length follows the hash.
zero="$(git hash-object --stdin </dev/null | tr '0-9a-f' '0')"

new_token() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

lstart_of() {
  ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'
}

current() {
  git rev-parse -q --verify "${ref}" 2>/dev/null
}

# Prints field $1 of the owner blob $2.
field() {
  git cat-file -p "$2" 2>/dev/null | sed -n "s/^$1=//p" | head -n1
}

# Prints $1 when it is a non-empty single value, so a value from the environment or herdr cannot add owner fields.
single() {
  [[ -n "$1" && "$1" != *[[:cntrl:]]* ]] && printf '%s' "$1"
}

# jq definition of one: a value that is not a single-line string reads as empty, so it can neither split a
# printed line nor be recorded.
jq_one='def one: if type == "string" and (test("[[:cntrl:]]") | not) then . else "" end;'

# Prints herdr's view of pane $1 as agent status, agent, and agent session, separated by the unit separator;
# fails when the pane is closed or herdr or jq is unavailable.
pane_info() {
  herdr pane get "$1" 2>/dev/null | jq -er "${jq_one}"'
    .result.pane | objects
    | "\(.agent_status | one | if . == "" then "unknown" else . end)\u001f\(.agent | one)\u001f\(.agent_session.value | one)"' \
    2>/dev/null
}

# Prints the pane that runs agent session $1 and its agent status, separated by the unit separator, preferring the
# pane doing the most work; prints an empty pane and gone when no pane runs it, and fails when herdr or jq does.
session_pane() {
  herdr pane list 2>/dev/null | jq -er --arg s "$1" "${jq_one}"'
    [.result.panes[] | select(.agent_session.value == $s)]
    | sort_by(.agent_status != "working", .agent_status != "blocked")
    | first // {pane_id: "", agent_status: "gone"}
    | "\(.pane_id | one)\u001f\(.agent_status | one | if . == "" then "unknown" else . end)"' 2>/dev/null
}

# Succeeds when the shell of herdr pane $1 is an ancestor of this script. A long-lived process, such as Codex's
# app-server daemon, keeps the HERDR_PANE_ID of the pane that started it long after that pane closed or moved on.
in_pane() {
  local shell p i
  shell="$(herdr pane process-info --pane "$1" 2>/dev/null |
    jq -r '.result.process_info.shell_pid // empty' 2>/dev/null)"
  [[ "${shell}" =~ ^[0-9]+$ ]] || return 1
  p=$$
  for ((i = 0; i < 64 && p > 1; i++)); do
    [[ "${p}" == "${shell}" ]] && return 0
    p="$(ps -o ppid= -p "${p}" 2>/dev/null | tr -d ' ')"
    [[ "${p}" =~ ^[0-9]+$ ]] || return 1
  done
  return 1
}

# Writes the owner blob, with the herdr pane and agent session of this run when both are certain; otherwise both
# stay empty, so state= reads unknown rather than reporting another session's state or a false gone.
# - A harness that names its own session, as Claude Code and Codex do, owns the pane herdr shows running it,
#   wherever this process sits; Codex runs tools from a daemon outside the pane.
# - Otherwise, as for opencode, HERDR_PANE_ID counts only when this process runs inside that pane.
owner_blob() {
  local pane="" session="" own status agent
  own="$(single "${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-}}")"
  if [[ -n "${own}" ]]; then
    IFS=$'\x1f' read -r pane status <<<"$(session_pane "${own}")"
    session="${own}"
  elif pane="$(single "${HERDR_PANE_ID:-}")" && in_pane "${pane}"; then
    IFS=$'\x1f' read -r status agent session <<<"$(pane_info "${pane}")"
  fi
  pane="$(single "${pane}")"
  session="$(single "${session}")"
  if [[ -z "${pane}" || -z "${session}" ]]; then
    pane=""
    session=""
  fi
  printf 'token=%s\npid=%s\nlstart=%s\nstarted=%s\npane=%s\nsession=%s\n' \
    "${token}" "${pid}" "$(lstart_of "${pid}")" "$(date -u +%FT%TZ)" "${pane}" "${session}" |
    git hash-object -w --stdin
}

# Sets owner_pane, owner_session, pane_session, active_pane, and state for the owner recorded in blob $1.
# state is herdr's agent status for the pane running the owner session, gone when herdr answers and no pane
# runs it, and unknown otherwise; a herdr or jq failure is never read as gone, which would invite a takeover.
owner_state() {
  local info status agent
  owner_pane="$(field pane "$1")"
  owner_session="$(field session "$1")"
  pane_session=""
  active_pane=""
  state=unknown
  [[ -n "${owner_pane}" && -n "${owner_session}" ]] || return 0
  if info="$(pane_info "${owner_pane}")"; then
    IFS=$'\x1f' read -r status agent pane_session <<<"${info}"
    if [[ "${pane_session}" == "${owner_session}" ]]; then
      active_pane="${owner_pane}"
      state="${status}"
      return 0
    fi
    # An agent that has not reported its session yet may still be the owner.
    [[ -z "${pane_session}" && -n "${agent}" ]] && return 0
  fi
  # The recorded pane is closed, unreadable, or runs another session, and herdr's pane list decides: the owner
  # may have been resumed in another pane. A list herdr cannot give leaves the state unknown.
  IFS=$'\x1f' read -r active_pane state <<<"$(session_pane "${owner_session}" || echo $'\x1funknown')"
}

report_held() {
  local opid olstart alive=no
  opid="$(field pid "$1")"
  olstart="$(field lstart "$1")"
  if [[ "${opid}" =~ ^[0-9]+$ && -n "${olstart}" && "$(lstart_of "${opid}")" == "${olstart}" ]]; then
    alive=yes
  fi
  owner_state "$1"
  echo "claim=${ref}"
  # This session's own token, so a takeover or a later run can pass it back; status has none.
  [[ -n "${token}" ]] && echo "token=${token}"
  echo "owner_token=$(field token "$1")"
  echo "owner_pid=${opid}"
  echo "owner_started=$(field started "$1")"
  echo "alive=${alive}"
  echo "owner_pane=${owner_pane:--}"
  echo "owner_session=${owner_session:--}"
  echo "pane_session=${pane_session:--}"
  echo "active_pane=${active_pane:--}"
  echo "state=${state}"
  exit 20
}

held="$(current)"

if [[ "${cmd}" == status ]]; then
  [[ -n "${held}" ]] && report_held "${held}"
  echo "claim=${ref}"
  exit 0
fi

if [[ "${cmd}" == release ]]; then
  [[ -n "${held}" ]] || exit 0
  [[ "$(field token "${held}")" == "${token}" ]] || report_held "${held}"
  # Deleting against the value just read refuses if another session changed the claim in between.
  if ! git update-ref -d "${ref}" "${held}" 2>/dev/null; then
    now="$(current)"
    [[ -n "${now}" ]] && report_held "${now}"
  fi
  exit 0
fi

[[ -n "${token}" ]] || token="$(new_token)"
created=""
if [[ -n "${held}" && "${cmd}" == acquire && "$(field token "${held}")" != "${token}" ]]; then
  report_held "${held}"
fi
# A rerun with this session's own token rewrites the owner too, so pid, pane, and session describe this run,
# as after a resume or after a claim written by an older version of this script.
blob="$(owner_blob)" || die "Cannot write the owner blob"
# update-ref compares against the expected value under Git's ref lock, so only one session wins.
if ! git update-ref "${ref}" "${blob}" "${held:-${zero}}" 2>/dev/null; then
  now="$(current)"
  [[ -n "${now}" ]] || die "Cannot update ${ref}"
  report_held "${now}"
fi
[[ -z "${held}" ]] && created="${blob}"

# A failed ls-remote would otherwise read as "no branch" and hide work that is already pushed.
if ! remote="$(git ls-remote --heads origin 2>/dev/null)"; then
  if [[ -n "${created}" ]]; then
    git update-ref -d "${ref}" "${created}" 2>/dev/null
  else
    # The claim existed before this run or was just taken over, so it stays held; say so.
    echo "claim=${ref}"
    echo "token=${token}"
  fi
  die "git ls-remote origin failed"
fi

pattern="(^|/)issue-${issue}(-|\$)"
remote_branches="$(printf '%s\n' "${remote}" | awk '{print $2}' | sed -n 's#^refs/heads/##p')"
local_branches="$(git for-each-ref --format='%(refname)' refs/heads | sed 's#^refs/heads/##')"
worktrees="$(git worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10) }
  /^branch refs\/heads\// { print substr($0, 19) "\t" path }')"
matches="$(printf '%s\n%s\n' "${local_branches}" "${remote_branches}" | grep -E "${pattern}" | sort -u)"

echo "claim=${ref}"
echo "token=${token}"
[[ -n "${matches}" ]] || exit 0
while IFS= read -r b; do
  on_remote=no
  printf '%s\n' "${remote_branches}" | grep -qxF -- "${b}" && on_remote=yes
  wt="$(printf '%s\n' "${worktrees}" | awk -F '\t' -v b="${b}" '$1 == b { print $2; exit }')"
  dirty=-
  if [[ -n "${wt}" ]]; then
    wt="$(cd "${wt}" 2>/dev/null && pwd -P || printf '%s' "${wt}")"
    dirty=no
    [[ -n "$(git -C "${wt}" status --porcelain 2>/dev/null)" ]] && dirty=yes
  fi
  echo "branch=${b} remote=${on_remote} worktree=${wt:--} dirty=${dirty}"
done <<<"${matches}"
exit 10
