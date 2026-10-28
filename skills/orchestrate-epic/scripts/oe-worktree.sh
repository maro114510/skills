#!/usr/bin/env bash
# oe worktree
#
# Creates or removes the worktree an agent works in for one Issue, outside the shared checkout.
# It never switches, pulls, or writes the shared checkout's HEAD, index, or working tree.
#
# Usage
#
#   oe worktree add <issue-number>
#   oe worktree remove <issue-number>
#
# - Run it from the shared checkout or any worktree of the same clone.
# - The worktree lives at <root>/issue-<number>, where <root> is OE_WORKTREE_ROOT when set.
# - Otherwise <root> is a sibling of the main checkout named after it with -oe appended.
#
# | Subcommand | Does |
# |---|---|
# | add | Fetches the Issue branch from origin and checks it out in a fresh worktree tracking it, then prints the path |
# | remove | Removes the worktree and the local Issue branch, discarding unpushed work |
#
# - add replaces a leftover worktree at the path, so a fresh agent starts from what origin holds.
# - Only a worktree of this clone is ever replaced or removed; any other directory at the path stays.
#
# Exit codes
#
# | Code | Meaning |
# |---|---|
# | 0 | Done |
# | 1 | Git failed, the branch is not on origin, or the path holds something oe did not create |
# | 2 | The arguments are invalid, or this is not a Git repository |
set -uo pipefail

# A repository selected by the caller's environment must never reach these commands.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe worktree add|remove <issue-number>" >&2
  exit 2
}

fail() {
  echo "oe worktree: $1" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage "Expected add|remove <issue-number>"
[[ "$1" == add || "$1" == remove ]] || usage "Unknown subcommand: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
cmd="$1"
n="$2"
branch="${branch_prefix}${n}"

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || usage "Not inside a Git repository"
main="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[[ -n "${main}" ]] || fail "cannot find the main checkout"
root="${OE_WORKTREE_ROOT:-${main%/*}/${main##*/}-oe}"
[[ "${root}" == /* ]] || usage "OE_WORKTREE_ROOT must be an absolute path"
wt="${root}/issue-${n}"

# Succeeds when $wt is the top of a worktree of this clone, not just a directory that happens to sit there.
is_our_worktree() {
  local top there
  top="$(git -C "${wt}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  there="$(git -C "${wt}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$(cd "${top}" && pwd -P)" == "$(cd "${wt}" && pwd -P)" ]] &&
    [[ "$(cd "${there}" && pwd -P)" == "$(cd "${common}" && pwd -P)" ]]
}

# Removes the worktree at $wt when there is one, and fails on anything else there.
remove_worktree() {
  [[ -e "${wt}" ]] || return 0
  is_our_worktree || fail "${wt} is not a worktree of this clone, so it stays"
  git worktree remove --force "${wt}" || fail "cannot remove ${wt}"
}

if [[ "${cmd}" == remove ]]; then
  remove_worktree
  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    git branch --quiet -D "${branch}" || fail "removed ${wt}, but cannot delete the local branch ${branch}"
  fi
  exit 0
fi

tracking="refs/remotes/origin/${branch}"
git fetch --quiet origin "+refs/heads/${branch}:${tracking}" || fail "cannot fetch ${branch} from origin"
git rev-parse --verify --quiet "${tracking}^{commit}" >/dev/null || fail "cannot read the fetched ${branch}"

remove_worktree
mkdir -p "${root}" || fail "cannot create ${root}"
git worktree add --quiet --track -B "${branch}" "${wt}" "origin/${branch}" ||
  fail "cannot create ${wt} on ${branch}"
printf '%s\n' "${wt}"
