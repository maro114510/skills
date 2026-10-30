#!/usr/bin/env bash
# Tests for pr-context.sh against throwaway Git repositories and a stub `gh` CLI on PATH.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${script_dir}/pr-context.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fail=0
# The user's own hooks and settings must not reach the throwaway repositories, from config files or from git's environment-variable config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

# Stub state files in $STUB_DIR:
# - default: repo default branch, main when absent
# - labels: label lines, printed as gh would after the script's --jq
# - missing: issue numbers that do not exist
# - body.<n>: issue n's body, printed after its title when the call asks for the body
bin="${work}/bin"
mkdir -p "${bin}"
cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
d="${STUB_DIR}"
case " $* " in
*" repo view "*) cat "${d}/default" 2>/dev/null || echo main ;;
*" issue view "*)
  if grep -qx -- "$3" "${d}/missing" 2>/dev/null; then
    echo "GraphQL: Could not resolve to an issue with the number of $3." >&2
    exit 1
  fi
  echo "Title of $3"
  if [[ " $* " == *"body"* ]]; then
    cat "${d}/body.$3" 2>/dev/null || echo
  fi
  ;;
*" label list "*) cat "${d}/labels" 2>/dev/null || true ;;
*) echo "unexpected gh $*" >&2 && exit 1 ;;
esac
STUB
chmod +x "${bin}/gh"

