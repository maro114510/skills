#!/usr/bin/env bats
# Tests for gate.sh. Each case builds a bare "GitHub" repository and a clone under a temp directory,
# serves the pull request from a stub pr-state, and answers the gate's two REST reads from a stub gh,
# so no test calls GitHub. A secret-like fixture is assembled at run time so no literal one is committed.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  gate="${scripts}/gate.sh"
  tmp="${BATS_TEST_TMPDIR}"
  token="tok-1"

  # Keep the developer's own Git configuration out of every case.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export BABYSIT_REMOTE_BASE="file://${tmp}/srv"
  export BABYSIT_PR_STATE="${tmp}/pr-state"

  mkdir -p "${tmp}/srv/o" "${tmp}/bin"
  git init -q --bare -b main "${tmp}/srv/o/r.git"
  git init -q --bare -b main "${tmp}/srv/o/other.git"
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

  # The pull request as pr-state would print it.
  clean='{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
    "author":"me","viewer":"me","isCrossRepository":false,"baseRef":"main","headRef":"feat/x","head":"aaa"}'
  set_snap '.'
  printf '#!/usr/bin/env bash\n[ -e "%s/pr-state-fails" ] && exit 1\ncat "%s/snap.json"\n' "${tmp}" "${tmp}" >"${tmp}/pr-state"
  chmod +x "${tmp}/pr-state"

  # gh serves the repository (default branch) and the branch (protected flag).
  printf '{"default_branch":"main"}\n' >"${tmp}/repo.json"
  printf '{"protected":false}\n' >"${tmp}/branch.json"
  cat >"${tmp}/bin/gh" <<EOF
