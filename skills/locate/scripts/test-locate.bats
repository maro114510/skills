#!/usr/bin/env bats
# Tests for locate.sh against a local repository with real worktrees. GitHub is faked: gh is a stub on
# PATH, and LOCATE_PR_STATE points at a stub that prints babysit's normalized pull request JSON.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/locate.sh"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.email t@example.invalid
  git config user.name t
  git config core.hooksPath /dev/null
  git commit -q --allow-empty -m base
  git remote add origin https://github.com/o/r.git
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export LOCATE_PR_STATE="${BATS_TEST_TMPDIR}/pr-state.sh"
}

# Checks out branch $1 in a new worktree at $2, a directory name that need not match the branch.
worktree_on() {
  git -C "${repo}" worktree add -q -b "$1" "$2"
}

# Fakes babysit's pr-state.sh: pull request 7 of o/r in state $1 with head branch $2, from a fork when $3 is
# true. One review thread is unresolved and one resolved; one check failed, one waits for a required action,
# one passed, and one is still running.
pr_state() {
  cat >"${LOCATE_PR_STATE}" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "o/r 7" ] || { echo "unexpected pr-state call: \$*" >&2; exit 2; }
cat <<'JSON'
{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"$1","isDraft":false,
 "isCrossRepository":${3:-false},"baseRef":"main","headRef":"$2","head":"aaa",
 "threads":[{"id":"T1","isResolved":false},{"id":"T2","isResolved":true}],
 "checks":[{"name":"lint","status":"failed","url":"https://ci/lint"},{"name":"deploy","status":"action","url":"https://ci/deploy"},
   {"name":"test","status":"pass","url":"https://ci/test"},
   {"name":"build","status":"pending","url":"https://ci/build"}]}
JSON
EOF
}

# Fakes gh for Issue 9 of o/r in state $1, linked on GitHub to the branches that follow, one per argument.
issue_gh() {
  local state="$1" b
  shift
  : >"${BATS_TEST_TMPDIR}/linked"
  for b in "$@"; do
    printf '%s\thttps://github.com/o/r/tree/%s\n' "${b}" "${b}" >>"${BATS_TEST_TMPDIR}/linked"
  done
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
'issue view 9 -R o/r --json state,stateReason,url')
  echo '{"state":"${state}","stateReason":"","url":"https://github.com/o/r/issues/9"}' ;;
'issue develop --list 9 -R o/r') cat "${BATS_TEST_TMPDIR}/linked" ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
}

# Adds branch $1 of the fork fork/r to the branches GitHub links to Issue 9. Call it after issue_gh.
link_fork_branch() {
  printf '%s\thttps://github.com/fork/r/tree/%s\n' "$1" "$1" >>"${BATS_TEST_TMPDIR}/linked"
}

field() {
  jq -cr "$1" <<<"${output}"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

canonical() {
  (cd "$1" && pwd -P)
}

@test "a PR whose head branch is checked out in one worktree resolves to that worktree and branch" {
  worktree_on feat/x "${BATS_TEST_TMPDIR}/elsewhere"
  pr_state OPEN feat/x
  run bash "${target}" https://github.com/o/r/pull/7
  expect "${status}" 0
  expect "$(field .kind)" pr
  expect "$(field .match)" one
  expect "$(field '.worktrees')" "[{\"path\":\"$(canonical "${BATS_TEST_TMPDIR}/elsewhere")\",\"branch\":\"feat/x\"}]"
  expect "$(field '.branches')" '["feat/x"]'
}

@test "a merged PR reports its state as MERGED" {
  worktree_on feat/x "${BATS_TEST_TMPDIR}/wt"
  pr_state MERGED feat/x
  run bash "${target}" https://github.com/o/r/pull/7
  expect "${status}" 0
  expect "$(field .state)" MERGED
}

@test "a PR reports its unresolved thread count, failing checks, and pending check count" {
  pr_state OPEN feat/x
  run bash "${target}" https://github.com/o/r/pull/7
  expect "${status}" 0
  expect "$(field .unresolvedThreads)" 1
  expect "$(field .failingChecks)" '[{"name":"lint","url":"https://ci/lint"},{"name":"deploy","url":"https://ci/deploy"}]'
  expect "$(field .pendingChecks)" 1
}

@test "a PR whose head branch has no worktree reports no match and still names the branch" {
  pr_state OPEN feat/x
  run bash "${target}" https://github.com/o/r/pull/7
  expect "${status}" 0
  expect "$(field .match)" none
  expect "$(field .worktrees)" '[]'
  expect "$(field .branches)" '["feat/x"]'
}

@test "an Issue with two linked branches checked out in two worktrees reports both as candidates" {
  worktree_on feat/issue-9-a "${BATS_TEST_TMPDIR}/a"
  worktree_on feat/issue-9-a-2 "${BATS_TEST_TMPDIR}/b"
  issue_gh OPEN feat/issue-9-a feat/issue-9-a-2
  run bash "${target}" https://github.com/o/r/issues/9
  expect "${status}" 0
  expect "$(field .kind)" issue
  expect "$(field .state)" OPEN
  expect "$(field .match)" many
  expect "$(field '[.worktrees[].branch]')" '["feat/issue-9-a","feat/issue-9-a-2"]'
}

@test "an Issue ignores a worktree branch that carries issue-<N> but that GitHub does not link" {
  worktree_on feat/issue-9 "${BATS_TEST_TMPDIR}/unlinked"
  issue_gh OPEN
  run bash "${target}" https://github.com/o/r/issues/9
  expect "${status}" 0
  expect "$(field .match)" none
  expect "$(field .branches)" '[]'
}

@test "a PR from a fork matches no worktree, even one on a local branch of the same name" {
  worktree_on feat/x "${BATS_TEST_TMPDIR}/same-name"
  pr_state OPEN feat/x true
  run bash "${target}" https://github.com/o/r/pull/7
  expect "${status}" 0
  expect "$(field .isCrossRepository)" true
  expect "$(field .match)" none
  expect "$(field .worktrees)" '[]'
}

@test "an Issue ignores a linked branch that lives in a fork, even with a same-named local worktree" {
  worktree_on feat/issue-9-a "${BATS_TEST_TMPDIR}/same-name"
  issue_gh OPEN
  link_fork_branch feat/issue-9-a
  run bash "${target}" https://github.com/o/r/issues/9
  expect "${status}" 0
  expect "$(field .match)" none
  expect "$(field .branches)" '[]'
}

@test "a URL for a repository other than this clone's origin exits 3" {
  pr_state OPEN feat/x
  run bash "${target}" https://github.com/other/r/pull/7
  expect "${status}" 3
}

@test "an origin in SSH form with a differently cased owner still matches the URL" {
  git -C "${repo}" remote set-url origin git@github.com:O/R.git
  pr_state OPEN feat/x
  run bash "${target}" https://github.com/o/r/pull/7
  expect "${status}" 0
  expect "$(field .number)" 7
}

@test "an argument that is not a pull request or Issue URL exits 2" {
  run bash "${target}" https://github.com/o/r/commit/abc
  expect "${status}" 2
}

@test "a GitHub read that fails exits 1" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"${LOCATE_PR_STATE}"
  run bash "${target}" https://github.com/o/r/pull/7
  expect "${status}" 1
}