g() { git -C "${clone}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }

# A bare origin whose main has one commit, cloned and checked out on branch feature.
setup() {
  local d
  d="$(mktemp -d "${work}/case.XXXXXX")"
  export STUB_DIR="${d}/stub"
  mkdir -p "${STUB_DIR}"
  git init -q --bare -b main "${d}/origin.git"
  clone="${d}/clone"
  git clone -q "${d}/origin.git" "${clone}" 2>/dev/null
  g commit -q --allow-empty -m init
  g push -q origin main
  g switch -q -c feature
}

n=0
commit() { # message, [file content]
  if [[ $# -gt 1 ]]; then
    n=$((n + 1))
    printf '%s\n' "$2" >"${clone}/file${n}.txt"
    g add -A
  fi
  g commit -q --allow-empty -m "$1"
}

run() {
  run_from . "$@"
}

run_from() { # directory inside the clone, args...
  local dir="$1"
  shift
  out="$(cd "${clone}/${dir}" && PATH="${bin}:${PATH}" bash "${target}" "$@" 2>&1)"
  rc=$?
}

# Lines between the exact header "== <name>" and the next "== " header.
section() {
  awk -v h="== $1" '/^== / { on = ($0 == h); next } on' <<<"${out}"
}

check() { # name, condition result (0 pass)
  if [[ "$2" == 0 ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (exit=${rc})"
    while IFS= read -r line; do echo "    ${line}"; done <<<"${out}"
    fail=1
  fi
}

no_context() { ! grep -q '^== ' <<<"${out}"; }

# 1. A local main and origin/main behind the real origin: only the branch's own commits count.
setup
g switch -q main
commit $'feat: upstream work\n\nCloses #9'
g push -q origin main
g switch -q feature
g reset -q --hard origin/main
stale="$(g rev-parse HEAD~1)"
g update-ref refs/heads/main "${stale}"
g update-ref refs/remotes/origin/main "${stale}"
commit $'feat: mine\n\nCloses #5'
run
[[ "${rc}" == 0 && "$(section issues)" == $'Closes #5\tTitle of 5' ]] && r=0 || r=1
check "stale local and tracking main: issues come only from origin/main..HEAD" "${r}"
[[ "$(section commits)" == *"feat: mine"* && "$(section commits)" != *"upstream work"* ]] && r=0 || r=1
check "stale local and tracking main: commits come only from origin/main..HEAD" "${r}"

# 2. gh-merge-base picks the base for both the context and the create flags.
setup
g push -q origin main:develop
g config branch.feature.gh-merge-base develop
commit 'feat: a' a
run
[[ "${rc}" == 0 && "$(section base)" == "origin/develop" ]] && r=0 || r=1
check "gh-merge-base=develop: base section says develop" "${r}"
[[ "$(section 'create flags')" == "--base develop --draft --assignee @me" ]] && r=0 || r=1
check "gh-merge-base=develop: create flags say develop" "${r}"
[[ "${out}" == "Arguments: lang=ja (default), draft=yes, base=develop"* ]] && r=0 || r=1
check "gh-merge-base=develop: arguments line says develop" "${r}"

# 3. The base argument wins over gh-merge-base, and ready drops --draft.
setup
g push -q origin main:develop
g config branch.feature.gh-merge-base develop
commit 'feat: a' a
run ready base main lang en
[[ "${rc}" == 0 && "$(section 'create flags')" == "--base main --assignee @me" ]] && r=0 || r=1
check "base argument over gh-merge-base, ready: flags have main and no --draft" "${r}"
[[ "${out}" == "Arguments: lang=en (argument), draft=no, base=main"* ]] && r=0 || r=1
check "ready base main lang en: arguments line" "${r}"

# 3b. The language comes from lang.sh: git config when no argument, and an invalid value stops first.
setup
g config skills.lang en
commit 'feat: a' a
run
[[ "${rc}" == 0 && "${out}" == "Arguments: lang=en (git config), draft=yes, base=main"* ]] && r=0 || r=1
check "skills.lang=en and no lang argument: arguments line says en from git config" "${r}"

setup
g config skills.lang en
commit 'feat: a' a
run lang ja
[[ "${rc}" == 0 && "${out}" == "Arguments: lang=ja (argument), draft=yes, base=main"* ]] && r=0 || r=1
check "lang ja with skills.lang=en: the argument wins" "${r}"

setup
g config skills.lang fr
commit 'feat: a' a
run
[[ "${rc}" == 2 && "${out}" == 'Invalid language "fr" from git config skills.lang; use ja or en.' ]] && no_context && r=0 || r=1
check "skills.lang=fr: exit 2 naming the key and value, no context" "${r}"

setup
g config skills.lang fr
commit 'feat: a' a
echo dirty >"${clone}/dirty.txt"
run
[[ "${rc}" == 2 ]] && no_context && r=0 || r=1
check "skills.lang=fr with uncommitted changes: the language stops first, before the commit skill would run" "${r}"

# 4. Stop conditions exit with their own code and print no context.
setup
commit 'feat: a' a
echo dirty >"${clone}/dirty.txt"
run
[[ "${rc}" == 6 ]] && no_context && r=0 || r=1
check "uncommitted changes exit 6 without context" "${r}"

setup
g switch -q main
run
[[ "${rc}" == 4 ]] && no_context && r=0 || r=1
check "on the base branch exits 4 without context" "${r}"

setup
run
[[ "${rc}" == 5 ]] && no_context && r=0 || r=1
check "no commits exits 5 without context" "${r}"

setup
commit $'feat: a\n\nCloses #5'
commit $'fix: b\n\nRelated #5'
run
[[ "${rc}" == 3 && "${out}" == *"CONFLICT #5"* ]] && no_context && r=0 || r=1
check "older Closes with newer Related exits 3 with CONFLICT and no context" "${r}"

setup
commit $'feat: a\n\nCloses #5'
commit $'fix: b\n\nRelated #5'
commit $'feat: c\n\nCloses #7'
run
[[ "${rc}" == 3 && "${out}" == "CONFLICT #5" ]] && r=0 || r=1
check "CONFLICT alongside a clean Closes prints only the CONFLICT line" "${r}"

# 5. Exact-case template lookup prints exactly one template.
setup
mkdir -p "${clone}/.github"
echo "lower template" >"${clone}/.github/pull_request_template.md"
commit 'feat: template' a
run
[[ "${rc}" == 0 && "$(grep -c '^== template' <<<"${out}")" == 1 ]] && r=0 || r=1
check "lowercase template only: exactly one template section" "${r}"
[[ "$(grep '^== template' <<<"${out}")" == "== template .github/pull_request_template.md" && "$(section 'template .github/pull_request_template.md')" == "lower template" ]] && r=0 || r=1
check "lowercase template only: printed with its exact path and content" "${r}"

setup
commit 'feat: a' a
run
[[ "${rc}" == 0 && "$(grep '^== template' <<<"${out}")" == "== template none" ]] && r=0 || r=1
check "no template: template none" "${r}"

# 6. Diff: full when small, lockfiles excluded, omitted when large.
setup
seq 1 2000 >"${clone}/package-lock.json"
echo "visible change" >"${clone}/a.txt"
g add -A
commit 'feat: small change with a big lockfile'
run
diff_out="$(section diff)"
[[ "${rc}" == 0 && "${diff_out}" == *"+visible change"* && "${diff_out}" != *"package-lock.json"* ]] && r=0 || r=1
check "big lockfile and small change: full diff without the lockfile" "${r}"

setup
mkdir -p "${clone}/sub"
seq 1 2000 >"${clone}/package-lock.json"
echo "visible change" >"${clone}/sub/a.txt"
g add -A
commit 'feat: small change with a big root lockfile'
run_from sub
diff_out="$(section diff)"
[[ "${rc}" == 0 && "${diff_out}" == *"+visible change"* && "${diff_out}" != *"package-lock.json"* ]] && r=0 || r=1
check "run from a subdirectory: root lockfile still excluded from the diff" "${r}"

setup
for i in $(seq 1 21); do echo "${i}" >"${clone}/f${i}.txt"; done
g add -A
commit 'feat: many files'
run
diff_out="$(section diff)"
[[ "${rc}" == 0 && "${diff_out}" == "omitted: 21 files"* && "${diff_out}" != *"+++"* ]] && r=0 || r=1
check "21 files: diff omitted" "${r}"

# A footer pointing at an issue gh cannot read stops before any context, naming gh's reason.
setup
echo 5 >"${STUB_DIR}/missing"
commit $'feat: a\n\nCloses #5'
run
[[ "${rc}" == 1 && "${out}" == "ISSUE_LOOKUP_FAILED #5: GraphQL: Could not resolve to an issue with the number of 5." ]] && no_context && r=0 || r=1
check "unreadable footer issue exits 1 with ISSUE_LOOKUP_FAILED and no context" "${r}"

# A valid branch name with shell metacharacters survives pasting the create flags into a shell.
setup
metachar_base='release;next'
g push -q origin "main:${metachar_base}"
commit 'feat: a' a
run base "${metachar_base}"
flags="$(section 'create flags')"
words="$(eval "printf '%s\n' ${flags}" 2>/dev/null)"
[[ "${rc}" == 0 && "${words}" == $'--base\nrelease;next\n--draft\n--assignee\n@me' ]] && r=0 || r=1
check "base with shell metacharacters: create flags parse back to the same base" "${r}"

# 7. Labels arrive as name<TAB>description.
setup
printf 'bug\tSomething is broken\ndocs\t\n' >"${STUB_DIR}/labels"
commit 'feat: a' a
run
[[ "${rc}" == 0 && "$(section labels)" == $'bug\tSomething is broken\ndocs\t' ]] && r=0 || r=1
check "labels: one per line as name<TAB>description" "${r}"

# 8. Invalid arguments exit 2 without context.
setup
commit 'feat: a' a
for args in "ready draft" "base" "lang fr" "bogus"; do
  # shellcheck disable=SC2086 # Split on purpose into tokens.
  run ${args}
  [[ "${rc}" == 2 ]] && no_context
  check "invalid arguments '${args}' exit 2 without context" $?
done

# 9. Manual checks come from the Manual checks list of each issue the branch closes.
setup
cat >"${STUB_DIR}/body.5" <<'BODY'
## Acceptance Criteria

### Target State
Setup works on a new Mac.

### Verification

#### Automated checks
- `make test` passes.

#### Manual checks
- Follow the README on a new Mac.
- Apply the PR on a second Mac and see no diff.

## Notes
- Not a check.
BODY
commit $'feat: a\n\nCloses #5' a
run
[[ "${rc}" == 0 && "$(section 'manual checks')" == $'#5\tFollow the README on a new Mac.\n#5\tApply the PR on a second Mac and see no diff.' ]] && r=0 || r=1
check "closed issue with Manual checks: only that list's items, each with its issue number" "${r}"
[[ "$(section issues)" == $'Closes #5\tTitle of 5' ]] && r=0 || r=1
check "closed issue with Manual checks: issues section keeps one line per issue" "${r}"

setup
printf '### 検証方法\r\n\r\n#### 自動確認\r\n- make test が通る\r\n\r\n#### 手動確認\r\n- [ ] 新しい Mac で README に従う\r\n- [x] 別の Mac で差分が出ない\r\n' >"${STUB_DIR}/body.5"
commit $'feat: a\n\nCloses #5' a
run
[[ "${rc}" == 0 && "$(section 'manual checks')" == $'#5\t新しい Mac で README に従う\n#5\t別の Mac で差分が出ない' ]] && r=0 || r=1
check "Japanese heading, CRLF body, and checkbox items: plain item text without CR or box" "${r}"

setup
printf '#### Manual checks\n- Check on a real device.\n' >"${STUB_DIR}/body.5"
printf '#### Manual checks\n- Check the other issue.\n' >"${STUB_DIR}/body.7"
printf '### Verification\n- make test passes.\n' >"${STUB_DIR}/body.8"
commit $'feat: a\n\nCloses #5\nRelated #7\nCloses #8' a
run
[[ "${rc}" == 0 && "$(section 'manual checks')" == $'#5\tCheck on a real device.' ]] && r=0 || r=1
check "Related issue and issue without Manual checks: neither adds a manual check" "${r}"

setup
commit 'feat: a' a
run
[[ "${rc}" == 0 && "$(grep -c '^== manual checks$' <<<"${out}")" == 1 && -z "$(section 'manual checks')" ]] && r=0 || r=1
check "no issue: an empty manual checks section" "${r}"

exit "${fail}"
