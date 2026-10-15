#!/usr/bin/env bats
# Tests for claim.sh, against a throwaway repo whose origin is a local bare repo.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/claim.sh"
  work="${BATS_TEST_TMPDIR}"
  export XDG_STATE_HOME="${work}/state"
  claim_dir="${XDG_STATE_HOME}/agent-claims/o/r/issue-7"
  git init -q --bare "${work}/origin.git"
  repo="${work}/repo"
  git init -q -b main "${repo}"
  git -C "${repo}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "${repo}" remote add origin "${work}/origin.git"
  git -C "${repo}" push -q origin main
  cd "${repo}" || return 1
}

claim() {
  run bash "${target}" "$@"
}

# Succeeds when the output has a line exactly equal to $1.
has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

# Prints the value of key $1 from the output.
value() {
  printf '%s\n' "${lines[@]}" | sed -n "s/^$1=//p" | head -n1
}

@test "rejects bad arguments with exit 2" {
  claim
  [ "${status}" -eq 2 ]
  claim nope o/r 7
  [ "${status}" -eq 2 ]
  claim acquire ../.. 7
  [ "${status}" -eq 2 ]
  claim acquire o/.. 7
  [ "${status}" -eq 2 ]
  claim acquire o 7
  [ "${status}" -eq 2 ]
  claim acquire o/r 0
  [ "${status}" -eq 2 ]
  claim acquire o/r 7a
  [ "${status}" -eq 2 ]
  claim acquire o/r 7 'bad token'
  [ "${status}" -eq 2 ]
  [ ! -e "${claim_dir}" ]
}

@test "fresh claim with no branch exits 0 and records the token" {
  claim acquire o/r 7
  [ "${status}" -eq 0 ]
  token="$(value token)"
  [ -n "${token}" ]
  grep -qxF "token=${token}" "${claim_dir}/owner"
}

@test "rerun with the same token is this session's own claim" {
  claim acquire o/r 7 tok-a
  [ "${status}" -eq 0 ]
  claim acquire o/r 7 tok-a
  [ "${status}" -eq 0 ]
  has_line "token=tok-a"
}

@test "claim held by another token exits 20 with its owner" {
  CLAIM_PID=$$ bash "${target}" acquire o/r 7 tok-a
  claim acquire o/r 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "owner_token=tok-a"
  has_line "alive=yes"
  grep -qxF "token=tok-a" "${claim_dir}/owner"
}

@test "dead owner process is reported as not alive" {
  CLAIM_PID=999999 bash "${target}" acquire o/r 7 tok-a
  claim acquire o/r 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "alive=no"
}

@test "claim without an owner file exits 20" {
  mkdir -p "${claim_dir}"
  claim acquire o/r 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "owner=missing"
}

@test "local matching branch exits 10 and lists it" {
  git branch feat/issue-7-thing
  claim acquire o/r 7
  [ "${status}" -eq 10 ]
  has_line "branch=feat/issue-7-thing remote=no worktree=- dirty=-"
}

@test "remote-only branch exits 10 and lists it as remote" {
  git push -q origin main:refs/heads/feat/issue-7
  claim acquire o/r 7
  [ "${status}" -eq 10 ]
  has_line "branch=feat/issue-7 remote=yes worktree=- dirty=-"
}

@test "branch with a worktree reports its path and dirtiness" {
  git worktree add -q -b fix/issue-7-x "${work}/wt"
  touch "${work}/wt/new.txt"
  claim acquire o/r 7
  [ "${status}" -eq 10 ]
  wt="$(cd "${work}/wt" && pwd -P)"
  has_line "branch=fix/issue-7-x remote=no worktree=${wt} dirty=yes"
}

@test "other issue numbers do not match" {
  git branch feat/issue-70
  git branch feat/issue-17-x
  git branch issue-7x
  claim acquire o/r 7
  [ "${status}" -eq 0 ]
}

@test "unreachable origin exits 2 and drops a new claim" {
  git remote set-url origin "${work}/missing.git"
  claim acquire o/r 7
  [ "${status}" -eq 2 ]
  [ ! -e "${claim_dir}" ]
}

@test "unreachable origin keeps an existing own claim" {
  bash "${target}" acquire o/r 7 tok-a
  git remote set-url origin "${work}/missing.git"
  claim acquire o/r 7 tok-a
  [ "${status}" -eq 2 ]
  [ -e "${claim_dir}/owner" ]
}

@test "unwritable state directory exits 2" {
  mkdir -p "${XDG_STATE_HOME}"
  chmod 500 "${XDG_STATE_HOME}"
  claim acquire o/r 7
  chmod 700 "${XDG_STATE_HOME}"
  [ "${status}" -eq 2 ]
}

@test "concurrent acquires give exactly one claim" {
  local i wins=0
  for i in $(seq 1 20); do
    (
      bash "${target}" acquire o/r 7 "tok-${i}" >/dev/null 2>&1
      echo $? >"${work}/rc.${i}"
    ) &
  done
  wait
  for i in $(seq 1 20); do
    [[ "$(cat "${work}/rc.${i}")" == 0 ]] && wins=$((wins + 1))
  done
  [ "${wins}" -eq 1 ]
}

@test "takeover replaces the owner and still reports branches" {
  bash "${target}" acquire o/r 7 tok-a
  git branch feat/issue-7
  claim takeover o/r 7 tok-b
  [ "${status}" -eq 10 ]
  grep -qxF "token=tok-b" "${claim_dir}/owner"
}

@test "release by a non-owner exits 20 and keeps the claim" {
  bash "${target}" acquire o/r 7 tok-a
  claim release o/r 7 tok-b
  [ "${status}" -eq 20 ]
  [ -e "${claim_dir}/owner" ]
}

@test "release by the owner removes the claim, and is idempotent" {
  bash "${target}" acquire o/r 7 tok-a
  claim release o/r 7 tok-a
  [ "${status}" -eq 0 ]
  [ ! -e "${claim_dir}" ]
  claim release o/r 7 tok-a
  [ "${status}" -eq 0 ]
}

@test "release and takeover require a token" {
  claim release o/r 7
  [ "${status}" -eq 2 ]
  claim takeover o/r 7
  [ "${status}" -eq 2 ]
}
