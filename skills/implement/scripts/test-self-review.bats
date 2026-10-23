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

# Prints a stub OpenCode body that answers `run --help` and `--version` as OpenCode $1 would, then runs $2.
# v2 offers `--standalone` and no `--command`; v1 offers `--command` and no `--standalone`; none offers
# neither; v2-command is a 2.x release offering only `--command`. Help text must not contain `%`.
opencode_stub() {
  local help version=2.0.30
  case "$1" in
  v2) help='      --standalone   run in a private server\n      --agent        agent to use' ;;
  v1)
    help='      --command      the command to run, use message for args\n      --agent        agent to use'
    version=1.19.3
    ;;
  v2-command) help='      --command      the command to run, use message for args' ;;
  none) help='      --agent        agent to use' ;;
  esac
  # shellcheck disable=SC2016 # expanded by the stub, not here
  printf 'if [ "$1 $2" = "run --help" ]; then printf "%s\\n"; exit 0; fi\nif [ "$1" = "--version" ]; then echo %s; exit 0; fi\n%s' \
    "${help}" "${version}" "$2"
}

# Prints the flags in the opencode argv echoed as `ARGS: ...` by the stub, one per line.
argv_flags() {
  local argv arg
  argv="$(sed -n 's/^ARGS: //p' <<<"${output}")"
  [ "${argv#run }" != "${argv}" ] || return 1
  for arg in ${argv#run }; do
    case "${arg}" in -*) printf '%s\n' "${arg}" ;; esac
  done
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
  run_stub "$(opencode_stub v2 'printf "%s" "${OPENCODE_CONFIG_CONTENT}" | jq -c .')" '' opencode
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
  run_stub "$(opencode_stub v2 'echo "ARGS: $*"')" '' opencode
  [ "${status}" -eq 0 ]
  grep -qF -- "ARGS: run --standalone Review the uncommitted changes." <<<"${output}"
  grep -qF -- "one command per bash call" <<<"${output}"
  if grep -qF -- "--agent" <<<"${output}"; then return 1; fi
}

# OpenCode v1 and v2 accept disjoint flags for this call, and each rejects the other's with help and
# exit 1 before reading the diff, so the stub below answers `run --help` like the version under test.
# v2 needs `--standalone` because its shared background service ignores OPENCODE_CONFIG_CONTENT,
# which would leave the deny block below inert. v1 has no such flag, applies the config without it,
# and ships the `review` command.
@test "opencode v2 runs the review standalone, and --standalone is its only flag" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v2 'echo "ARGS: $*"')" '' opencode
  [ "${status}" -eq 0 ]
  [ "$(argv_flags)" = "--standalone" ]
}

@test "opencode v1 runs the review command, and --command is its only flag" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v1 'echo "ARGS: $*"')" '' opencode
  [ "${status}" -eq 0 ]
  grep -qF -- "ARGS: run --command review Review the uncommitted changes." <<<"${output}"
  [ "$(argv_flags)" = "--command" ]
}

@test "opencode without either flag fails before the review runs" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub none 'echo "ARGS: $*"')" '' opencode
  [ "${status}" -eq 1 ]
  if grep -qF -- "ARGS:" <<<"${output}"; then return 1; fi
  grep -qF -- "Unsupported OpenCode CLI" <<<"${output}"
  has_line "REVIEWER_EXIT=unsupported"
}

# A 2.x release that drops `--standalone` would ignore the deny block on the `--command` form.
@test "opencode 2.x offering only --command fails closed" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v2-command 'echo "ARGS: $*"')" '' opencode
  [ "${status}" -eq 1 ]
  if grep -qF -- "ARGS:" <<<"${output}"; then return 1; fi
  has_line "REVIEWER_EXIT=unsupported"
}

@test "missing opencode reports the probe's exit code" {
  if PATH=/usr/bin:/bin command -v opencode >/dev/null; then skip "opencode is on the system PATH"; fi
  run env TMPDIR="${work}" PATH=/usr/bin:/bin bash "${target}" opencode "$(new_repo)"
  [ "${status}" -eq 1 ]
  has_line "REVIEWER_EXIT=127"
}

