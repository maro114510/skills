#!/usr/bin/env bash
# oe brief
#
# Builds the brief that orchestrate-epic hands to an Owner or a Verifier, so the orchestrator never assembles one by hand.
#
# Usage
#
#   oe brief owner <owner/repo> <issue-number> <worktree> [<reason>]
#   oe brief verifier <owner/repo> <issue-number> <worktree>
#
# - <worktree> is the path oe worktree add printed: the Issue branch for an Owner, its head detached for a Verifier.
# - <reason> is the reason oe ready gave for starting the Owner.
#
# | Role | Checks | Writes | Prints |
# |---|---|---|---|
# | owner | The worktree is on the Issue branch | Nothing | repo, issue, base, worktree, and the reason |
# | verifier | The worktree HEAD is detached at the head of the Issue branch's open PR, and fewer than max_verifier_starts pending verify statuses are on it | A pending verify_context status on that SHA | repo, issue, sha, base, worktree |
#
# - The pending status is the Verifier start that oe ready counts, so a Verifier given a brief is always counted.
# - The status is written before the brief is printed, so a failed write starts no Verifier.
# - The brief is one line, as pr-owner and pr-verify read it.
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The brief was printed | verifier: the pending status |
# | 1 | A GitHub read or write failed | Nothing |
# | 2 | The arguments are invalid, or the worktree is not in the state the role needs | Nothing |
# | 4 | verifier: the branch has no open PR, its head is not the worktree HEAD, or the start limit is reached | Nothing |
set -uo pipefail

# A repository selected by the caller's environment must never reach these commands.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe brief owner <owner/repo> <issue-number> <worktree> [<reason>]" >&2
  echo "       oe brief verifier <owner/repo> <issue-number> <worktree>" >&2
  exit 2
}

fail() {
  echo "oe brief: $1" >&2
  exit 1
}

refuse() {
  echo "oe brief: $1, so nothing was written" >&2
  exit 4
}

role="${1:-}"
case "${role}" in
owner) [[ $# -eq 4 || $# -eq 5 ]] || usage "Expected owner <owner/repo> <issue-number> <worktree> [<reason>]" ;;
verifier) [[ $# -eq 4 ]] || usage "Expected verifier <owner/repo> <issue-number> <worktree>" ;;
*) usage "Unknown role: ${role}" ;;
esac
[[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $2"
[[ "$3" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $3"
repo="$2"
n="$3"
wt="$4"
reason="${5:-}"
branch="${branch_prefix}${n}"

top="$(git -C "${wt}" rev-parse --show-toplevel 2>/dev/null)" || usage "Not a Git worktree: ${wt}"
[[ "$(cd "${top}" && pwd -P)" == "$(cd "${wt}" && pwd -P)" ]] || usage "Not the top of a worktree: ${wt}"
current="$(git -C "${wt}" symbolic-ref -q --short HEAD)"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

base="$(gh api "repos/${repo}" --jq '.default_branch' 2>"${err}")" ||
  fail "repository read for ${repo} failed: $(head -n1 "${err}")"
[[ -n "${base}" ]] || fail "repository read for ${repo} named no default branch"

if [[ "${role}" == owner ]]; then
  [[ "${current}" == "${branch}" ]] || usage "${wt} is on ${current:-a detached HEAD}, not ${branch}"
  if [[ -n "${reason}" ]]; then
    printf 'repo %s issue %s base %s worktree %s reason %s\n' "${repo}" "${n}" "${base}" "${wt}" "${reason}"
  else
    printf 'repo %s issue %s base %s worktree %s\n' "${repo}" "${n}" "${base}" "${wt}"
  fi
  exit 0
fi

[[ -z "${current}" ]] || usage "${wt} is on ${current}; a Verifier needs a detached HEAD"
sha="$(git -C "${wt}" rev-parse HEAD)" || usage "Cannot read the HEAD of ${wt}"

found="$(open_pr_head "${repo}" "${branch}" 2>"${err}")" || fail "$(head -n1 "${err}")"
pr="${found%%$'\t'*}"
head="${found#*$'\t'}"

[[ -n "${pr}" ]] || refuse "${branch} has no open pull request on ${repo}"
[[ "${head}" == "${sha}" ]] || refuse "PR #${pr} head is ${head}, not the worktree HEAD ${sha}"

starts="$(gh api "repos/${repo}/commits/${sha}/statuses?per_page=100" --paginate \
  --jq '[.[] | select(.context == "'"${verify_context}"'" and .state == "pending")] | length' 2>"${err}")" ||
  fail "status read for ${sha} failed: $(head -n1 "${err}")"
total=0
while read -r page; do
  [[ -n "${page}" ]] || continue
  [[ "${page}" =~ ^[0-9]+$ ]] || fail "status read for ${sha} unreadable"
  total=$((total + page))
done <<<"${starts}"
((total < max_verifier_starts)) || refuse "the Verifier already started ${total} times on ${sha}"

gh api -X POST "repos/${repo}/statuses/${sha}" -f state=pending -f context="${verify_context}" \
  -f description="Verifier started on PR #${pr}" --jq '.state' >/dev/null 2>"${err}" ||
  fail "writing the pending ${verify_context} status on ${sha} failed, so no Verifier may start: $(head -n1 "${err}")"
printf 'repo %s issue %s sha %s base %s worktree %s\n' "${repo}" "${n}" "${sha}" "${base}" "${wt}"
