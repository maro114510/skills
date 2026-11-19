#!/usr/bin/env bash
# Takes the Lock on a GitHub Issue: its fixed-name branch feat/issue-<N> on origin, the name oe claim creates.
# The branch is created at the head of <base-branch> only when it is absent, in one push that fails when it exists,
# so one Issue has one branch at a time. When the branch exists, nothing is written and the exit code says why.
# Usage: lock.sh <issue> <base-branch>
# Run from inside the repository. Stdout holds one line, `locked<TAB><branch>`, or the lines of the stop:
# `branch=<name>`, then `worktree=<path>` when a worktree of this clone holds the branch.
# Exit: 0 locked, 10 the branch exists, its pull request is merged, and the Issue is open,
# 20 the branch exists, so the Issue is Busy, 2 error.
set -uo pipefail

issue="${1:-}"
base="${2:-}"

die() {
  echo "$1" >&2
  exit 2
}

[[ "${issue}" =~ ^[1-9][0-9]*$ ]] || die "Invalid issue number: ${issue:-<none>}"
[[ -n "${base}" ]] || die "Missing base branch"
git rev-parse --git-dir >/dev/null 2>&1 || die "Not inside a Git repository"

branch="feat/issue-${issue}"
ref="refs/heads/${branch}"

git fetch -q origin "${base}" 2>/dev/null || die "Fetching ${base} from origin failed"

# Only a push that creates the branch counts as taking the Lock. Git reports a push of the commit a branch already
# points to as up to date and exits 0, so the exit code cannot tell this run from one that created the branch at the
# same head a moment earlier, as oe claim or a second run does. The porcelain flag `*` marks a created ref.
pushed="$(git push --porcelain --force-with-lease="${ref}:" origin "FETCH_HEAD:${ref}" 2>/dev/null)"
if [[ "${pushed}" == *$'\n*\t'* ]]; then
  printf 'locked\t%s\n' "${branch}"
  exit 0
fi

# Not created by this run: tell an existing branch from an unreachable origin or any other cause.
head_sha="$(git ls-remote --heads origin "${ref}" 2>/dev/null | cut -f1)" || die "Reading ${branch} from origin failed"
[[ -n "${head_sha}" ]] || die "Creating ${branch} on origin failed"

echo "branch=${branch}"
worktree="$(git worktree list --porcelain | awk -v ref="${ref}" '
  $1 == "worktree" { path = substr($0, 10) }
  $1 == "branch" && $2 == ref { print path; exit }')"
[[ -z "${worktree}" ]] || echo "worktree=${worktree}"

# A merged pull request ends the unit only when it merged the branch as it stands now: GitHub keeps a merged pull
# request under its branch name after the branch is deleted and created again, and that branch is held by a new run.
# A squash merge leaves the Issue open when the unit did not finish it; the caller decides what comes next.
merged="$(gh pr list --head "${branch}" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null)" || die "Reading pull requests of ${branch} failed"
if grep -qx "${head_sha}" <<<"${merged}"; then
  state="$(gh issue view "${issue}" --json state --jq .state 2>/dev/null)" || die "Reading Issue ${issue} failed"
  [[ "${state}" == OPEN ]] && exit 10
fi
exit 20
