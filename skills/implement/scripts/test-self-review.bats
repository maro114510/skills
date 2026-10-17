#!/usr/bin/env bats
# Tests for self-review.sh, using a stub reviewer CLI on PATH.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/self-review.sh"
  work="${BATS_TEST_TMPDIR}"
}

new_repo() {
  local d
  d="$(mktemp -d "${work}/repo.XXXXXX")"
  git -C "${d}" init -q -b main
  echo a >"${d}/tracked.txt"
  git -C "${d}" add .
  git -C "${d}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m init
  echo b >>"${d}/tracked.txt"
  echo u >"${d}/untracked.txt"
  echo "${d}"
}

# Runs self-review.sh against a fresh repo with a stub harness CLI (default `claude`) whose body is $1,
# after running setup $2 in the repo.
run_stub() {
  local repo bin harness="${3:-claude}"
  repo="$(new_repo)"
  (cd "${repo}" && eval "${2:-true}")
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\n%s\n' "$1" >"${bin}/${harness}"
  chmod +x "${bin}/${harness}"
  cd "${repo}" || return 1
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" "${harness}" "${repo}"
}

# Succeeds when the output has a line exactly equal to $1.
has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

# Mirrors OpenCode's Wildcard.match: `*` and `?` are wildcards, a trailing ` *` also matches nothing, anchored.
wildcard_re() {
  local re
  re="$(printf '%s' "$1" | sed -e 's/[]\\.+^${}()|[]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g')"
  [[ "${re}" == *" .*" ]] && re="${re% .\*}( .*)?"
  printf '^%s$' "${re}"
}

# Prints the bash permission OpenCode resolves for command $1 under ${config}; the last matching rule wins.
bash_permission() {
  local verdict=none action pattern re
  while IFS=$'\t' read -r action pattern; do
    re="$(wildcard_re "${pattern}")"
    [[ "$1" =~ ${re} ]] && verdict="${action}"
  done < <(jq -r '.permission.bash | to_entries[] | "\(.value)\t\(.key)"' <<<"${config}")
  printf '%s' "${verdict}"
}

# Sets ${config} to the OpenCode config self-review.sh passes to the reviewer.
load_opencode_config() {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub 'printf "%s" "${OPENCODE_CONFIG_CONTENT}" | jq -c .' '' opencode
  [ "${status}" -eq 0 ]
  config="$(grep -m1 '^{' <<<"${output}")"
  [ -n "${config}" ]
}

# Fails listing every command in $2.. whose resolved permission is not $1.
expect_permission() {
  local want="$1" c bad=()
  shift
  for c in "$@"; do
    [[ "$(bash_permission "${c}")" == "${want}" ]] || bad+=("${c}")
  done
  if [ "${#bad[@]}" -ne 0 ]; then
    printf 'not %s: %s\n' "${want}" "${bad[@]}"
    return 1
  fi
}

@test "clean run exits 0 and prints the output" {
  run_stub 'echo "no findings"'
  [ "${status}" -eq 0 ]
  has_line "no findings"
}

@test "reviewer failure exits 1 and reports its code" {
  run_stub 'echo boom; exit 3'
  [ "${status}" -eq 1 ]
  has_line "REVIEWER_EXIT=3"
}

@test "edit to a tracked file exits 3" {
  run_stub 'echo c >> tracked.txt'
  [ "${status}" -eq 3 ]
}

@test "new untracked file exits 3" {
  run_stub 'touch pwned.txt'
  [ "${status}" -eq 3 ]
}

@test "edit to an existing untracked file exits 3" {
  run_stub 'echo x >> untracked.txt'
  [ "${status}" -eq 3 ]
}

@test "staging change exits 3" {
  run_stub 'git add tracked.txt'
  [ "${status}" -eq 3 ]
}

@test "new file with a quoted name exits 3" {
  run_stub 'printf 1 > "日本語.txt"'
  [ "${status}" -eq 3 ]
}

@test "edit to an existing untracked file with a quoted name exits 3" {
  run_stub 'echo 2 >> "日本語.txt"' 'echo 1 > "日本語.txt"'
  [ "${status}" -eq 3 ]
}

@test "worktree change wins over reviewer failure" {
  run_stub 'echo x >> tracked.txt; exit 1'
  [ "${status}" -eq 3 ]
}

