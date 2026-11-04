#!/usr/bin/env bash
# Resolves a GitHub pull request or Issue URL to its local worktrees, branches, and current state.
# It only reads: it never creates, switches, or removes a worktree or branch.
# Usage: locate.sh <https://github.com/<owner>/<repo>/(pull|issues)/<n>>
# Prints one JSON line:
#   kind, repo, number, url, state, branches, worktrees ([{path, branch}]), and match (one, none, many).
#   A pull request adds isDraft, isCrossRepository, unresolvedThreads, failingChecks ([{name, url}]), pendingChecks.
#   An Issue adds stateReason.
# Candidate branches: a pull request's head branch; for an Issue, the branches GitHub links to it in this
# repository. A fork's branch never matches a worktree here.
# Pull request state comes from babysit's pr-state.sh, which pages every thread and check; LOCATE_PR_STATE
# overrides its path.
# Exit: 0 printed, 1 GitHub could not be read, 2 usage error, 3 the URL belongs to another repository than origin.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pr_state="${LOCATE_PR_STATE:-${script_dir}/../../babysit/scripts/pr-state.sh}"

usage() {
  echo "locate: $1" >&2
  echo "Usage: locate.sh <https://github.com/<owner>/<repo>/(pull|issues)/<n>>" >&2
  exit 2
}

fail() {
  echo "locate: $1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || usage "jq is required"
[[ $# -eq 1 ]] || usage "Expected exactly one URL"

url_re='^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(pull|issues)/([1-9][0-9]*)([/?#].*)?$'
[[ "$1" =~ ${url_re} ]] || usage "Not a pull request or Issue URL: $1"
repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
kind="${BASH_REMATCH[3]}"
num="${BASH_REMATCH[4]}"

origin="$(git remote get-url origin 2>/dev/null)" || usage "Not inside a Git repository with an origin remote"
origin_re='github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$'
origin_repo=""
if [[ "${origin}" =~ ${origin_re} ]]; then
  origin_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
fi
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [[ "$(lower "${origin_repo}")" != "$(lower "${repo}")" ]]; then
  echo "locate: ${repo} is not this clone's origin (${origin}); run it from a clone of ${repo}" >&2
  exit 3
fi

if [[ "${kind}" == pull ]]; then
  [[ -r "${pr_state}" ]] || fail "babysit's pr-state.sh is required at ${pr_state}"
  state="$(bash "${pr_state}" "${repo}" "${num}")" || fail "cannot read pull request ${repo}#${num}"
  branches="$(jq -r '.headRef' <<<"${state}")" || fail "unexpected pull request state"
  info="$(jq -c '{kind: "pr", repo, number, url, state, isDraft, isCrossRepository,
    unresolvedThreads: ([.threads[] | select(.isResolved | not)] | length),
    failingChecks: [.checks[] | select(.status == "failed" or .status == "action") | {name, url}],
    pendingChecks: ([.checks[] | select(.status == "pending")] | length)}' <<<"${state}")" ||
    fail "unexpected pull request state"
  # A fork's branch only shares its name with any branch here, so no local worktree holds it.
  matchable="$(jq -r 'if .isCrossRepository then "" else .headRef end' <<<"${state}")"
else
  command -v gh >/dev/null 2>&1 || fail "gh is required"
  state="$(gh issue view "${num}" -R "${repo}" --json state,stateReason,url)" || fail "cannot read Issue ${repo}#${num}"
  linked="$(gh issue develop --list "${num}" -R "${repo}")" || fail "cannot list the branches linked to ${repo}#${num}"
  info="$(jq -c --arg repo "${repo}" --argjson n "${num}" \
    '{kind: "issue", repo: $repo, number: $n, url, state, stateReason}' <<<"${state}")" ||
    fail "unexpected Issue state"
  # A linked branch can live in a fork; only one in this repository can be checked out here.
  branches="$(awk -F '\t' -v prefix="https://github.com/$(lower "${repo}")/tree/" \
    'index(tolower($2), prefix) == 1 { print $1 }' <<<"${linked}" | LC_ALL=C sort -u)"
  matchable="${branches}"
fi

# Every worktree of this clone, as <branch>\t<path>; a detached worktree has no branch line and never matches.
all_worktrees="$(git worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10) }
  /^branch refs\/heads\// { print substr($0, 19) "\t" path }')"
worktrees="$(while IFS= read -r b; do
  [[ -n "${b}" ]] || continue
  path="$(awk -F '\t' -v b="${b}" '$1 == b { print $2; exit }' <<<"${all_worktrees}")"
  [[ -n "${path}" ]] || continue
  path="$(cd "${path}" 2>/dev/null && pwd -P || printf '%s' "${path}")"
  jq -nc --arg path "${path}" --arg branch "${b}" '{path: $path, branch: $branch}'
done <<<"${matchable}" | jq -sc '.')"

jq -c --argjson worktrees "${worktrees}" --arg branches "${branches}" '
  . + {branches: ($branches | split("\n") | map(select(. != ""))), worktrees: $worktrees,
       match: (if ($worktrees | length) == 0 then "none" elif ($worktrees | length) == 1 then "one" else "many" end)}' \
  <<<"${info}"
