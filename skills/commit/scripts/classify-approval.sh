#!/usr/bin/env bash
# Decides whether a change needs human approval before it is committed or pushed. The only approval rules:
# commit's Step 6 runs --staged, and the range mode classifies base..HEAD before push. implement keeps no rules
# of its own.
# Usage: classify-approval.sh --staged [--removed-test] [--require <reason>]...
#        classify-approval.sh [<base>] [--require <reason>]...
# Run from inside the repository. --staged classifies the staged diff. Otherwise the non-merge commits in
# <base>..HEAD are classified, starting at the merge base of <base>, default origin/HEAD, with HEAD; uncommitted
# changes are ignored.
#
# | Condition              | Needs approval when |
# |------------------------|---------------------|
# | release or CI config   | .agents/skills.toml, a path under .github/workflows/ or .claude-plugin/, or a Makefile, cliff.toml, package.json, Cargo.toml, or pyproject.toml at any depth, changes |
# | configured path        | A path matching `[commit.approval] paths` changes |
# | large diff             | More than 20 files or more than 1,000 changed lines |
# | deleted file           | A file is deleted rather than renamed, unless it matches `[paths] tests` and a Removed-Test trailer covers it: --removed-test for --staged, a trailer on a commit in the range otherwise |
# | --require <reason>     | Always; the caller's own finding, such as a critical decision in implement's decision log |
#
# In the range mode a path counts when any commit in the range changes it, even if a later one reverts it; size
# and deletions are measured on the net diff.
# Any Removed-Test trailer covers every deleted test file; gate-tests.sh checks that the trailers name the cases.
# The config is read from the index for --staged and from HEAD otherwise, never from the working tree, and a
# change to it always needs approval, so an edit that drops a configured path cannot hide a change under it.
#
# Config: .agents/skills.toml at the repository root, read with Python 3.11+ tomllib; a config error is exit 2.
# `[commit.approval] paths` holds Git glob pathspecs, as a string or an array, and only adds to the conditions above.
# No key can remove or relax a built-in condition: any other key in [commit.approval] is ignored with a warning.
# `[paths] tests` is read for the deleted-file exception.
#
# Prints one `reason: <condition>: <detail>` line per hit, then `approval: required` or `approval: not-required`.
#
# | Exit | Meaning |
# |------|---------|
# | 0    | Approval not required |
# | 10   | Approval required |
# | 2    | Usage, repository, or config error; callers treat it as approval required |
set -uo pipefail

die() {
  echo "classify-approval: $1" >&2
  exit 2
}

usage="Usage: classify-approval.sh --staged [--removed-test] [--require <reason>]... | [<base>] [--require <reason>]..."
staged=""
removed_test=""
base_ref=""
reasons=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --staged) staged=1 ;;
  --removed-test) removed_test=1 ;;
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
[[ -n "${staged}" || -z "${removed_test}" ]] || die "--removed-test applies only to --staged"

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
  if [[ -n "$(git log --no-merges --format='%(trailers:key=Removed-Test,valueonly)' "${base}..HEAD")" ]]; then
    removed_test=1
  fi
fi

builtin=(
  ':(glob).agents/skills.toml'
  ':(glob).github/workflows/**'
  ':(glob).claude-plugin/**'
  ':(glob)**/Makefile'
  ':(glob)**/cliff.toml'
  ':(glob)**/package.json'
  ':(glob)**/Cargo.toml'
  ':(glob)**/pyproject.toml'
)
configured=()
tests=()

read -r -d '' PY <<'EOF'
import sys

def die(msg):
    print("classify-approval: " + msg, file=sys.stderr)
    sys.exit(2)

try:
    import tomllib
except ImportError:
    die("reading .agents/skills.toml needs Python 3.11 or later")
try:
    with open(sys.argv[1], "rb") as f:
        doc = tomllib.load(f)
except (OSError, tomllib.TOMLDecodeError) as e:
    die(f"cannot read .agents/skills.toml: {e}")

def globs(table, key, name):
    v = table.get(key)
    if v is None:
        return []
    if isinstance(v, str):
        v = [v]
    if not isinstance(v, list) or not all(isinstance(p, str) and p and "\0" not in p for p in v):
        die(f"{name} must be a string or an array of non-empty strings")
    return v

