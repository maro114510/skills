#!/usr/bin/env bash
# Claims a GitHub Issue for one session on this machine, and lists branches that already carry its number.
# Usage: claim.sh acquire <owner/repo> <issue> [<token>]
#        claim.sh takeover <owner/repo> <issue> <token>
#        claim.sh release <owner/repo> <issue> <token>
# Run from inside the repository. Set CLAIM_PID to the harness process, normally the calling shell's $PPID.
# Exit: 0 claimed or released, 10 claimed and matching branches exist, 20 held by another session, 2 error.
set -uo pipefail

cmd="${1:-}"
repo="${2:-}"
issue="${3:-}"
token="${4:-}"

die() {
  echo "$1" >&2
  exit 2
}

case "${cmd}" in
acquire | takeover | release) ;;
*) die "Unknown command: ${cmd:-<none>}" ;;
esac
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid repo: ${repo:-<none>}"
case "/${repo}/" in
*/./* | */../*) die "Invalid repo: ${repo}" ;;
esac
[[ "${issue}" =~ ^[1-9][0-9]*$ ]] || die "Invalid issue number: ${issue:-<none>}"
[[ -z "${token}" || "${token}" =~ ^[A-Za-z0-9-]+$ ]] || die "Invalid token"
[[ "${cmd}" == acquire || -n "${token}" ]] || die "${cmd} needs a token"

claim="${XDG_STATE_HOME:-${HOME}/.local/state}/agent-claims/${repo}/issue-${issue}"
pid="${CLAIM_PID:-${PPID}}"

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

owner_field() {
  sed -n "s/^$1=//p" "${claim}/owner" 2>/dev/null | head -n1
}

# Writes the owner file through a rename, so a reader never sees it half written.
write_owner() {
  local tmp
  tmp="$(mktemp "${claim}/.owner.XXXXXX")" || return 1
  printf 'token=%s\npid=%s\nlstart=%s\nstarted=%s\ncwd=%s\n' \
    "${token}" "${pid}" "$(lstart_of "${pid}")" "$(date -u +%FT%TZ)" "${PWD}" >"${tmp}" &&
    mv -f "${tmp}" "${claim}/owner"
}

drop_claim() {
  rm -f -- "${claim}/owner" && rmdir -- "${claim}"
}

report_held() {
  echo "claim=${claim}"
  if [[ ! -f "${claim}/owner" ]]; then
    echo "owner=missing"
    exit 20
  fi
  local opid olstart alive=no
  opid="$(owner_field pid)"
  olstart="$(owner_field lstart)"
  if [[ "${opid}" =~ ^[0-9]+$ && -n "${olstart}" && "$(lstart_of "${opid}")" == "${olstart}" ]]; then
    alive=yes
  fi
  echo "owner_token=$(owner_field token)"
  echo "owner_pid=${opid}"
  echo "owner_started=$(owner_field started)"
  echo "owner_cwd=$(owner_field cwd)"
  echo "alive=${alive}"
  exit 20
}

if [[ "${cmd}" == release ]]; then
  [[ -e "${claim}" ]] || exit 0
  [[ "$(owner_field token)" == "${token}" ]] || report_held
  drop_claim || die "Could not remove ${claim}"
  exit 0
fi

mkdir -p -- "$(dirname -- "${claim}")" 2>/dev/null || die "Cannot create $(dirname -- "${claim}")"
[[ -n "${token}" ]] || token="$(new_token)"
created=0
if mkdir -- "${claim}" 2>/dev/null; then
  created=1
  write_owner || {
    drop_claim
    die "Cannot write ${claim}/owner"
  }
elif [[ ! -d "${claim}" ]]; then
  die "Cannot create ${claim}"
elif [[ "${cmd}" == takeover ]]; then
  write_owner || die "Cannot write ${claim}/owner"
elif [[ "$(owner_field token)" != "${token}" ]]; then
  report_held
fi

# A failed ls-remote would otherwise read as "no branch" and hide work that is already pushed.
if ! remote="$(git ls-remote --heads origin 2>/dev/null)"; then
  [[ "${created}" -eq 1 ]] && drop_claim
  die "git ls-remote origin failed"
fi

pattern="(^|/)issue-${issue}(-|\$)"
remote_branches="$(printf '%s\n' "${remote}" | awk '{print $2}' | sed -n 's#^refs/heads/##p')"
local_branches="$(git for-each-ref --format='%(refname)' refs/heads | sed 's#^refs/heads/##')"
worktrees="$(git worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10) }
  /^branch refs\/heads\// { print substr($0, 19) "\t" path }')"
matches="$(printf '%s\n%s\n' "${local_branches}" "${remote_branches}" | grep -E "${pattern}" | sort -u)"

echo "claim=${claim}"
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
