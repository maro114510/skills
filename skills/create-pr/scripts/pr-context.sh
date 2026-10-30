#!/usr/bin/env bash
# Prints everything create-pr needs to write a PR. Fetches origin/<base>, and otherwise changes no branch, worktree, or GitHub state.
# Usage: pr-context.sh [ready|draft] [base <branch>] [lang <ja|en>]
# Base: the base argument, else git config branch.<current>.gh-merge-base, else the default branch, as create-linked-pr.sh resolves it.
# Output on exit 0: an "Arguments:" line, then sections headed "== <name>": create flags, branch, base, commits, diff stat, diff, template <path|none>, issues, labels.
# A stop prints only its reason: ON_BASE_BRANCH <b>, UNCOMMITTED with git status lines, NO_COMMITS origin/<b>, or CONFLICT #N lines.
# Exit: 0 ok, 1 git or gh failed, 2 bad arguments, 3 CONFLICT, 4 on the base branch, 5 no commits, 6 uncommitted changes.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Valid arguments: ready | draft, base <branch>, lang <ja|en>; e.g. ready base develop lang en" >&2
  exit 2
}

draft="" base="" lang=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  ready)
    [[ "${draft}" == yes ]] && usage
    draft=no
    ;;
  draft)
    [[ "${draft}" == no ]] && usage
    draft=yes
    ;;
  base)
    [[ -n "${2:-}" ]] || usage
    base="$2" && shift
    ;;
  lang)
    [[ "${2:-}" == ja || "${2:-}" == en ]] || usage
    lang="$2" && shift
    ;;
  *) usage ;;
  esac
  shift
done
draft="${draft:-yes}"
lang="${lang:-ja}"

branch="$(git branch --show-current 2>/dev/null)"
if [[ -z "${branch}" ]]; then
  echo "DETACHED_HEAD: check out the branch to open a PR from"
  exit 1
fi

# Same precedence as create-linked-pr.sh, which passes the result to gh pr create.
[[ -n "${base}" ]] || base="$(git config --get "branch.${branch}.gh-merge-base" 2>/dev/null)"
if [[ -z "${base}" ]]; then
  base="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)" || exit 1
fi

if [[ "${branch}" == "${base}" ]]; then
  echo "ON_BASE_BRANCH ${base}"
  exit 4
fi

status="$(git status --porcelain)" || exit 1
if [[ -n "${status}" ]]; then
  echo "UNCOMMITTED"
  printf '%s\n' "${status}"
  exit 6
fi

# A stale origin/<base> puts the base's own commits and their closing footers in the range.
if ! git fetch -q origin "+refs/heads/${base}:refs/remotes/origin/${base}"; then
  echo "FETCH_FAILED origin ${base}"
  exit 1
fi
remote="origin/${base}"

count="$(git rev-list --count "${remote}..HEAD")" || exit 1
if [[ "${count}" == 0 ]]; then
  echo "NO_COMMITS ${remote}"
  exit 5
fi

refs="$(bash "${script_dir}/issue-refs.sh" "${remote}")"
case $? in
0) ;;
3)
  printf '%s\n' "${refs}"
  exit 3
  ;;
*) exit 1 ;;
esac

# Collect everything before printing, so a failure never leaves partial context.
issues=""
while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  n="${line##*#}"
  title="$(gh issue view "${n}" --json title --jq .title 2>/dev/null)" || title="(title unavailable)"
  issues+="${line}"$'\t'"${title}"$'\n'
done <<<"${refs}"

labels="$(gh label list --limit 200 --json name,description --jq '.[] | "\(.name)\t\(.description)"')" || exit 1

commits="$(git log --reverse --format='--- %h%n%B' "${remote}..HEAD")" || exit 1
stat="$(git diff --stat "${remote}...HEAD")" || exit 1

lockfiles=(
  ':(exclude,glob)**/*.lock' ':(exclude,glob)**/*.lockb' ':(exclude,glob)**/package-lock.json'
  ':(exclude,glob)**/npm-shrinkwrap.json' ':(exclude,glob)**/pnpm-lock.yaml' ':(exclude,glob)**/go.sum'
)
read -r files lines < <(git diff --numstat "${remote}...HEAD" -- ':/' "${lockfiles[@]}" |
  awk '{ f++; if ($1 != "-") l += $1 + $2 } END { print f + 0, l + 0 }')
if [[ "${files}" -le 20 && "${lines}" -le 1000 ]]; then
  diff="$(git diff "${remote}...HEAD" -- ':/' "${lockfiles[@]}")" || exit 1
else
  diff="omitted: ${files} files, ${lines} lines exceed 20 files or 1,000 lines without lockfiles; read meaningful files with git diff ${remote}...HEAD -- <path>"
fi

# Exact-case match against the HEAD tree, so a case-insensitive filesystem cannot resolve another candidate.
template=""
tree="$(git ls-tree --full-tree -r --name-only HEAD)" || exit 1
for candidate in .github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md docs/pull_request_template.md PULL_REQUEST_TEMPLATE.md; do
  if grep -Fxq -- "${candidate}" <<<"${tree}"; then
    template="${candidate}"
    break
  fi
done

flags="--base ${base}"
[[ "${draft}" == yes ]] && flags+=" --draft"
flags+=" --assignee @me"

echo "Arguments: lang=${lang}, draft=${draft}, base=${base}"
echo "== create flags"
echo "${flags}"
echo "== branch"
echo "${branch}"
echo "== base"
echo "${remote}"
echo "== commits"
echo "${commits}"
echo "== diff stat"
echo "${stat}"
echo "== diff"
echo "${diff}"
if [[ -n "${template}" ]]; then
  echo "== template ${template}"
  git show "HEAD:${template}"
else
  echo "== template none"
fi
echo "== issues"
printf '%s' "${issues}"
echo "== labels"
[[ -n "${labels}" ]] && echo "${labels}"
exit 0
