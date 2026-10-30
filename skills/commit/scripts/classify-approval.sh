#!/usr/bin/env bash
# Decides whether a change needs human approval before it is committed or pushed. The only approval rules:
# commit's Step 6 runs --staged, and the range mode classifies base..HEAD before push. implement keeps no rules
# of its own.
# Usage: classify-approval.sh --staged [--require <reason>]...
#        classify-approval.sh [<base>] [--require <reason>]...
# Run from inside the repository. --staged classifies the staged diff. Otherwise the non-merge commits in
# <base>..HEAD are classified, starting at the merge base of <base>, default origin/HEAD, with HEAD; uncommitted
# changes are ignored.
#
# | Condition              | Needs approval when |
# |------------------------|---------------------|
# | release or CI config   | A path under .github/workflows/ or .claude-plugin/, or a Makefile, cliff.toml, package.json, Cargo.toml, or pyproject.toml at any depth, changes |
# | large diff             | More than 20 files or more than 1,000 changed lines |
# | deleted file           | A file is deleted rather than renamed |
# | --require <reason>     | Always; the caller's own finding, such as a critical decision in implement's decision log |
#
# In the range mode a path counts when any commit in the range changes it, even if a later one reverts it; size
# and deletions are measured on the net diff.
# No repository file or setting can add, remove, or relax a condition.
#
# Prints one `reason: <condition>: <detail>` line per hit, then `approval: required` or `approval: not-required`.
#
# | Exit | Meaning |
# |------|---------|
# | 0    | Approval not required |
# | 10   | Approval required |
# | 2    | Usage or repository error; callers treat it as approval required |
set -uo pipefail

die() {
  echo "classify-approval: $1" >&2
  exit 2
}

usage="Usage: classify-approval.sh --staged [--require <reason>]... | [<base>] [--require <reason>]..."
staged=""
base_ref=""
reasons=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --staged) staged=1 ;;
  --require)
    [[ $# -ge 2 && -n "$2" ]] || die "--require needs a reason"
    reasons+=("$2")
    shift
    ;;
  -*) die "${usage}" ;;
  *)
    [[ -z "${base_ref}" ]] || die "${usage}"
    base_ref="$1"
    ;;
  esac
  shift
done
[[ -z "${staged}" || -z "${base_ref}" ]] || die "${usage}"

top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a Git repository"
cd "${top}" || die "Cannot enter ${top}"

if [[ -n "${staged}" ]]; then
  range=(--cached)
else
  base_ref="${base_ref:-origin/HEAD}"
  git rev-parse -q --verify "${base_ref}^{commit}" >/dev/null || die "Unknown base: ${base_ref}"
  git rev-parse -q --verify 'HEAD^{commit}' >/dev/null || die "HEAD has no commit"
  base="$(git merge-base "${base_ref}" HEAD)" || die "No merge base between ${base_ref} and HEAD"
  range=("${base}" HEAD)
fi

builtin=(
  ':(glob).github/workflows/**'
  ':(glob).claude-plugin/**'
  ':(glob)**/Makefile'
  ':(glob)**/cliff.toml'
  ':(glob)**/package.json'
  ':(glob)**/Cargo.toml'
  ':(glob)**/pyproject.toml'
)

work="$(mktemp -d "${TMPDIR:-/tmp}/classify-approval.XXXXXX")" || die "Cannot create a temporary directory"
# shellcheck disable=SC2064 # expand the path now
trap "rm -rf '${work}'" EXIT

# Writes to ${work}/out, NUL-separated and deduplicated, every path the change touches that matches the
# pathspecs in $@.
touched() {
  if [[ -n "${staged}" ]]; then
    git -c core.quotePath=false diff --cached --no-ext-diff --no-renames --name-only -z -- "$@"
  else
    git -c core.quotePath=false log --no-merges --format= --no-renames --name-only -z "${base}..HEAD" -- "$@"
  fi >"${work}/raw" || die "git rejected a pathspec among: $*"
  tr -s '\0' <"${work}/raw" | LC_ALL=C sort -zu >"${work}/out"
}

touched "${builtin[@]}"
while IFS= read -r -d '' path; do
  reasons+=("release or CI config: ${path}")
done <"${work}/out"

git diff "${range[@]}" --no-ext-diff -M --numstat >"${work}/numstat" || die "Cannot read the diff"
read -r files lines < <(awk -F '\t' '{ n++; if ($1 != "-") l += $1 + $2 } END { print n + 0, l + 0 }' "${work}/numstat")
if [[ "${files}" -gt 20 || "${lines}" -gt 1000 ]]; then
  reasons+=("large diff: ${files} files, ${lines} changed lines (limit 20 files, 1000 lines)")
fi

# Renames are not deletions.
git -c core.quotePath=false diff "${range[@]}" --no-ext-diff -M --diff-filter=D --name-only -z >"${work}/out" ||
  die "Cannot read the diff"
while IFS= read -r -d '' path; do
  reasons+=("deleted file: ${path}")
done <"${work}/out"

if [[ ${#reasons[@]} -eq 0 ]]; then
  echo "approval: not-required"
  exit 0
fi
printf 'reason: %s\n' "${reasons[@]}"
echo "approval: required"
exit 10