@test "gitignored output is not a change" {
  run_stub 'echo out/ >> .git/info/exclude; mkdir out; touch out/x'
  [ "${status}" -eq 0 ]
}

@test "output without trailing newline stays on its own line" {
  run_stub 'printf "finding without newline"'
  [ "${status}" -eq 0 ]
  has_line "finding without newline"
}

@test "opencode passes the review prompt as the message and asks for one command per call" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub 'echo "ARGS: $*"' '' opencode
  [ "${status}" -eq 0 ]
  grep -qF -- "ARGS: run --standalone Review the uncommitted changes." <<<"${output}"
  grep -qF -- "one command per bash call" <<<"${output}"
  if grep -qF -- "--command" <<<"${output}"; then return 1; fi
  if grep -qF -- "--agent" <<<"${output}"; then return 1; fi
}

# `run --command review` named a flag OpenCode V2 does not have, so the CLI printed help and exited
# 1 before reading the diff: no OpenCode review ever ran, and the stub below cannot notice because it
# accepts any argument. `--standalone` is pinned because the shared background service ignores
# OPENCODE_CONFIG_CONTENT, which would leave the deny block below inert. The installed CLI's own
# flags are checked in the test after this one.
@test "opencode runs the review standalone, and --standalone is its only flag" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub 'echo "ARGS: $*"' '' opencode
  [ "${status}" -eq 0 ]
  argv="$(sed -n 's/^ARGS: //p' <<<"${output}")"
  [ "${argv#run }" != "${argv}" ] || return 1
  for arg in ${argv#run }; do
    case "${arg}" in
    -*) [ "${arg}" = "--standalone" ] || {
      printf 'unexpected flag passed to opencode run: %s\n' "${arg}"
      return 1
    } ;;
    esac
  done
}

@test "opencode uses only flags the installed CLI accepts" {
  command -v opencode >/dev/null 2>&1 || skip "opencode is not installed"
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub 'echo "ARGS: $*"' '' opencode
  [ "${status}" -eq 0 ]
  argv="$(sed -n 's/^ARGS: //p' <<<"${output}")"
  help="$(opencode run --help 2>&1)"
  for arg in ${argv#run }; do
    case "${arg}" in
    -*) grep -qF -- "${arg}" <<<"${help}" || {
      printf 'the installed opencode rejects %s\n' "${arg}"
      return 1
    } ;;
    esac
  done
}

@test "opencode allows read-only review commands" {
  load_opencode_config
  expect_permission allow "git diff" "git diff --cached" "git status --short" "git log -5" "git show HEAD" \
    "git ls-files" "git branch --show-current" "git rev-parse HEAD" "git merge-base HEAD origin/main" \
    "git blame main.go" "echo ---" "head -n 20 main.go" "cat AGENTS.md" "ls" "ls -la pkg" "rg -n foo" "go vet ./..." "go test ./..." \
    "go test -run TestX ./pkg/..."
}

@test "opencode denies writes and commands that run another program" {
  load_opencode_config
  expect_permission deny "git branch new" "git commit -m x" "git checkout ." "git diff --output=x" \
    "rm -rf x" "make" "echo x > f" "echo x >> f" "cat a > b" "go test -exec sh ./..." "go test -toolexec x ./..." \
    "go vet -vettool=x ./..." "go build ./..." "rg --pre sh foo" "rg --pre=sh foo" "rg --hostname-bin=sh foo"
}

@test "opencode reviewer writing a file exits 3" {
  run_stub 'touch pwned.txt' '' opencode
  [ "${status}" -eq 3 ]
  has_line "REVIEWER_CHANGED_WORKTREE"
}

@test "temp files are removed" {
  run_stub 'true'
  [ "$(find "${work}" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "unsupported harness exits 2" {
  run bash "${target}" gemini "$(new_repo)"
  [ "${status}" -eq 2 ]
}

@test "missing worktree exits 2" {
  run bash "${target}" claude "${work}/missing"
  [ "${status}" -eq 2 ]
}

@test "directory outside a Git worktree exits 2" {
  run bash "${target}" claude "$(mktemp -d "${work}/nogit.XXXXXX")"
  [ "${status}" -eq 2 ]
}