def table(parent, key, name):
    v = parent.get(key, {})
    if not isinstance(v, dict):
        die(f"[{name}] must be a table")
    return v

approval = table(table(doc, "commit", "commit"), "approval", "commit.approval")
for key in approval:
    if key != "paths":
        print(f"classify-approval: warning: [commit.approval] {key} is ignored; config can only add paths",
              file=sys.stderr)
out = [("approval", p) for p in globs(approval, "paths", "commit.approval.paths")]
out += [("tests", p) for p in globs(table(doc, "paths", "paths"), "tests", "paths.tests")]
sys.stdout.write("".join(f"{k}\0{v}\0" for k, v in out))
EOF

work="$(mktemp -d "${TMPDIR:-/tmp}/classify-approval.XXXXXX")" || die "Cannot create a temporary directory"
# shellcheck disable=SC2064 # expand the path now
trap "rm -rf '${work}'" EXIT

# The config comes from the same tree as the diff, so an unstaged or uncommitted edit to it changes nothing.
if [[ -n "${staged}" ]]; then
  config_rev=":.agents/skills.toml"
else
  config_rev="HEAD:.agents/skills.toml"
fi
if git cat-file -e "${config_rev}" 2>/dev/null; then
  command -v python3 >/dev/null 2>&1 || die "reading .agents/skills.toml needs python3"
  git cat-file blob "${config_rev}" >"${work}/skills.toml" || die "Cannot read ${config_rev}"
  python3 -c "${PY}" "${work}/skills.toml" >"${work}/config" || exit 2
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    case "${key}" in
    approval) configured+=(":(glob)${value}") ;;
    tests) tests+=(":(glob)${value}") ;;
    esac
  done <"${work}/config"
fi

# Writes to ${work}/out, NUL-separated and deduplicated, every path the change touches that matches the
# pathspecs in $@. A pathspec git rejects is a config error.
touched() {
  if [[ -n "${staged}" ]]; then
    git -c core.quotePath=false diff --cached --no-ext-diff --no-renames --name-only -z -- "$@"
  else
    git -c core.quotePath=false log --no-merges --format= --no-renames --name-only -z "${base}..HEAD" -- "$@"
  fi >"${work}/raw" || die "git rejected a pathspec among: $*"
  tr -s '\0' <"${work}/raw" | LC_ALL=C sort -zu >"${work}/out"
}

# Writes to ${work}/out the paths the change deletes, not counting renames, that match the pathspecs in $@,
# NUL-separated.
deleted() {
  git -c core.quotePath=false diff "${range[@]}" --no-ext-diff -M --diff-filter=D --name-only -z -- "$@" \
    >"${work}/out" || die "git rejected a pathspec among: $*"
}

touched "${builtin[@]}"
while IFS= read -r -d '' path; do
  reasons+=("release or CI config: ${path}")
done <"${work}/out"

if [[ ${#configured[@]} -gt 0 ]]; then
  touched "${configured[@]}"
  while IFS= read -r -d '' path; do
    reasons+=("configured path: ${path}")
  done <"${work}/out"
fi

git diff "${range[@]}" --no-ext-diff -M --numstat >"${work}/numstat" || die "Cannot read the diff"
read -r files lines < <(awk -F '\t' '{ n++; if ($1 != "-") l += $1 + $2 } END { print n + 0, l + 0 }' "${work}/numstat")
if [[ "${files}" -gt 20 || "${lines}" -gt 1000 ]]; then
  reasons+=("large diff: ${files} files, ${lines} changed lines (limit 20 files, 1000 lines)")
fi

covered=()
if [[ -n "${removed_test}" && ${#tests[@]} -gt 0 ]]; then
  deleted "${tests[@]}"
  while IFS= read -r -d '' path; do
    covered+=("${path}")
  done <"${work}/out"
fi
deleted
while IFS= read -r -d '' path; do
  hit=""
  for c in ${covered[@]+"${covered[@]}"}; do
    [[ "${c}" == "${path}" ]] && hit=1
  done
  [[ -n "${hit}" ]] || reasons+=("deleted file: ${path}")
done <"${work}/out"

if [[ ${#reasons[@]} -eq 0 ]]; then
  echo "approval: not-required"
  exit 0
fi
printf 'reason: %s\n' "${reasons[@]}"
echo "approval: required"
exit 10
