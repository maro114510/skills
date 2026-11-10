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
# - subs_fail: reading the issue fails for a reason other than its absence
# - created_body, edited_body: body sent when creating or editing the PR
# - meta: the call that set the PR's assignees
# - create_fail, pr_view_fail, link_noop, web_fail, meta_fail, user_fail: force that failure
# - refs: linked issue numbers. lag: reads that still return the old list
# - gql_exhausted: every GraphQL call fails on the rate limit
# The script must use REST wherever REST can do the job, so a GraphQL-only subcommand that has a REST equivalent always fails here.
bin="${work}/bin"
mkdir -p "${bin}"
cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
d="${STUB_DIR}"
printf '%s\n' "$*" >>"${d}/log"
args=" $* "
limited() {
  echo "GraphQL: API rate limit already exceeded for user ID 1." >&2
  exit 1
}
body_arg() { # destination file; copies the file named by a body=@<path> argument
  local a
  for a in "${@:2}"; do [[ "${a}" == body=@* ]] && cp "${a#body=@}" "$1"; done
  return 0
}
case "${args}" in
*" api graphql "*)
  [[ -f "${d}/gql_exhausted" ]] && limited
  issue=""
  for a in "$@"; do [[ "${a}" == i=I_* ]] && issue="${a#i=I_}"; done
  [[ -f "${d}/link_noop" ]] || echo "${issue}" >>"${d}/pending"
  echo '{"data":{"addCloseIssueReferences":{"issue":{"number":'"${issue}"'}}}}'
  ;;
*" pr view "*"--web"*)
  [[ -f "${d}/web_fail" ]] && {
    echo "could not open a browser" >&2
    exit 1
  }
  ;;
*" pr view "*"closingIssuesReferences"*)
  [[ -f "${d}/gql_exhausted" ]] && limited
  lag="$(cat "${d}/lag" 2>/dev/null || echo 0)"
  if [[ "${lag}" -gt 0 ]]; then
    echo $((lag - 1)) >"${d}/lag"
  elif [[ -f "${d}/pending" ]]; then
    cat "${d}/pending" >>"${d}/refs"
    rm -f "${d}/pending"
  fi
  cat "${d}/refs" 2>/dev/null
  ;;
*" pr create "* | *" pr edit "* | *" pr view "* | *" issue view "* | *" repo view "*) limited ;;
*" api user "*)
  [[ -f "${d}/user_fail" ]] && {
    echo "gh: Resource not accessible by integration (HTTP 403)" >&2
    exit 1
  }
  echo me
  ;;
*" api -X POST "*"/pulls "*)
  if [[ -f "${d}/create_fail" ]]; then
    echo '{"message":"Validation Failed","errors":[{"message":"A pull request already exists for o:x."}]}'
    echo "gh: Validation Failed (HTTP 422)" >&2
    exit 1
  fi
  body_arg "${d}/created_body" "$@"
  printf '7\thttps://github.com/o/r/pull/7\n'
  ;;
*" api -X PATCH "*"/pulls/"*) body_arg "${d}/edited_body" "$@" ;;
*" api -X PATCH "*"/issues/"*)
  [[ -f "${d}/meta_fail" ]] && {
    echo "gh: Validation Failed (HTTP 422)" >&2
    exit 1
  }
  printf '%s\n' "$*" >"${d}/meta"
  ;;
*" api "*"/pulls/"*)
  case "${args}" in
  *".base.ref"*) cat "${d}/base" 2>/dev/null || echo main ;;
  *".body"*) cat "${d}/body" ;;
  *)
    [[ -f "${d}/pr_view_fail" ]] && {
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    }
    echo PR_7
    ;;
  esac
  ;;
*" api "*"/issues/"*)
  for a in "$@"; do [[ "${a}" == repos/*/issues/* ]] && n="${a##*/}"; done
  if grep -qx -- "${n}" "${d}/missing" 2>/dev/null; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  elif [[ -f "${d}/subs_fail" ]]; then
    echo "HTTP 502: Bad Gateway" >&2
    exit 1
  fi
  printf 'I_%s\t%s\n' "${n}" "$(cat "${d}/open.${n}" 2>/dev/null || echo 0)"
  ;;
*" api repos/"*) printf '%s\to\n' "$(cat "${d}/default" 2>/dev/null || echo main)" ;;
*)
  echo "stub gh: unexpected call: $*" >&2
  exit 99
  ;;
