#!/usr/bin/env bash
# Tests for self-review.sh, using a stub reviewer CLI on PATH.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${script_dir}/self-review.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fail=0

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

# Runs self-review.sh against a fresh repo with a stub `claude` whose body is $1, after running setup $2 in the repo.
run_stub() {
  local repo bin
  repo="$(new_repo)"
  (cd "${repo}" && eval "${2:-true}")
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\n%s\n' "$1" >"${bin}/claude"
  chmod +x "${bin}/claude"
  out="$(cd "${repo}" && TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" claude "${repo}")"
  rc=$?
}

expect() { # name, expected exit code, [line the output must contain]
  local ok=1
  [[ "${rc}" == "$2" ]] || ok=0
  if [[ $# -ge 3 ]] && ! grep -qx -- "$3" <<<"${out}"; then ok=0; fi
  if [[ "${ok}" == 1 ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (exit=${rc})"
    while IFS= read -r line; do echo "    ${line}"; done <<<"${out}"
    fail=1
  fi
}

run_stub 'echo "no findings"'
expect "clean run exits 0 and prints the output" 0 "no findings"

run_stub 'echo boom; exit 3'
expect "reviewer failure exits 1 and reports its code" 1 "REVIEWER_EXIT=3"

run_stub 'echo c >> tracked.txt'
expect "edit to a tracked file exits 3" 3

run_stub 'touch pwned.txt'
expect "new untracked file exits 3" 3

run_stub 'echo x >> untracked.txt'
expect "edit to an existing untracked file exits 3" 3

run_stub 'git add tracked.txt'
expect "staging change exits 3" 3

run_stub 'printf 1 > "日本語.txt"'
expect "new file with a quoted name exits 3" 3

run_stub 'echo 2 >> "日本語.txt"' 'echo 1 > "日本語.txt"'
expect "edit to an existing untracked file with a quoted name exits 3" 3

run_stub 'echo x >> tracked.txt; exit 1'
expect "worktree change wins over reviewer failure" 3

run_stub 'echo out/ >> .git/info/exclude; mkdir out; touch out/x'
expect "gitignored output is not a change" 0

run_stub 'printf "finding without newline"'
expect "output without trailing newline stays on its own line" 0 "finding without newline"

run_stub 'true'
leftover="$(find "${work}" -maxdepth 1 -type f | wc -l | tr -d ' ')"
rc="${leftover}" out=""
expect "temp files are removed" 0

repo="$(new_repo)"
out="$(bash "${target}" gemini "${repo}" 2>&1)"
rc=$?
expect "unsupported harness exits 2" 2

out="$(bash "${target}" claude "${work}/missing" 2>&1)"
rc=$?
expect "missing worktree exits 2" 2

out="$(bash "${target}" claude "$(mktemp -d "${work}/nogit.XXXXXX")" 2>&1)"
rc=$?
expect "directory outside a Git worktree exits 2" 2

exit "${fail}"
