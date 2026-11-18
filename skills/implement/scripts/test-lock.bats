#!/usr/bin/env bats
# Tests for lock.sh, against a throwaway repo whose origin is a local bare repo and a fake gh.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  # The developer's own git config and hooks must not reach the repositories built here.
  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  : >"${GIT_CONFIG_GLOBAL}"
  target="${BATS_TEST_DIRNAME}/lock.sh"
  work="${BATS_TEST_TMPDIR}"
  origin="${work}/origin.git"
  git init -q --bare "${origin}"
  repo="${work}/repo"
  git init -q -b main "${repo}"
  git -C "${repo}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "${repo}" remote add origin "${origin}"
  git -C "${repo}" push -q origin main
  cd "${repo}" || return 1
  # The fake gh answers from files in ${gh_dir}: the head commits of the branch's merged pull requests, one per line,
  # and the Issue's state.
  gh_dir="${work}/gh"
  mkdir -p "${work}/bin" "${gh_dir}"
  : >"${gh_dir}/merged"
  echo OPEN >"${gh_dir}/state"
  cat >"${work}/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
"pr list") cat "${FAKE_GH_DIR}/merged" ;;
"issue view") cat "${FAKE_GH_DIR}/state" ;;
*) exit 2 ;;
esac
GH
  chmod +x "${work}/bin/gh"
  export FAKE_GH_DIR="${gh_dir}" PATH="${work}/bin:${PATH}"
}

# Creates feat/issue-7 on origin at the head of main, as a person's earlier run or oe would have.
branch_on_origin() {
  git -C "${repo}" push -q origin main:refs/heads/feat/issue-7
}

origin_head_of() {
  git -C "${origin}" rev-parse "refs/heads/$1"
}

@test "creates feat/issue-<N> on origin at the base head when it is absent" {
  run bash "${target}" 7 main
  [ "${status}" -eq 0 ]
  [ "${output}" = "locked	feat/issue-7" ]
  [ "$(origin_head_of feat/issue-7)" = "$(origin_head_of main)" ]
}

@test "returns Busy naming the branch when a second run takes the same Issue" {
  bash "${target}" 7 main
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
  [[ "${output}" == *"branch=feat/issue-7"* ]]
}

@test "leaves the existing branch where it was when it returns Busy" {
  git -C "${repo}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m ahead
  git -C "${repo}" push -q origin HEAD:refs/heads/feat/issue-7
  ahead="$(origin_head_of feat/issue-7)"
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
  [ "$(origin_head_of feat/issue-7)" = "${ahead}" ]
}

@test "returns Busy for a branch that still sits at the base head" {
  branch_on_origin
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
  [[ "${output}" == *"branch=feat/issue-7"* ]]
}

@test "names the worktree holding the branch on this host when Busy" {
  branch_on_origin
  git -C "${repo}" worktree add -q "${work}/wt" -b feat/issue-7 main
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
  [[ "${output}" == *"worktree=$(cd "${work}/wt" && pwd -P)"* ]]
}

@test "names no worktree when none on this host holds the branch" {
  branch_on_origin
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
  [[ "${output}" != *"worktree="* ]]
}

@test "returns the merged signal when the branch's pull request merged and the Issue is open" {
  branch_on_origin
  origin_head_of feat/issue-7 >"${gh_dir}/merged"
  run bash "${target}" 7 main
  [ "${status}" -eq 10 ]
  [[ "${output}" == *"branch=feat/issue-7"* ]]
}

@test "returns Busy for a merged branch whose Issue is closed" {
  branch_on_origin
  origin_head_of feat/issue-7 >"${gh_dir}/merged"
  echo CLOSED >"${gh_dir}/state"
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
}

@test "ends with an error and creates nothing when origin is unreachable" {
  git -C "${repo}" remote set-url origin "${work}/missing.git"
  run bash "${target}" 7 main
  [ "${status}" -eq 2 ]
  [ ! -e "${origin}/refs/heads/feat/issue-7" ]
}

@test "ends with an error when the base branch is not on origin" {
  run bash "${target}" 7 nope
  [ "${status}" -eq 2 ]
  [ -z "$(git -C "${origin}" for-each-ref refs/heads/feat)" ]
}

@test "rejects an invalid issue number" {
  run bash "${target}" 0 main
  [ "${status}" -eq 2 ]
  run bash "${target}" abc main
  [ "${status}" -eq 2 ]
}

@test "uses the branch name that oe claim creates" {
  prefix="$(sed -n 's/^branch_prefix=//p' "${BATS_TEST_DIRNAME}/../../orchestrate-epic/scripts/oe-config.sh")"
  [ "${prefix}" = "feat/issue-" ]
  run bash "${target}" 7 main
  [ "${output}" = "locked	${prefix}7" ]
}

@test "returns Busy when another run creates the branch at the same head after this run read it as absent" {
  real_git="$(command -v git)"
  # The other run's push lands between this run's read and its own push.
  cat >"${work}/bin/git" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = push ] && [ ! -e "${work}/raced" ]; then
  : >"${work}/raced"
  "${real_git}" push -q origin main:refs/heads/feat/issue-7
fi
exec "${real_git}" "\$@"
WRAP
  chmod +x "${work}/bin/git"
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
  [[ "${output}" == *"branch=feat/issue-7"* ]]
}

@test "returns Busy for a recreated branch whose name an earlier merged pull request also had" {
  branch_on_origin
  echo 1111111111111111111111111111111111111111 >"${gh_dir}/merged"
  run bash "${target}" 7 main
  [ "${status}" -eq 20 ]
}