esac
STUB
chmod +x "${bin}/gh"

# git stub: current branch from $STUB_DIR/current, gh-merge-base per branch from $STUB_DIR/merge-base.<branch>.
# Local HEAD is $LOCAL_SHA. The remote tip of <branch> is $STUB_DIR/remote.<branch>, else $LOCAL_SHA, as if pushed;
# $STUB_DIR/no_remote.<branch> means origin has no such branch. origin's URL is $STUB_DIR/origin_url, else the o/r repository.
# Each call is logged to $STUB_DIR/git_log.
cat >"${bin}/git" <<'STUB'
#!/usr/bin/env bash
d="${STUB_DIR}"
local_sha=1111111111111111111111111111111111111111
printf '%s\n' "$*" >>"${d}/git_log"
case "$*" in
"branch --show-current") cat "${d}/current" 2>/dev/null || echo feat-x ;;
"config --get branch."*".gh-merge-base")
  b="${3#branch.}"
  cat "${d}/merge-base.${b%.gh-merge-base}" 2>/dev/null || exit 1
  ;;
"rev-parse HEAD") echo "${local_sha}" ;;
"remote get-url origin") cat "${d}/origin_url" 2>/dev/null || echo "https://github.com/o/r.git" ;;
"ls-remote origin refs/heads/"*)
  b="${3#refs/heads/}"
  [[ -f "${d}/no_remote.${b}" ]] && exit 0
  printf '%s\trefs/heads/%s\n' "$(cat "${d}/remote.${b}" 2>/dev/null || echo "${local_sha}")" "${b}"
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
called "POST .*/pulls " && r=1
check "non-default base still rejects a missing issue" "${r}"

setup $'Body\nCloses #12'
echo 3 >"${STUB_DIR}/open.12"
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "Related #12 (3 open sub-issues remain)" "${STUB_DIR}/created_body" 2>/dev/null || r=1
grep -q "Closes" "${STUB_DIR}/created_body" 2>/dev/null && r=1
called "api graphql" && r=1
has_line "NOTICE: #12 has 3 open sub-issues; rewrote to Related #12" || r=1
check "issue with open sub-issues is rewritten to Related" "${r}"

setup $'Closes #12\nCloses #13'
echo 2 >"${STUB_DIR}/open.12"
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "Related #12 (2 open sub-issues remain)" "${STUB_DIR}/created_body" 2>/dev/null || r=1
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
grep -qx "Related #12 (1 open sub-issues remain)" "${STUB_DIR}/created_body" 2>/dev/null || r=1
called "api graphql" && r=1
check "open sub-issues are rewritten on a non-default base too" "${r}"

setup $'Closes #012'
echo 3 >"${STUB_DIR}/open.12"
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx "Related #12 (3 open sub-issues remain)" "${STUB_DIR}/created_body" 2>/dev/null || r=1
called "api graphql" && r=1
check "leading zeros do not dodge the sub-issue rewrite" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/subs_fail"
create
r=0
[[ "${rc}" == 2 ]] || r=1
called "POST .*/pulls " && r=1
has_line "ISSUE_NOT_FOUND #12: HTTP 502: Bad Gateway" || r=1
check "a failed sub-issue query stops instead of skipping the guard" "${r}"

setup $'Closes #5'
echo 5 >"${STUB_DIR}/missing"
create
r=0
[[ "${rc}" == 2 ]] || r=1
called "POST .*/pulls " && r=1
has_line "ISSUE_NOT_FOUND #5: gh: Not Found (HTTP 404)" || r=1
check "missing issue exits 2 with gh's reason before creating the PR" "${r}"

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
called "POST .*/pulls " && r=1
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
has_line "NOTICE: #12 has 4 open sub-issues; rewrote to Related #12" || r=1
grep -qx "Related #12 (4 open sub-issues remain)" "${STUB_DIR}/edited_body" 2>/dev/null || r=1
grep -qx "Closes #13" "${STUB_DIR}/edited_body" 2>/dev/null || r=1
has_line "LINKED #13" || r=1
check "--link rewrites an issue with open sub-issues in the PR body" "${r}"

