#!/usr/bin/env bash
# Claims a GitHub Issue for one session through the Git ref refs/claims/issue-<N>, and lists branches
# that already carry its number. The ref points to a blob holding the owner; list claims with
# `git for-each-ref refs/claims` and read one with `git cat-file -p refs/claims/issue-<N>`.
# Usage: claim.sh acquire <issue> [<token>]
#        claim.sh takeover <issue> <token>
#        claim.sh release <issue> <token>
# Run from inside the repository. Set CLAIM_PID to the harness process, normally the calling shell's $PPID.
# Exit: 0 claimed or released, 10 claimed and matching branches exist, 20 held by another session, 2 error.
set -uo pipefail

cmd="${1:-}"
issue="${2:-}"
token="${3:-}"

die() {
  echo "$1" >&2
  exit 2
}

case "${cmd}" in
acquire | takeover | release) ;;
*) die "Unknown command: ${cmd:-<none>}" ;;
esac
[[ "${issue}" =~ ^[1-9][0-9]*$ ]] || die "Invalid issue number: ${issue:-<none>}"
[[ -z "${token}" || "${token}" =~ ^[A-Za-z0-9-]+$ ]] || die "Invalid token"
[[ "${cmd}" == acquire || -n "${token}" ]] || die "${cmd} needs a token"
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

owner_blob() {
  printf 'token=%s\npid=%s\nlstart=%s\nstarted=%s\n' \
    "${token}" "${pid}" "$(lstart_of "${pid}")" "$(date -u +%FT%TZ)" | git hash-object -w --stdin
}

report_held() {
  local opid olstart alive=no
  opid="$(field pid "$1")"
  olstart="$(field lstart "$1")"
  if [[ "${opid}" =~ ^[0-9]+$ && -n "${olstart}" && "$(lstart_of "${opid}")" == "${olstart}" ]]; then
    alive=yes
  fi
  echo "claim=${ref}"
  # This session's own token, so a takeover or a later run can pass it back.
  echo "token=${token}"
  echo "owner_token=$(field token "$1")"
  echo "owner_pid=${opid}"
  echo "owner_started=$(field started "$1")"
  echo "alive=${alive}"
  exit 20
}

held="$(current)"

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
if [[ -n "${held}" && "$(field token "${held}")" == "${token}" ]]; then
  : # This session's own claim from an earlier run.
elif [[ -n "${held}" && "${cmd}" == acquire ]]; then
  report_held "${held}"
else
  blob="$(owner_blob)" || die "Cannot write the owner blob"
  # update-ref compares against the expected value under Git's ref lock, so only one session wins.
  if ! git update-ref "${ref}" "${blob}" "${held:-${zero}}" 2>/dev/null; then
    now="$(current)"
    [[ -n "${now}" ]] || die "Cannot update ${ref}"
    report_held "${now}"
  fi
  [[ -z "${held}" ]] && created="${blob}"
fi

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
