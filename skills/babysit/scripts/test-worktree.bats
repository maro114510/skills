#!/usr/bin/env bats
# Tests for worktree.sh against a local bare origin, so no test calls GitHub.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  # A caller's own repository selection (a hook exports GIT_DIR) must not leak into the repositories built here.
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  export BABYSIT_NOW=1000000
  token="tok-1"
  origin="${BATS_TEST_TMPDIR}/origin.git"
  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q --bare -b main "${origin}"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.email t@example.invalid
  git config user.name t
  echo base >a.txt
  git add a.txt
  git commit -qm base
  git remote add origin "${origin}"
  git push -q origin main
  git checkout -q -b feat/x
  echo x >b.txt
  git add b.txt
  git commit -qm x
  git push -q origin feat/x
  head="$(git rev-parse HEAD)"
  git checkout -q main
  git branch -q -D feat/x
  # The user's own checkout holds work in progress that no babysit step may touch.
  echo dirty >>a.txt
  echo untracked >u.txt
  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
  wt="$(git rev-parse --path-format=absolute --git-common-dir)/babysit/wt/o/r/7"
}

prepare() {
  run bash "${scripts}/worktree.sh" prepare o/r 7 --session "${token}" --branch feat/x "$@"
}

# Everything that identifies the user's checkout: branch, HEAD, tracked and untracked changes, and branches.
fingerprint() {
  git -C "${repo}" symbolic-ref HEAD
  git -C "${repo}" rev-parse HEAD
  git -C "${repo}" status --porcelain --untracked-files=all
  git -C "${repo}" diff HEAD
  cat "${repo}/a.txt" "${repo}/u.txt"
  git -C "${repo}" branch --list
}

