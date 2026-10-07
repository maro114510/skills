#!/usr/bin/env bash
# Tests for create-linked-pr.sh, using a stub `gh` CLI on PATH.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${script_dir}/create-linked-pr.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fail=0

# Stub state files in $STUB_DIR:
# - default, base, body: repo default branch, PR base and PR body
# - missing: issue numbers that do not exist
# - open.<n>: open sub-issue count of issue <n>, 0 when absent
# - no_subs: gh too old to know the subIssuesSummary field
# - create_fail, pr_view_fail, link_noop: force that failure
# - refs: linked issue numbers. lag: reads that still return the old list
bin="${work}/bin"
mkdir -p "${bin}"
cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
d="${STUB_DIR}"
printf '%s\n' "$*" >>"${d}/log"
args=" $* "
case "${args}" in
*" repo view "*) cat "${d}/default" 2>/dev/null || echo main ;;
*" issue view "*)
  n="$3"
  if grep -qx -- "${n}" "${d}/missing" 2>/dev/null; then
    echo "GraphQL: Could not resolve to an issue with the number of ${n}." >&2
    exit 1
  fi
  if [[ "${args}" != *subIssuesSummary* ]]; then
    echo "I_${n}"
  elif [[ -f "${d}/no_subs" ]]; then
    echo 'Unknown JSON field: "subIssuesSummary"' >&2
    exit 1
  else
    printf 'I_%s\t%s\n' "${n}" "$(cat "${d}/open.${n}" 2>/dev/null || echo 0)"
  fi
  ;;
*" pr create "*)
  if [[ -f "${d}/create_fail" ]]; then
    echo "a pull request for branch \"x\" into branch \"main\" already exists" >&2
    exit 1
  fi
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body-file" ]]; then cp "$2" "${d}/created_body"; fi
    shift
  done
  echo "https://github.com/o/r/pull/7"
  echo "Warning: 1 uncommitted change" >&2
  ;;
*" api graphql "*)
  issue=""
  for a in "$@"; do [[ "${a}" == i=I_* ]] && issue="${a#i=I_}"; done
  [[ -f "${d}/link_noop" ]] || echo "${issue}" >>"${d}/pending"
  echo '{"data":{"addCloseIssueReferences":{"issue":{"number":'"${issue}"'}}}}'
  ;;
*" pr view "*"closingIssuesReferences"*)
  lag="$(cat "${d}/lag" 2>/dev/null || echo 0)"
  if [[ "${lag}" -gt 0 ]]; then
    echo $((lag - 1)) >"${d}/lag"
  elif [[ -f "${d}/pending" ]]; then
    cat "${d}/pending" >>"${d}/refs"
    rm -f "${d}/pending"
  fi
  cat "${d}/refs" 2>/dev/null
  ;;
*" pr view "*"baseRefName"*) cat "${d}/base" 2>/dev/null || echo main ;;
*" pr view "*"body"*) cat "${d}/body" ;;
*" pr view "*)
  [[ -f "${d}/pr_view_fail" ]] && exit 1
  printf 'PR_7\thttps://github.com/o/r/pull/7\n'
  ;;
*)
  echo "stub gh: unexpected call: $*" >&2
  exit 99
  ;;
esac
STUB
chmod +x "${bin}/gh"

# git stub: current branch from $STUB_DIR/current, gh-merge-base per branch from $STUB_DIR/merge-base.<branch>.
cat >"${bin}/git" <<'STUB'
#!/usr/bin/env bash
d="${STUB_DIR}"
case "$*" in
"branch --show-current") cat "${d}/current" 2>/dev/null || echo feat-x ;;
"config --get branch."*".gh-merge-base")
  b="${3#branch.}"
  cat "${d}/merge-base.${b%.gh-merge-base}" 2>/dev/null || exit 1
  ;;
*) exit 1 ;;
esac
STUB
chmod +x "${bin}/git"

# Fresh stub state with $1 as the PR body.
setup() {
  STUB_DIR="$(mktemp -d "${work}/stub.XXXXXX")"
  export STUB_DIR
  printf '%s\n' "$1" >"${STUB_DIR}/input_body"
}

