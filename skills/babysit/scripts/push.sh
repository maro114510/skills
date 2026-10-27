#!/usr/bin/env bash
# Drive mode's only way to push. It asks the gate about the worktree's HEAD, lists that sha in the ledger,
# pushes it as a plain fast-forward, and only then counts one round and one repair per --check key.
# Usage: push.sh <owner/repo> <pr> --session <token> --worktree <path> --start <sha> --branch <head branch>
#                [--check <check key>]...
# Prints one JSON line: the gate's verdict when it does not allow, otherwise {"pushed":true|false,...}.
# Never forces, and never pushes anything the gate has not judged: the command it runs is the command it gave the gate.
# Test hooks BABYSIT_PR_STATE and BABYSIT_REMOTE_BASE reach the gate.
# Exit: 0 pushed, 1 the push failed, 2 usage error, 3 the lock is not ours,
# 10 the gate parked it, 11 the gate refused it. Only an exit of 1 or 3 with "pushed":true in the JSON line
# means the push went out and the ledger count failed; every other exit but 0 means nothing went out.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

usage() {
  echo "$1" >&2
  echo "Usage: push.sh <owner/repo> <pr> --session <token> --worktree <path> --start <sha> --branch <head branch> [--check <check key>]..." >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v git >/dev/null 2>&1 || usage "git is required"

repo="${1:-}"
pr="${2:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 2
token=""
worktree=""
start=""
branch=""
checks=()
while (($# > 0)); do
  case "$1" in
  --session) token="${2:-}" ;;
  --worktree) worktree="${2:-}" ;;
  --start) start="${2:-}" ;;
  --branch) branch="${2:-}" ;;
  --check) checks+=("${2:-}") ;;
  *) usage "Unknown option: $1" ;;
  esac
  (($# >= 2)) || usage "$1 needs a value"
  shift 2
done
[[ "${token}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
[[ -n "${worktree}" && -d "${worktree}" ]] || usage "--worktree needs an existing directory"
[[ "${start}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || usage "--start needs a full commit sha"
if [[ -z "${branch}" || "${branch}" == -* ]] || ! git check-ref-format "refs/heads/${branch}"; then
  usage "--branch needs a branch name"
fi
cd "${worktree}" || usage "Cannot enter the worktree"
sha="$(git rev-parse --verify -q 'HEAD^{commit}')" || usage "Not a Git worktree with a commit: ${worktree}"

cmd=(git push origin "${sha}:refs/heads/${branch}")

verdict="$(bash "${script_dir}/gate.sh" push "${repo}" "${pr}" --session "${token}" --worktree "${worktree}" \
  --start "${start}" -- "${cmd[@]}")"
code=$?
if ((code != 0)); then
  [[ -z "${verdict}" ]] || printf '%s\n' "${verdict}"
  exit "${code}"
fi

# The sha is listed before the push, so wait never raises the agent's own head change, and the lock is rechecked.
bash "${script_dir}/ledger.sh" own-push "${repo}" "${pr}" "${token}" "${sha}" || exit $?

if ! "${cmd[@]}" >&2; then
  jq -nc --arg sha "${sha}" --arg branch "${branch}" '{pushed: false, sha: $sha, branch: $branch, reason: "git push failed"}'
  exit 1
fi

# The check keys follow the checks array; with none, the call counts the round alone.
bash "${script_dir}/ledger.sh" count-push "${repo}" "${pr}" "${token}" ${checks[@]+"${checks[@]}"}
count_code=$?
if ((count_code != 0)); then
  # The push is out, so the caller must not read this as a failed push; 3 still means the lock is gone.
  jq -nc --arg sha "${sha}" --arg branch "${branch}" \
    '{pushed: true, sha: $sha, branch: $branch, error: "the push went out but the ledger count failed"}'
  ((count_code == 3)) && exit 3
  exit 1
fi
rounds="$(bash "${script_dir}/ledger.sh" show "${repo}" "${pr}" | jq -r '.rounds // 0')"
jq -nc --arg sha "${sha}" --arg branch "${branch}" --argjson rounds "${rounds}" \
  '{pushed: true, sha: $sha, branch: $branch, rounds: $rounds}'