# Pushes one more commit to feat/x from a second clone and prints its sha.
advance_remote() {
  git clone -q "${origin}" "${BATS_TEST_TMPDIR}/other"
  git -C "${BATS_TEST_TMPDIR}/other" config user.email t@example.invalid
  git -C "${BATS_TEST_TMPDIR}/other" config user.name t
  git -C "${BATS_TEST_TMPDIR}/other" checkout -q feat/x
  echo y >"${BATS_TEST_TMPDIR}/other/c.txt"
  git -C "${BATS_TEST_TMPDIR}/other" add c.txt
  git -C "${BATS_TEST_TMPDIR}/other" commit -qm y
  git -C "${BATS_TEST_TMPDIR}/other" push -q origin feat/x
  git -C "${BATS_TEST_TMPDIR}/other" rev-parse HEAD
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

@test "rejects bad arguments with exit 2" {
  run bash "${scripts}/worktree.sh"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/worktree.sh" prepare noslash 7 --session "${token}" --branch feat/x
  [ "${status}" -eq 2 ]
  run bash "${scripts}/worktree.sh" prepare o/r 0 --session "${token}" --branch feat/x
  [ "${status}" -eq 2 ]
  run bash "${scripts}/worktree.sh" prepare o/r 7 --branch feat/x
  [ "${status}" -eq 2 ]
  run bash "${scripts}/worktree.sh" prepare o/r 7 --session "${token}"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/worktree.sh" prepare o/r 7 --session "${token}" --branch -feat
  [ "${status}" -eq 2 ]
  run bash "${scripts}/worktree.sh" prepare o/r 7 --session "${token}" --branch feat/x --head abc
  [ "${status}" -eq 2 ]
  [ ! -e "${wt}" ]
  prepare --head "${head}"
  [ "${status}" -eq 0 ]
}

@test "a session that does not hold the lock exits 3 and creates nothing" {
  run bash "${scripts}/worktree.sh" prepare o/r 7 --session other --branch feat/x
  [ "${status}" -eq 3 ]
  [ ! -e "${wt}" ]
  run bash "${scripts}/worktree.sh" remove o/r 7 --session other
  [ "${status}" -eq 3 ]
}

@test "prepare puts a detached worktree at the PR head under the git common dir" {
  prepare
  [ "${status}" -eq 0 ]
  expect "$(jq -r .path <<<"${output}")" "${wt}"
  expect "$(jq -r .sha <<<"${output}")" "${head}"
  expect "$(git -C "${wt}" rev-parse HEAD)" "${head}"
  run git -C "${wt}" symbolic-ref -q HEAD
  [ "${status}" -ne 0 ]
  [ "$(cat "${wt}/b.txt")" = x ]
}

@test "prepare leaves the user's checkout and branches as they were" {
  before="$(fingerprint)"
  prepare
  [ "${status}" -eq 0 ]
  prepare
  [ "${status}" -eq 0 ]
  expect "$(fingerprint)" "${before}"
}

@test "prepare again resets to a moved head and drops leftover work" {
  prepare
  echo leftover >>"${wt}/b.txt"
  echo stray >"${wt}/stray.txt"
  git -C "${wt}" -c user.email=t@example.invalid -c user.name=t commit -qam "unpushed fix"
  echo more >>"${wt}/b.txt"
  new_head="$(advance_remote)"
  prepare
  [ "${status}" -eq 0 ]
  expect "$(jq -r .sha <<<"${output}")" "${new_head}"
  expect "$(git -C "${wt}" rev-parse HEAD)" "${new_head}"
  expect "$(git -C "${wt}" status --porcelain --untracked-files=all)" ""
  [ ! -e "${wt}/stray.txt" ]
  [ "$(cat "${wt}/b.txt")" = x ]
}

@test "prepare exits 1 when the head is not the one the caller expects, and changes nothing" {
  prepare --head "$(printf 'c%.0s' $(seq 40))"
  [ "${status}" -eq 1 ]
  [ ! -e "${wt}" ]
  prepare --head "${head}"
  [ "${status}" -eq 0 ]
  new_head="$(advance_remote)"
  prepare --head "${head}"
  [ "${status}" -eq 1 ]
  expect "$(git -C "${wt}" rev-parse HEAD)" "${head}"
  [ -n "${new_head}" ]
}

@test "prepare exits 1 when the branch is not on origin" {
  run bash "${scripts}/worktree.sh" prepare o/r 7 --session "${token}" --branch feat/missing
  [ "${status}" -eq 1 ]
  [ ! -e "${wt}" ]
}

@test "prepare refuses a leftover directory that is not a worktree and leaves it alone" {
  mkdir -p "${wt}"
  echo keep >"${wt}/keep.txt"
  prepare
  [ "${status}" -eq 1 ]
  [ "$(cat "${wt}/keep.txt")" = keep ]
}

@test "prepare refreshes the heartbeat" {
  BABYSIT_NOW=1000090 prepare
  [ "${status}" -eq 0 ]
  expect "$(bash "${scripts}/ledger.sh" show o/r 7 | jq -r .lock.heartbeat)" 1000090
}

@test "remove deletes the worktree and nothing of the user's, and succeeds when there is none" {
  run bash "${scripts}/worktree.sh" remove o/r 7 --session "${token}"
  [ "${status}" -eq 0 ]
  prepare
  before="$(fingerprint)"
  run bash "${scripts}/worktree.sh" remove o/r 7 --session "${token}"
  [ "${status}" -eq 0 ]
  [ ! -e "${wt}" ]
  expect "$(git -C "${repo}" worktree list --porcelain | grep -c '^worktree ')" 1
  expect "$(fingerprint)" "${before}"
}

@test "prepare works for a repository whose name Git would refuse in a ref" {
  for name in .github foo.lock; do
    bash "${scripts}/ledger.sh" start "o/${name}" 8 "${token}" >/dev/null
    run bash "${scripts}/worktree.sh" prepare "o/${name}" 8 --session "${token}" --branch feat/x
    [ "${status}" -eq 0 ]
    expect "$(jq -r .sha <<<"${output}")" "${head}"
    expect "$(git -C "$(jq -r .path <<<"${output}")" rev-parse HEAD)" "${head}"
  done
}

@test "prepare ignores a GIT_DIR from the caller and never moves the caller's HEAD" {
  prepare
  [ "${status}" -eq 0 ]
  echo leftover >"${wt}/stray.txt"
  user_head="$(git -C "${repo}" rev-parse HEAD)"
  GIT_DIR="${repo}/.git" prepare
  [ "${status}" -eq 0 ]
  expect "$(git -C "${repo}" rev-parse HEAD)" "${user_head}"
  expect "$(git -C "${wt}" rev-parse HEAD)" "${head}"
  [ ! -e "${wt}/stray.txt" ]
}