@test "opencode uses only flags the installed CLI accepts" {
  local real
  real="$(command -v opencode)" || skip "opencode is not installed"
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "if [ \"\$1 \$2\" = \"run --help\" ] || [ \"\$1\" = --version ]; then exec '${real}' \"\$@\"; fi"'
echo "ARGS: $*"' '' opencode
  [ "${status}" -eq 0 ]
  flags="$(argv_flags)"
  [ -n "${flags}" ]
  help="$("${real}" run --help 2>&1)"
  while IFS= read -r arg; do
    grep -qE -- "(^|[[:space:]])${arg}([[:space:],=]|$)" <<<"${help}" || {
      printf 'the installed opencode rejects %s\n' "${arg}"
      return 1
    }
  done <<<"${flags}"
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
  for version in v1 v2; do
    run_stub "$(opencode_stub "${version}" 'touch pwned.txt')" '' opencode
    [ "${status}" -eq 3 ]
    has_line "REVIEWER_CHANGED_WORKTREE"
  done
}

@test "opencode v1 receives the same read-only config as v2" {
  load_opencode_config
  v2="${config}"
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v1 'printf "%s" "${OPENCODE_CONFIG_CONTENT}" | jq -c .')" '' opencode
  [ "${status}" -eq 0 ]
  [ "$(grep -m1 '^{' <<<"${output}")" = "${v2}" ]
}

@test "temp files are removed" {
  run_stub 'true'
  [ "$(find "${work}" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 0 ]
}

# Prints a repo whose `main` gained a commit after `feature` branched from it, with two commits on
# `feature` checked out and a clean worktree, so only committed changes are left to review.
new_range_repo() {
  local d
  d="$(mktemp -d "${work}/range.XXXXXX")"
  g() { git -C "${d}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }
  g init -q -b main
  echo a >"${d}/tracked.txt"
  g add .
  g commit -q -m init
  g switch -q -c feature
  for n in 1 2; do
    echo "${n}" >>"${d}/tracked.txt"
    g commit -q -am "cycle ${n}"
  done
  g switch -q main
  echo m >"${d}/main.txt"
  g add .
  g commit -q -m later
  g switch -q feature
  echo "${d}"
}

# Runs self-review.sh in range mode against main on a fresh range repo, with a stub harness CLI whose body
# is $1; sets ${mb} to the merge base the review must start at.
run_range_stub() {
  local repo bin harness="${2:-claude}"
  repo="$(new_range_repo)"
  mb="$(git -C "${repo}" merge-base main feature)"
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\n%s\n' "$1" >"${bin}/${harness}"
  chmod +x "${bin}/${harness}"
  cd "${repo}" || return 1
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" "${harness}" "${repo}" main
}

@test "claude reviews the committed range from the merge base with a clean worktree" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_range_stub 'echo "ARGS: $*"'
  [ "${status}" -eq 0 ]
  has_line "ARGS: -p /code-review high ${mb}..HEAD --permission-mode plan --no-session-persistence"
}

@test "codex reviews against the merge base instead of the uncommitted changes" {
  # Codex writes its review to the -o file, so the stub echoes its argv there.
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_range_stub 'for a; do [ "${p:-}" = -o ] && f="$a"; p="$a"; done; echo "ARGS: $*" >"$f"' codex
  [ "${status}" -eq 0 ]
  grep -qF -- "ARGS: exec review --base ${mb} --ephemeral" <<<"${output}"
  if grep -qF -- "--uncommitted" <<<"${output}"; then return 1; fi
}

@test "opencode names the committed range in the review message" {
  for version in v1 v2; do
    # shellcheck disable=SC2016 # expanded by the stub, not here
    run_range_stub "$(opencode_stub "${version}" 'echo "ARGS: $*"')" opencode
    [ "${status}" -eq 0 ]
    grep -qF -- "Review the committed changes in ${mb}..HEAD." <<<"${output}"
    if grep -qF -- "uncommitted" <<<"${output}"; then return 1; fi
  done
}

@test "reviewer moving HEAD in range mode exits 3" {
  run_range_stub 'git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m pwned'
  [ "${status}" -eq 3 ]
  has_line "REVIEWER_CHANGED_WORKTREE"
}

# Runs self-review.sh in range mode with base $1 and a claude stub that announces any call.
run_range_base() {
  local bin
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\necho REVIEWER_CALLED\n' >"${bin}/claude"
  chmod +x "${bin}/claude"
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" claude "$(new_range_repo)" "$1"
}

@test "unknown base exits 2 before the review runs" {
  run_range_base no-such-base
  [ "${status}" -eq 2 ]
  if has_line REVIEWER_CALLED; then return 1; fi
}

@test "base with no commits after it exits 2 before the review runs" {
  run_range_base feature
  [ "${status}" -eq 2 ]
  if has_line REVIEWER_CALLED; then return 1; fi
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
