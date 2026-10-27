#!/usr/bin/env bats
# Tests for push.sh: the one way drive pushes. No test calls GitHub; the gate reads a saved snapshot and a local origin.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  tmp="${BATS_TEST_TMPDIR}"
  token="tok-1"
  check_key="github-actions/.github/workflows/ci.yml/pull_request/test"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export BABYSIT_REMOTE_BASE="file://${tmp}/srv"
  export BABYSIT_PR_STATE="${tmp}/pr-state"
  export BABYSIT_NOW=1000000

  mkdir -p "${tmp}/srv/o" "${tmp}/bin"
  git init -q --bare -b main "${tmp}/srv/o/r.git"
  git clone -q "file://${tmp}/srv/o/r.git" "${tmp}/wt" 2>/dev/null
  cd "${tmp}/wt" || return 1
  git switch -q -c main
  printf 'base\n' >app.txt
  git add -- app.txt
  git commit -q -m base
  git push -q origin main
  git switch -q -c feat/x
  printf 'feature\n' >feature.txt
  git add -- feature.txt
  git commit -q -m feature
  git push -q origin feat/x
  start="$(git rev-parse HEAD)"

  # The pull request as pr-state prints it, and the default branch as gh prints it
  printf '{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,"author":"me","viewer":"me","isCrossRepository":false,"baseRef":"main","headRef":"feat/x","head":"aaa"}\n' >"${tmp}/snap.json"
  printf '#!/usr/bin/env bash\ncat "%s/snap.json"\n' "${tmp}" >"${tmp}/pr-state"
  printf '#!/usr/bin/env bash\necho "{\\"default_branch\\":\\"main\\"}"\n' >"${tmp}/bin/gh"
  chmod +x "${tmp}/pr-state" "${tmp}/bin/gh"
  export PATH="${tmp}/bin:${PATH}"

  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

# Commits file $1 with content $2.
commit_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
  git add -- "$1"
  git commit -q -m "change"
}

push() {
  run bash "${scripts}/push.sh" o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" --branch feat/x "$@"
}

remote_head() {
  git --git-dir="${tmp}/srv/o/r.git" rev-parse refs/heads/feat/x
}

ledger() {
  bash "${scripts}/ledger.sh" show o/r 7 | jq -r "$1"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

@test "rejects bad arguments with exit 2" {
  commit_file fix.txt fix
  run bash "${scripts}/push.sh"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/push.sh" noslash 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" --branch feat/x
  [ "${status}" -eq 2 ]
  run bash "${scripts}/push.sh" o/r 7 --worktree "${tmp}/wt" --start "${start}" --branch feat/x
  [ "${status}" -eq 2 ]
  run bash "${scripts}/push.sh" o/r 7 --session "${token}" --worktree "${tmp}/nowhere" --start "${start}" --branch feat/x
  [ "${status}" -eq 2 ]
  run bash "${scripts}/push.sh" o/r 7 --session "${token}" --worktree "${tmp}/wt" --start short --branch feat/x
  [ "${status}" -eq 2 ]
  run bash "${scripts}/push.sh" o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}"
  [ "${status}" -eq 2 ]
  expect "$(remote_head)" "${start}"
  push
  [ "${status}" -eq 0 ]
}

@test "a session that does not hold the lock exits 3 and pushes nothing" {
  commit_file fix.txt fix
  run bash "${scripts}/push.sh" o/r 7 --session other --worktree "${tmp}/wt" --start "${start}" --branch feat/x
  [ "${status}" -eq 3 ]
  expect "$(remote_head)" "${start}"
}

@test "an allowed push goes out as a plain fast-forward of HEAD and counts one round" {
  commit_file fix.txt fix
  head="$(git rev-parse HEAD)"
  push
  [ "${status}" -eq 0 ]
  expect "$(jq -r .pushed <<<"${output}")" true
  expect "$(jq -r .sha <<<"${output}")" "${head}"
  expect "$(jq -r .rounds <<<"${output}")" 1
  expect "$(remote_head)" "${head}"
  expect "$(ledger '.own.pushes | join(",")')" "${head}"
  expect "$(ledger .rounds)" 1
  expect "$(ledger '.repairs | length')" 0
}

@test "each --check key counts one repair for that check" {
  commit_file fix.txt fix
  push --check "${check_key}" --check "status/lint"
  [ "${status}" -eq 0 ]
  expect "$(ledger ".repairs[\"${check_key}\"]")" 1
  expect "$(ledger '.repairs["status/lint"]')" 1
}

@test "the sha is listed in the ledger before the push reaches origin" {
  commit_file fix.txt fix
  head="$(git rev-parse HEAD)"
  printf '#!/usr/bin/env bash\nbash "%s/ledger.sh" show o/r 7 >"%s/seen"\n' "${scripts}" "${tmp}" >.git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  push
  [ "${status}" -eq 0 ]
  expect "$(jq -r '.own.pushes | join(",")' "${tmp}/seen")" "${head}"
  expect "$(jq -r '.rounds // 0' "${tmp}/seen")" 0
}

@test "a gate park exits 10 with its matches, pushes nothing, and counts nothing" {
  commit_file .github/workflows/ci.yml "name: ci"
  push --check "${check_key}"
  [ "${status}" -eq 10 ]
  expect "$(jq -r .verdict <<<"${output}")" park
  expect "$(jq -r '.matches[0].path' <<<"${output}")" .github/workflows/ci.yml
  expect "$(remote_head)" "${start}"
  expect "$(ledger '.own // "none"')" none
  expect "$(ledger .rounds)" 0
  expect "$(ledger '.repairs | length')" 0
}

@test "a gate refusal exits 11, pushes nothing, and counts nothing" {
  commit_file fix.txt fix
  jq -c '.viewer = "mallory"' "${tmp}/snap.json" >"${tmp}/snap.new"
  mv "${tmp}/snap.new" "${tmp}/snap.json"
  push
  [ "${status}" -eq 11 ]
  expect "$(jq -r .verdict <<<"${output}")" refuse
  expect "$(remote_head)" "${start}"
  expect "$(ledger .rounds)" 0
}

@test "a push that origin rejects exits 1 and counts nothing" {
  commit_file fix.txt fix
  printf '#!/usr/bin/env bash\nexit 1\n' >.git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  push --check "${check_key}"
  [ "${status}" -eq 1 ]
  expect "$(jq -r .pushed <<<"${output}")" false
  expect "$(remote_head)" "${start}"
  expect "$(ledger .rounds)" 0
  expect "$(ledger '.repairs | length')" 0
}
