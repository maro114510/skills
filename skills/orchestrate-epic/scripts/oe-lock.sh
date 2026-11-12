#!/usr/bin/env bash
# oe lock
#
# Admits one orchestrate-epic session per Epic on this host.
# A second session for the same Epic is refused while the first one runs.
#
# Usage
#
#   OE_SESSION_PID=<pid> oe lock acquire <owner/repo> <epic-number> [<token>]
#   oe lock release <owner/repo> <epic-number> <token>
#
# - OE_SESSION_PID is the process that lives as long as the session, normally the harness: pass "$PPID" from its shell.
# - acquire prints token=<token>. The session keeps it, and passes it again to re-acquire after a resume or to release.
# - The holder is running while its process exists and started when it did, so a reused PID never keeps a lock.
# - The start time is recorded in UTC and the C locale, so whether the holder runs does not depend on the reader's TZ or locale.
#   A lock taken before that holds its taker's TZ and locale, and is read correctly only under the same ones until its holder acquires again or ends.
# - A lock whose holder is no longer running is taken over by the next acquire.
# - The lock records when it was taken, at OE_NOW in epoch seconds when set, as a record's at.
#   The same session acquiring again with its token keeps that time, so the agents it started still count as running.
#
# Storage
#
# - One ref per Epic in a bare Git repository under the state directory that oe-store.sh defines, so every clone on the host shares it.
# - Every change is a compare-and-swap on that ref, so two sessions racing for a lock never both get it.
#
# Exit codes
#
# | Code | Meaning |
# |---|---|
# | 0 | acquire: this session holds the lock, and the Epic's oe wait, if one runs, is stopped unless this session already held the lock. release: the lock is free, and the Epic's oe wait, if one runs, is stopped |
# | 1 | The lock store failed |
# | 2 | The arguments are invalid, or OE_SESSION_PID is not a running process |
# | 4 | Another running session holds the lock |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: OE_SESSION_PID=<pid> oe lock acquire <owner/repo> <epic-number> [<token>]" >&2
  echo "       oe lock release <owner/repo> <epic-number> <token>" >&2
  exit 2
}

fail() {
  echo "oe lock: $1" >&2
  exit 1
}

[[ $# -ge 3 && $# -le 4 ]] || usage "Expected acquire|release <owner/repo> <epic-number> [<token>]"
cmd="$1"
[[ "${cmd}" == acquire || "${cmd}" == release ]] || usage "Unknown subcommand: ${cmd}"
[[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $2"
[[ "$3" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $3"
repo="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
epic="$3"
token="${4:-}"
[[ -z "${token}" || "${token}" =~ ^[A-Za-z0-9-]+$ ]] || usage "Invalid token"
[[ "${cmd}" == acquire || -n "${token}" ]] || usage "release needs the token that acquire printed"

state="$(state_dir)"
store="$(lock_store)"

store_git() {
  git --git-dir="${store}" "$@"
}

if [[ ! -d "${store}" ]]; then
  mkdir -p "${state}" || fail "cannot create ${state}"
  git init --quiet --bare "${store}" || fail "cannot create the lock store ${store}"
fi

ref="$(lock_ref "${repo}" "${epic}")"
# The all-zero object name tells update-ref that the ref must not exist yet.
zero="$(store_git hash-object --stdin </dev/null | tr '0-9a-f' '0')"

# Prints the holder blob of the lock, or nothing when the lock is free.
# Only rev-parse exit 1 means the ref is missing; any other failure means the store itself cannot be read.
holder() {
  local out rc
  out="$(store_git rev-parse --quiet --verify "${ref}")"
  rc=$?
  case "${rc}" in
  0) printf "%s" "${out}" ;;
  1) ;;
  *) fail "cannot read the lock store ${store}" ;;
  esac
}

refuse() {
  echo "oe lock: another session holds ${repo}#${epic}: pid=$(lock_field pid "$1") started=$(lock_field started "$1")" >&2
  exit 4
}

if [[ "${cmd}" == release ]]; then
  current="$(holder)" || exit 1
  if [[ -n "${current}" ]]; then
    [[ "$(lock_field token "${current}")" == "${token}" ]] || refuse "${current}"
    store_git update-ref -d "${ref}" "${current}" || fail "cannot release ${repo}#${epic}"
  fi
  # A session that ends leaves no wait behind for the Epic.
  stop_recorded_wait "${repo}" "${epic}"
  exit 0
fi

pid="${OE_SESSION_PID:-}"
[[ "${pid}" =~ ^[1-9][0-9]*$ ]] || usage "OE_SESSION_PID must name the session's process"
lstart="$(process_start "${pid}")"
[[ -n "${lstart}" ]] || usage "OE_SESSION_PID ${pid} is not running"

if [[ -z "${token}" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    token="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  fi
fi

started="$(record_now)" || usage "OE_NOW must be epoch seconds"
blob="$(printf 'token=%s\npid=%s\nlstart=%s\nrepo=%s\nepic=%s\nstarted=%s\n' \
  "${token}" "${pid}" "${lstart}" "${repo}" "${epic}" "${started}" |
  store_git hash-object -w --stdin)" || fail "cannot write to the lock store"

# Succeeds when the holder blob $1 names this session: the same token, process, and process start.
same_session() {
  [[ "$(lock_field token "$1")" == "${token}" && "$(lock_field pid "$1")" == "${pid}" ]] &&
    [[ "$(lock_field lstart "$1")" == "${lstart}" ]]
}

# A failed swap means another session changed the lock in between, so it is read again.
for _ in 1 2 3; do
  current="$(holder)" || exit 1
  # The same session acquiring again keeps its lock as it was, so oe ready still counts the agents it started since.
  if [[ -n "${current}" ]] && same_session "${current}"; then
    printf 'token=%s\n' "${token}"
    exit 0
  fi
  if [[ -n "${current}" ]]; then
    if [[ "$(lock_field token "${current}")" != "${token}" ]] && lock_holder_running "${current}"; then
      refuse "${current}"
    fi
    expected="${current}"
  else
    expected="${zero}"
  fi
  if store_git update-ref "${ref}" "${blob}" "${expected}" 2>/dev/null; then
    # A wait left by a session that ended would answer every new wait with exit 6 while its own completion reaches no one.
    stop_recorded_wait "${repo}" "${epic}"
    printf 'token=%s\n' "${token}"
    exit 0
  fi
done
fail "the lock for ${repo}#${epic} kept changing"