run() {
  out="$(PATH="${bin}:${PATH}" LINK_POLL_ATTEMPTS=3 LINK_POLL_INTERVAL=0 bash "${target}" "$@" 2>&1)"
  rc=$?
}

create() { run --title "t" --body-file "${STUB_DIR}/input_body" "$@"; }

check() { # name, condition result (0 = ok)
  if [[ "$2" == 0 ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (exit=${rc})"
    while IFS= read -r line; do echo "    ${line}"; done <<<"${out}"
    fail=1
  fi
}

has_line() { grep -qx -- "$1" <<<"${out}"; }
called() { grep -q -- "$1" "${STUB_DIR}/log" 2>/dev/null; }

setup "Just a change."
create
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "https://github.com/o/r/pull/7" || r=1
called "api graphql" && r=1
check "no keyword creates the PR without linking" "${r}"

setup $'Body\n\nCloses #12'
create
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "LINKED #12" || r=1
called "i=I_12" || r=1
called "addCloseIssueReferences(input: {issueId: \$i, pullRequestIds: \[\$p\]})" || r=1
check "single Closes is linked and confirmed" "${r}"

setup $'Fixes #1\ncloses: #2\nRESOLVED #3'
create
r=0
[[ "${rc}" == 0 ]] || r=1
for n in 1 2 3; do has_line "LINKED #${n}" || r=1; done
check "every keyword variant on its own line is linked" "${r}"

setup $'```\nCloses #40\n```\nThis also closes #41 in prose.'
create
r=0
[[ "${rc}" == 0 ]] || r=1
called "api graphql" && r=1
check "fenced and inline keywords are ignored" "${r}"

setup $'Body\nCloses #12'
create --base develop
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "Closes #12" "${STUB_DIR}/created_body" 2>/dev/null || r=1
grep -q "Related" "${STUB_DIR}/created_body" 2>/dev/null && r=1
called "api graphql" && r=1
has_line "NOTICE: base develop is not the default branch main; kept Closes #12 unlinked" || r=1
check "non-default base keeps Closes and skips linking" "${r}"

setup $'Closes #5'
echo 5 >"${STUB_DIR}/missing"
create --base develop
r=0
[[ "${rc}" == 2 ]] || r=1
called "pr create" && r=1
check "non-default base still rejects a missing issue" "${r}"

setup $'Body\nCloses #12'
echo 3 >"${STUB_DIR}/open.12"
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "Related #12" "${STUB_DIR}/created_body" 2>/dev/null || r=1
grep -q "Closes" "${STUB_DIR}/created_body" 2>/dev/null && r=1
called "api graphql" && r=1
has_line "NOTICE: #12 has 3 open sub-issues; rewrote to Related #12" || r=1
check "issue with open sub-issues is rewritten to Related" "${r}"

setup $'Closes #12\nCloses #13'
echo 2 >"${STUB_DIR}/open.12"
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "Related #12" "${STUB_DIR}/created_body" 2>/dev/null || r=1
grep -qx "Closes #13" "${STUB_DIR}/created_body" 2>/dev/null || r=1
called "i=I_12" && r=1
has_line "LINKED #13" || r=1
has_line "LINKED #12" && r=1
check "only the issue with open sub-issues is rewritten" "${r}"

setup $'Closes #12'
echo 1 >"${STUB_DIR}/open.12"
create --base develop
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "Related #12" "${STUB_DIR}/created_body" 2>/dev/null || r=1
called "api graphql" && r=1
check "open sub-issues are rewritten on a non-default base too" "${r}"

setup $'Closes #5'
echo 5 >"${STUB_DIR}/missing"
create
r=0
[[ "${rc}" == 2 ]] || r=1
called "pr create" && r=1
has_line "ISSUE_NOT_FOUND #5: GraphQL: Could not resolve to an issue with the number of 5." || r=1
check "missing issue exits 2 with gh's reason before creating the PR" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/no_subs"
create
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "LINKED #12" || r=1
check "gh without subIssuesSummary still links" "${r}"

setup $'Closes #5'
touch "${STUB_DIR}/no_subs"
echo 5 >"${STUB_DIR}/missing"
create
r=0
[[ "${rc}" == 2 ]] || r=1
has_line "ISSUE_NOT_FOUND #5: GraphQL: Could not resolve to an issue with the number of 5." || r=1
check "gh without subIssuesSummary still rejects a missing issue" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/create_fail"
create
r=0
[[ "${rc}" == 1 ]] || r=1
grep -q "already exists" <<<"${out}" || r=1
called "api graphql" && r=1
check "create failure exits 1 without linking" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/link_noop"
create
r=0
[[ "${rc}" == 3 ]] || r=1
has_line "LINK_MISSING #12" || r=1
has_line "https://github.com/o/r/pull/7" || r=1
check "link that never appears exits 3" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/pr_view_fail"
create
r=0
[[ "${rc}" == 3 ]] || r=1
has_line "LINK_MISSING #12" || r=1
check "unreadable PR after creation exits 3" "${r}"

# The pre-link read and the first poll both miss.
setup $'Closes #12'
echo 2 >"${STUB_DIR}/lag"
create
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "LINKED #12" || r=1
check "link appearing on a later poll succeeds" "${r}"

setup ""
printf 'Closes #12\nCloses #13\n' >"${STUB_DIR}/body"
echo 12 >"${STUB_DIR}/refs"
run --link 7
r=0
[[ "${rc}" == 0 ]] || r=1
called "pr create" && r=1
called "i=I_12" && r=1
called "i=I_13" || r=1
has_line "LINKED #12" || r=1
has_line "LINKED #13" || r=1
check "--link adds only missing references on an existing PR" "${r}"

setup ""
printf 'Closes #12\n' >"${STUB_DIR}/body"
echo develop >"${STUB_DIR}/base"
run --link 7
r=0
[[ "${rc}" == 0 ]] || r=1
called "api graphql" && r=1
grep -q "NOTICE: base develop is not the default branch main" <<<"${out}" || r=1
check "--link on a non-default base links nothing" "${r}"

setup ""
printf 'Closes #12\nCloses #13\n' >"${STUB_DIR}/body"
echo 4 >"${STUB_DIR}/open.12"
run --link 7
r=0
[[ "${rc}" == 0 ]] || r=1
called "i=I_12" && r=1
has_line "NOTICE: #12 has 4 open sub-issues; not linked" || r=1
has_line "LINKED #13" || r=1
check "--link skips an issue with open sub-issues" "${r}"

setup ""
out="$(printf 'From stdin\nCloses #12\n' | PATH="${bin}:${PATH}" LINK_POLL_ATTEMPTS=3 LINK_POLL_INTERVAL=0 bash "${target}" --title t --body-file - 2>&1)"
rc=$?
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "From stdin" "${STUB_DIR}/created_body" 2>/dev/null || r=1
has_line "LINKED #12" || r=1
check "--body-file - reads the body from stdin" "${r}"

setup $'Closes #12'
echo develop >"${STUB_DIR}/merge-base.feat-x"
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -q -- "pr create .*--base develop" "${STUB_DIR}/log" || r=1
grep -qx "Closes #12" "${STUB_DIR}/created_body" 2>/dev/null || r=1
called "api graphql" && r=1
check "gh-merge-base of the current branch is the base" "${r}"

setup $'Closes #12'
echo develop >"${STUB_DIR}/merge-base.feat-y"
create --head feat-y
r=0
[[ "${rc}" == 0 ]] || r=1
grep -q -- "pr create .*--base develop" "${STUB_DIR}/log" || r=1
called "api graphql" && r=1
check "gh-merge-base is read from the --head branch" "${r}"

setup $'Closes #12'
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -q -- "pr create .*--base main" "${STUB_DIR}/log" || r=1
check "default branch is passed as --base when nothing is configured" "${r}"

setup ""
run --title "t"
r=0
[[ "${rc}" == 2 ]] || r=1
check "missing --body-file exits 2" "${r}"

exit "${fail}"