setup ""
printf 'Closes #12\n' >"${STUB_DIR}/body"
echo develop >"${STUB_DIR}/base"
echo 2 >"${STUB_DIR}/open.12"
run --link 7
r=0
[[ "${rc}" == 0 ]] || r=1
called "api graphql" && r=1
grep -qx "Related #12 (2 open sub-issues remain)" "${STUB_DIR}/edited_body" 2>/dev/null || r=1
check "--link on a non-default base still rewrites open sub-issues" "${r}"

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
grep -q -- "POST .*/pulls .*base=develop" "${STUB_DIR}/log" || r=1
grep -qx "Closes #12" "${STUB_DIR}/created_body" 2>/dev/null || r=1
called "api graphql" && r=1
check "gh-merge-base of the current branch is the base" "${r}"

setup $'Closes #12'
echo develop >"${STUB_DIR}/merge-base.feat-y"
create --head feat-y
r=0
[[ "${rc}" == 0 ]] || r=1
grep -q -- "POST .*/pulls .*base=develop" "${STUB_DIR}/log" || r=1
called "api graphql" && r=1
check "gh-merge-base is read from the --head branch" "${r}"

setup $'Closes #12'
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -q -- "POST .*/pulls .*base=main" "${STUB_DIR}/log" || r=1
check "default branch is passed as --base when nothing is configured" "${r}"

setup ""
run --title "t"
r=0
[[ "${rc}" == 2 ]] || r=1
check "missing --body-file exits 2" "${r}"

older_sha=2222222222222222222222222222222222222222
setup $'Closes #12'
echo "${older_sha}" >"${STUB_DIR}/remote.feat-x"
create
r=0
[[ "${rc}" == 4 ]] || r=1
grep -q "^NOT_PUSHED" <<<"${out}" || r=1
called "POST .*/pulls " && r=1
check "remote branch at an older commit exits 4 without creating the PR" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/no_remote.feat-y"
create --head feat-y
r=0
[[ "${rc}" == 4 ]] || r=1
grep -q "^NOT_PUSHED" <<<"${out}" || r=1
called "POST .*/pulls " && r=1
check "--head branch missing on origin exits 4 without creating the PR" "${r}"

setup $'Closes #12'
create --web
r=0
[[ "${rc}" == 0 ]] || r=1
called "pr view https://github.com/o/r/pull/7 --web" || r=1
check "--web opens the created PR in the browser" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/web_fail"
create --web
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "https://github.com/o/r/pull/7" || r=1
has_line "LINKED #12" || r=1
called "pr view https://github.com/o/r/pull/7 --web" || r=1
check "a failing --web still exits 0 with the PR created and linked" "${r}"

# pr-owner pushes HEAD:refs/heads/<branch> itself, then runs this exact shape from its worktree.
setup ""
out="$(printf 'Closes #12\n' | PATH="${bin}:${PATH}" LINK_POLL_ATTEMPTS=3 LINK_POLL_INTERVAL=0 bash "${target}" \
  --repo o/r --base main --head feat-y --draft --title t --body-file - 2>&1)"
rc=$?
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "https://github.com/o/r/pull/7" || r=1
has_line "LINKED #12" || r=1
grep -q -- "^api -X POST repos/o/r/pulls .*head=feat-y .*base=main .*draft=true" "${STUB_DIR}/log" || r=1
check "pr-owner's pushed --repo --base --head --draft call creates and links the PR" "${r}"

setup $'Body\nCloses #12'
touch "${STUB_DIR}/gql_exhausted"
create --web
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "https://github.com/o/r/pull/7" || r=1
grep -qx "Closes #12" "${STUB_DIR}/created_body" 2>/dev/null || r=1
has_line "NOTICE: GraphQL rate limit exhausted; skipped linking #12" || r=1
grep -q "LINK" <<<"${out}" && r=1
check "GraphQL exhausted: creates the PR and says linking #12 was skipped" "${r}"

