#!/usr/bin/env bash
# Collects what pick-next ranks: the open Issues and pull requests of this clone's origin, and its worktrees.
# It only reads: it never writes to GitHub, a branch, or a worktree.
# Usage: pick.sh [--limit <n>]
#   --limit caps the next and blocked groups; the default is 3. The owner and local groups are never cut.
# Prints one JSON object: repo, viewer, owner, next, nextTotal, blocked, blockedTotal, local.
# pick.jq holds every rule that groups and orders them.
# Reads, in order: every open Issue (pick-issues.graphql), every open pull request (pick-prs.graphql), and
# git worktree list with git status of each worktree. A detached worktree has no branch and is skipped.
# Exit: 0 printed, 1 GitHub or a worktree could not be read, 2 usage error or an origin not on GitHub.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "pick-next: $1" >&2
  echo "Usage: pick.sh [--limit <n>]" >&2
  exit 2
}

fail() {
  echo "pick-next: $1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v gh >/dev/null 2>&1 || usage "gh is required"

limit=3
while [[ $# -gt 0 ]]; do
  [[ "$1" == --limit && "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage "Expected --limit <positive number>, got: $*"
  limit="$2"
  shift 2
done

origin="$(git remote get-url origin 2>/dev/null)" || usage "Not inside a Git repository with an origin remote"
origin_re='github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$'
[[ "${origin}" =~ ${origin_re} ]] || usage "origin is not a GitHub repository: ${origin}"
owner="${BASH_REMATCH[1]}"
repo="${BASH_REMATCH[2]%.git}"

# Prints every node of the connection at .data.repository.$2 across all pages of query file $1, as one array.
read_all() {
  local query
  query="$(<"${dir}/$1")" || fail "cannot read $1"
  gh api graphql --paginate -f query="${query}" -F owner="${owner}" -F repo="${repo}" |
    jq -sc --arg c "$2" '{viewer: (.[0].data.viewer.login // null), nodes: [.[].data.repository[$c].nodes[]]}'
}

issues="$(read_all pick-issues.graphql issues)" || fail "cannot read the open Issues of ${owner}/${repo}"
prs="$(read_all pick-prs.graphql pullRequests)" || fail "cannot read the open pull requests of ${owner}/${repo}"

list="$(git worktree list --porcelain)" || fail "cannot list worktrees"
worktrees="$(awk '/^worktree / { path = substr($0, 10) }
  /^branch refs\/heads\// { print substr($0, 19) "\t" path }' <<<"${list}" |
  while IFS=$'\t' read -r branch path; do
    changes="$(git -C "${path}" status --porcelain 2>/dev/null)" || fail "cannot read the status of ${path}"
    path="$(cd "${path}" && pwd -P)"
    jq -nc --arg path "${path}" --arg branch "${branch}" --argjson dirty "$([[ -n "${changes}" ]] && echo true || echo false)" \
      '{path: $path, branch: $branch, dirty: $dirty}'
  done | jq -sc '.')" || fail "cannot read the worktrees"

# Bodies make the reads large, so they go through stdin rather than arguments, which the OS caps.
printf '%s\n' "${issues}" "${prs}" "${worktrees}" |
  jq -sc --arg repo "${owner}/${repo}" --argjson limit "${limit}" \
    '{repo: $repo, viewer: .[0].viewer, limit: $limit, issues: .[0].nodes, prs: .[1].nodes, worktrees: .[2]}' |
  jq -c -f "${dir}/pick.jq" || fail "cannot rank the facts"
