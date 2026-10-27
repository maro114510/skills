#!/usr/bin/env bash
# Drive mode's own worktree: a detached HEAD checkout of the PR head under the git common dir, so no repair
# ever edits, resets, or switches the user's checkout.
# Usage: worktree.sh prepare <owner/repo> <pr> --session <token> --branch <head branch> [--head <sha>]
#        worktree.sh remove  <owner/repo> <pr> --session <token>
# prepare fetches the branch into refs/babysit/<owner>/<repo>/<pr>, creates the worktree at
# <git-common-dir>/babysit/wt/<owner>/<repo>/<pr> or resets the existing one to the fetched head with its
# leftover work discarded, and prints {"path":...,"sha":...,"branch":...}. With --head it fails when the
# fetched head is another commit, which means the PR moved since the caller read it.
# The path comes from the arguments alone, and only a worktree of this clone is ever reset.
# Exit: 0 done, 1 GitHub or the worktree could not be used, 2 usage error, 3 the lock is not ours.
set -uo pipefail

# This script runs Git against another worktree, so a repository selected by the caller's environment
# (a hook or an alias exports GIT_DIR) must never reach it: reset --hard would move the caller's HEAD.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

usage() {
  echo "$1" >&2
  echo "Usage: worktree.sh prepare <owner/repo> <pr> --session <token> --branch <head branch> [--head <sha>]" >&2
  echo "       worktree.sh remove <owner/repo> <pr> --session <token>" >&2
  exit 2
}

fail() {
  echo "worktree: $1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v git >/dev/null 2>&1 || usage "git is required"

cmd="${1:-}"
repo="${2:-}"
pr="${3:-}"
case "${cmd}" in
prepare | remove) ;;
*) usage "Unknown command: ${cmd:-<none>}" ;;
esac
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 3
token=""
branch=""
expected=""
while (($# > 0)); do
  case "$1" in
  --session) token="${2:-}" ;;
  --branch) branch="${2:-}" ;;
  --head) expected="${2:-}" ;;
  *) usage "Unknown option: $1" ;;
  esac
  (($# >= 2)) || usage "$1 needs a value"
  shift 2
done
[[ "${token}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
if [[ "${cmd}" == prepare ]]; then
  if [[ -z "${branch}" || "${branch}" == -* ]] || ! git check-ref-format "refs/heads/${branch}"; then
    usage "--branch needs a branch name"
  fi
  [[ -z "${expected}" || "${expected}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || usage "--head needs a full commit sha"
fi

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || usage "Not inside a Git repository"
lowered="$(printf '%s' "${repo}" | tr '[:upper:]' '[:lower:]')"
wt="${common}/babysit/wt/${lowered}/${pr}"

# The lock shows this session owns the pull request, and touching it keeps the heartbeat fresh.
bash "${script_dir}/ledger.sh" touch "${repo}" "${pr}" "${token}" || exit $?

# True when $wt is a worktree of this clone, not just a directory that happens to sit there.
is_our_worktree() {
  local top common_there
  top="$(git -C "${wt}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  common_there="$(git -C "${wt}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$(cd "${top}" && pwd -P)" == "$(cd "${wt}" && pwd -P)" ]] &&
    [[ "$(cd "${common_there}" && pwd -P)" == "$(cd "${common}" && pwd -P)" ]]
}

if [[ "${cmd}" == remove ]]; then
  [[ -e "${wt}" ]] || exit 0
  is_our_worktree || fail "${wt} is not a worktree of this clone, so it stays"
  git worktree remove --force "${wt}" || fail "cannot remove ${wt}"
  exit 0
fi

# A private ref, so neither FETCH_HEAD nor a branch of the user's changes. Git forbids a ref component that
# starts with "." or ends in ".lock", and a repository can be named like that (owner/.github), so "." is encoded.
ref="refs/babysit/${lowered//./%2e}/${pr}"
git fetch --quiet origin "+refs/heads/${branch}:${ref}" || fail "cannot fetch ${branch} from origin"
sha="$(git rev-parse --verify "${ref}^{commit}")" || fail "cannot read the fetched head"
[[ -z "${expected}" || "${expected}" == "${sha}" ]] || fail "the head moved: origin has ${sha}, expected ${expected}"

if [[ -e "${wt}" ]]; then
  is_our_worktree || fail "${wt} is not a worktree of this clone, so it stays"
  git -C "${wt}" reset --quiet --hard "${sha}" || fail "cannot reset ${wt}"
  git -C "${wt}" clean --quiet -ffdx || fail "cannot clean ${wt}"
else
  mkdir -p "$(dirname "${wt}")" || fail "cannot create the parent of ${wt}"
  git worktree add --quiet --detach "${wt}" "${sha}" || fail "cannot create ${wt}"
fi
jq -nc --arg path "${wt}" --arg sha "${sha}" --arg branch "${branch}" '{path: $path, sha: $sha, branch: $branch}'
