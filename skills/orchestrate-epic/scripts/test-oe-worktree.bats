#!/usr/bin/env bats
# Tests for oe worktree.
#
# - Each test builds a bare origin and a shared checkout cloned from it, both under the test's temporary directory.
# - origin holds main and the Issue branch feat/issue-5, one commit ahead of main.
# - The shared checkout has a staged, an unstaged, and an untracked change, so any write to it shows.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  tmp="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
  export GIT_CONFIG_GLOBAL="${tmp}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  unset OE_WORKTREE_ROOT

  git init -q --bare "${tmp}/origin.git"
  git clone -q "${tmp}/origin.git" "${tmp}/seed" 2>/dev/null
  echo base >"${tmp}/seed/README"
  git -C "${tmp}/seed" add README
  git -C "${tmp}/seed" commit -q -m base
  git -C "${tmp}/seed" push -q origin main
  git -C "${tmp}/seed" switch -q -c feat/issue-5
  echo work >"${tmp}/seed/work"
  git -C "${tmp}/seed" add work
  git -C "${tmp}/seed" commit -q -m work
  git -C "${tmp}/seed" push -q origin feat/issue-5
  issue_head="$(git -C "${tmp}/seed" rev-parse HEAD)"

  shared="${tmp}/shared"
  git clone -q "${tmp}/origin.git" "${shared}"
  echo staged >"${shared}/staged"
  git -C "${shared}" add staged
  echo edited >>"${shared}/README"
  echo untracked >"${shared}/untracked"
  cd "${shared}" || return 1
}

# Prints the shared checkout's HEAD, index, and working tree, so two snapshots differ when any of them changed.
snapshot() {
  git -C "${shared}" symbolic-ref HEAD
  git -C "${shared}" rev-parse HEAD
  git -C "${shared}" ls-files --stage
  git -C "${shared}" status --porcelain=v1 --untracked-files=all
  git -C "${shared}" diff
  cat "${shared}/README" "${shared}/staged" "${shared}/untracked"
}

@test "an Issue worktree checks out the origin branch outside the shared checkout and leaves the shared checkout unchanged" {
  before="$(snapshot)"

  run --separate-stderr bash "${oe}" worktree add 5

  [ "${status}" -eq 0 ]
  [ "${output}" = "${tmp}/shared-oe/issue-5" ]
  [ "$(git -C "${output}" rev-parse HEAD)" = "${issue_head}" ]
  [ "$(git -C "${output}" branch --show-current)" = feat/issue-5 ]
  [ "$(git -C "${output}" rev-parse --abbrev-ref '@{upstream}')" = origin/feat/issue-5 ]
  [ "$(snapshot)" = "${before}" ]
}

@test "an Issue whose branch is not on origin gets no worktree" {
  before="$(snapshot)"

  run --separate-stderr bash "${oe}" worktree add 6

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"feat/issue-6"*) ;;
  *) return 1 ;;
  esac
  [ "$(git -C "${shared}" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
  [ ! -e "${tmp}/shared-oe/issue-6" ]
  [ "$(snapshot)" = "${before}" ]
}

@test "a leftover Issue worktree is replaced by a fresh one at the origin head, discarding its unpushed work" {
  wt="${tmp}/shared-oe/issue-5"
  git -C "${shared}" worktree add -q -b feat/issue-5 "${wt}" origin/feat/issue-5
  echo unpushed >"${wt}/unpushed"
  git -C "${wt}" add unpushed
  git -C "${wt}" commit -q -m unpushed
  echo dirty >"${wt}/dirty"
  before="$(snapshot)"

  run --separate-stderr bash "${oe}" worktree add 5

  [ "${status}" -eq 0 ]
  [ "$(git -C "${wt}" rev-parse HEAD)" = "${issue_head}" ]
  [ -z "$(git -C "${wt}" status --porcelain --untracked-files=all)" ]
  [ "$(snapshot)" = "${before}" ]
}

@test "removing an Issue worktree deletes it and leaves the shared checkout unchanged" {
  git -C "${shared}" worktree add -q -b feat/issue-5 "${tmp}/shared-oe/issue-5" origin/feat/issue-5
  echo dirty >"${tmp}/shared-oe/issue-5/dirty"
  before="$(snapshot)"

  run --separate-stderr bash "${oe}" worktree remove 5

  [ "${status}" -eq 0 ]
  [ ! -e "${tmp}/shared-oe/issue-5" ]
  [ "$(git -C "${shared}" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
  [ "$(snapshot)" = "${before}" ]
}

@test "a directory at the Issue worktree path that is not a worktree of this clone is left alone" {
  mkdir -p "${tmp}/shared-oe/issue-5"
  echo mine >"${tmp}/shared-oe/issue-5/notes"

  run --separate-stderr bash "${oe}" worktree add 5

  [ "${status}" -eq 1 ]
  case "${stderr}" in
  *"not a worktree"*) ;;
  *) return 1 ;;
  esac
  [ "$(cat "${tmp}/shared-oe/issue-5/notes")" = mine ]
}

@test "OE_WORKTREE_ROOT places the Issue worktree under it" {
  export OE_WORKTREE_ROOT="${tmp}/elsewhere"

  run --separate-stderr bash "${oe}" worktree add 5

  [ "${status}" -eq 0 ]
  [ "${output}" = "${tmp}/elsewhere/issue-5" ]
  [ "$(git -C "${output}" rev-parse HEAD)" = "${issue_head}" ]
}

@test "an Issue worktree whose directory was deleted by hand is created again" {
  git -C "${shared}" worktree add -q -b feat/issue-5 "${tmp}/shared-oe/issue-5" origin/feat/issue-5
  rm -rf "${tmp}/shared-oe/issue-5"

  run --separate-stderr bash "${oe}" worktree add 5

  [ "${status}" -eq 0 ]
  [ "$(git -C "${tmp}/shared-oe/issue-5" rev-parse HEAD)" = "${issue_head}" ]
}