#!/usr/bin/env bash
[ -e "${tmp}/gh-fails" ] && exit 1
case "\$*" in
*/branches/*) cat "${tmp}/branch.json" ;;
*) cat "${tmp}/repo.json" ;;
esac
EOF
  chmod +x "${tmp}/bin/gh"
  export PATH="${tmp}/bin:${PATH}"

  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

# Writes the clean pull request after the jq edit $1.
set_snap() {
  jq -c "$1" <<<"${clean}" >"${tmp}/snap.json"
}

# Commits a file with the content $2 and message $3 in the clone.
commit_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
  git add -- "$1"
  git commit -q -m "${3:-change}"
}

# Runs the gate for a push whose command is the one it would verify for HEAD.
gate_push() {
  run_gate git push origin "$(git rev-parse HEAD):refs/heads/feat/x"
}

# Runs the gate for a push with the command given as arguments.
run_gate() {
  run bash "${gate}" push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" -- "$@"
}

field() {
  jq -r "$1" <<<"${output}"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

# Expects a refuse verdict whose reason contains $1.
expect_refuse() {
  expect "${status}" 11
  expect "$(field .verdict)" refuse
  [[ "$(field .reason)" == *"$1"* ]] || {
    echo "reason [$(field .reason)] lacks [$1]" >&2
    return 1
  }
}

# Expects exit 2 with a usage message for the gate arguments given.
expect_usage() {
  run bash "${gate}" "$@"
  expect "${status}" 2
  [[ "${output}" == *"Usage:"* ]] || {
    echo "no usage message for [$*]; output: ${output}" >&2
    return 1
  }
}

@test "rejects bad arguments with exit 2 and a usage message" {
  expect_usage
  expect_usage bogus o/r 7
  expect_usage push noslash 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 0 --session "${token}" --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 7 --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 7 --session "bad token" --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start nothex -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}"
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/missing" --start "${start}" -- git push
  expect_usage push o/r 7 --session "${token}" --start "${start}" -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" --unknown -- git push
}

@test "exits 3 when another session holds the lock" {
  commit_file src.txt fix
  run bash "${gate}" push o/r 7 --session other-session --worktree "${tmp}/wt" --start "${start}" -- \
    git push origin "$(git rev-parse HEAD):refs/heads/feat/x"
  [ "${status}" -eq 3 ]
}

@test "exits 3 when the lock was cleared" {
  commit_file src.txt fix
  bash "${scripts}/ledger.sh" stop o/r 7 "${token}"
  gate_push
  [ "${status}" -eq 3 ]
}

@test "allows an ordinary fix pushed as a fast-forward of the verified commit" {
  commit_file src.txt "return 1"
  gate_push
  expect "${status}" 0
  expect "$(field .verdict)" allow
  expect "$(field .head)" "$(git rev-parse HEAD)"
  expect "$(field .branch)" feat/x
  expect "$(field .start)" "${start}"
}

@test "refuses a pull request from a fork" {
  commit_file src.txt fix
  set_snap '.isCrossRepository = true'
  gate_push
  expect_refuse fork
}

@test "refuses a pull request when the cross-repository flag is unreadable" {
  commit_file src.txt fix
  set_snap 'del(.isCrossRepository)'
  gate_push
  expect_refuse fork
}

@test "refuses a pull request authored by someone else" {
  commit_file src.txt fix
  set_snap '.author = "mallory"'
  gate_push
  expect_refuse author
}

@test "refuses a pull request without a known author" {
  commit_file src.txt fix
  set_snap '.author = null'
  gate_push
  expect_refuse author
}

@test "refuses a closed pull request" {
  commit_file src.txt fix
  set_snap '.state = "CLOSED"'
  gate_push
  expect_refuse open
}

@test "refuses a merged pull request" {
  commit_file src.txt fix
  set_snap '.state = "MERGED"'
  gate_push
  expect_refuse open
}

@test "refuses a pull request whose snapshot is for another repository" {
  commit_file src.txt fix
  set_snap '.repo = "o/elsewhere"'
  gate_push
  expect_refuse "another pull request"
}

@test "refuses when the head branch is the default branch" {
  git switch -q main
  local main_tip
  main_tip="$(git rev-parse HEAD)"
  commit_file src.txt fix
  set_snap '.headRef = "main"'
  run bash "${gate}" push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${main_tip}" -- \
    git push origin "$(git rev-parse HEAD):refs/heads/main"
  expect_refuse "default branch"
}

@test "refuses when the head branch is protected" {
  commit_file src.txt fix
  printf '{"protected":true}\n' >"${tmp}/branch.json"
  gate_push
  expect_refuse protected
}

@test "refuses when the branch cannot be read from GitHub" {
  commit_file src.txt fix
  : >"${tmp}/gh-fails"
  gate_push
  expect_refuse "could not"
}

@test "refuses when the pull request cannot be read" {
  commit_file src.txt fix
  : >"${tmp}/pr-state-fails"
  gate_push
  expect_refuse "could not"
}

@test "refuses when the remote head has moved ahead of the start" {
  commit_file src.txt fix
  git clone -q "file://${tmp}/srv/o/r.git" "${tmp}/other" 2>/dev/null
  (
    cd "${tmp}/other" || exit 1
    git switch -q feat/x
    printf 'theirs\n' >theirs.txt
    git add -- theirs.txt
    git commit -q -m theirs
    git push -q origin feat/x
  )
  gate_push
  expect_refuse "moved"
}

@test "refuses when the remote branch does not exist" {
  commit_file src.txt fix
  git push -q origin --delete feat/x
  gate_push
  expect_refuse "moved"
}

@test "refuses when there is nothing new to push" {
  gate_push
  expect_refuse "nothing"
}

@test "refuses when the start commit is not an ancestor of HEAD" {
  commit_file src.txt fix
  git reset -q --hard "${start}^"
  gate_push
  expect_refuse "descend"
}

@test "refuses when origin fetches from another repository" {
  commit_file src.txt fix
  git remote set-url origin "file://${tmp}/srv/o/other.git"
  gate_push
  expect_refuse origin
}

@test "refuses when origin pushes to another repository" {
  commit_file src.txt fix
  git remote set-url --push origin "file://${tmp}/srv/o/other.git"
  gate_push
  expect_refuse origin
}

@test "refuses when a rewrite rule sends the push elsewhere" {
  commit_file src.txt fix
  git config "url.file://${tmp}/srv/o/other.git.pushInsteadOf" "file://${tmp}/srv/o/r.git"
  gate_push
  expect_refuse origin
}

@test "refuses a push command that differs from the verified one" {
  commit_file src.txt fix
  head="$(git rev-parse HEAD)"
  other="$(git rev-parse HEAD^)"
  local -a variants=(
    "git push --force origin ${head}:refs/heads/feat/x"
    "git push --force-with-lease=refs/heads/feat/x:${start} origin ${head}:refs/heads/feat/x"
    "git push origin +${head}:refs/heads/feat/x"
    "git push origin HEAD:refs/heads/feat/x"
    "git push origin ${head}:refs/heads/main"
    "git push origin ${other}:refs/heads/feat/x"
    "git push origin ${head}:refs/heads/feat/x --no-verify"
    "git push upstream ${head}:refs/heads/feat/x"
    "git push origin"
  )
  for variant in "${variants[@]}"; do
    # shellcheck disable=SC2086 # the variant is split into words on purpose.
    run_gate ${variant}
    echo "variant: ${variant}" >&2
    expect_refuse "command"
  done
}

@test "prints exactly one JSON line for a refusal" {
  commit_file src.txt fix
  set_snap '.state = "CLOSED"'
  gate_push
  expect "$(wc -l <<<"${output}" | tr -d ' ')" 1
  jq -e 'has("verdict") and has("reason")' <<<"${output}" >/dev/null
}