setup ""
printf 'Closes #12\n' >"${STUB_DIR}/body"
touch "${STUB_DIR}/gql_exhausted"
run --link 7
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "NOTICE: GraphQL rate limit exhausted; skipped linking #12" || r=1
check "GraphQL exhausted: --link says linking #12 was skipped and exits 0" "${r}"

setup $'Closes #12'
create --assignee @me
r=0
[[ "${rc}" == 0 ]] || r=1
grep -qx -- "api -X PATCH repos/{owner}/{repo}/issues/7 -f assignees\[\]=me --silent" "${STUB_DIR}/meta" 2>/dev/null || r=1
check "--assignee @me is set on the created PR as the login" "${r}"

setup $'Closes #12'
create --assignee @me --label bug
r=0
[[ "${rc}" == 2 ]] || r=1
called "api -X POST" && r=1
check "--label is an unknown option: exits 2 without creating a PR" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/meta_fail"
create --assignee octocat
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "https://github.com/o/r/pull/7" || r=1
has_line "LINKED #12" || r=1
grep -q "^WARN: could not set assignees on https://github.com/o/r/pull/7: gh: Validation Failed (HTTP 422)" <<<"${out}" || r=1
check "a failed assignee update warns and still exits 0 with the PR created and linked" "${r}"

setup $'Closes #12'
touch "${STUB_DIR}/user_fail"
create --assignee @me
r=0
[[ "${rc}" == 0 ]] || r=1
has_line "https://github.com/o/r/pull/7" || r=1
has_line "WARN: could not resolve @me to assign https://github.com/o/r/pull/7: gh: Resource not accessible by integration (HTTP 403)" || r=1
called "api -X PATCH repos/{owner}/{repo}/issues/" && r=1
check "an unresolvable @me warns, updates nothing on the PR, and exits 0" "${r}"

setup $'Closes #12'
echo "git@github.com:fork/r.git" >"${STUB_DIR}/origin_url"
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -q -- "POST .*/pulls .*head=fork:feat-x " "${STUB_DIR}/log" || r=1
check "origin in another owner's fork sends head as fork:feat-x" "${r}"

setup $'Closes #12'
create
r=0
[[ "${rc}" == 0 ]] || r=1
grep -q -- "POST .*/pulls .*head=feat-x " "${STUB_DIR}/log" || r=1
check "origin in the target repository sends head as the bare branch" "${r}"

setup $'Summary\n\nCloses #12'
create --owner orchestrate-epic
r=0
[[ "${rc}" == 0 ]] || r=1
[[ "$(cat "${STUB_DIR}/created_body" 2>/dev/null)" == $'Summary\n\nCloses #12\n\n<!-- automation-owner: orchestrate-epic -->' ]] || r=1
has_line "LINKED #12" || r=1
check "--owner appends the owner line to a body that lacks it" "${r}"

setup $'Summary\n  <!--automation-owner:orchestrate-epic-->  \nOwned by orchestrate-epic.'
create --owner orchestrate-epic
r=0
[[ "${rc}" == 0 ]] || r=1
[[ "$(cat "${STUB_DIR}/created_body" 2>/dev/null)" == $'Summary\n  <!--automation-owner:orchestrate-epic-->  \nOwned by orchestrate-epic.' ]] || r=1
check "--owner leaves a body that already holds the owner line unchanged" "${r}"

setup $'Add the line <!-- automation-owner: orchestrate-epic --> to opt out.\n<!-- automation-owner: orchestrateXepic -->'
create --owner orchestrate.epic
r=0
[[ "${rc}" == 0 ]] || r=1
[[ "$(tail -n 1 "${STUB_DIR}/created_body" 2>/dev/null)" == "<!-- automation-owner: orchestrate.epic -->" ]] || r=1
check "--owner appends the line when the marker appears only inline or for another id" "${r}"

setup $'Summary'
create --owner "two words"
r=0
[[ "${rc}" == 2 ]] || r=1
called "POST .*/pulls " && r=1
check "--owner with an id outside [A-Za-z0-9._-] is rejected before creating" "${r}"

setup $'Summary'
run --link 7 --owner orchestrate-epic
r=0
[[ "${rc}" == 2 ]] || r=1
called "PATCH" && r=1
check "--owner with --link is rejected without touching the PR" "${r}"

exit "${fail}"
