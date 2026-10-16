#!/usr/bin/env bash
# Tests for issue-refs.sh against throwaway Git repositories.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${script_dir}/issue-refs.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fail=0

# Repo with one base commit plus one commit per argument as its message.
repo() {
  local d m
  d="$(mktemp -d "${work}/repo.XXXXXX")"
  git -C "${d}" init -q -b main
  git -C "${d}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "${d}" branch base
  for m in "$@"; do
    git -C "${d}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m "${m}"
  done
  echo "${d}"
}

run() { # base, messages...
  local base="$1" d
  shift
  d="$(repo "$@")"
  out="$(cd "${d}" && bash "${target}" "${base}" 2>&1)"
  rc=$?
}

expect() { # name, exit code, expected output
  if [[ "${rc}" == "$2" && "${out}" == "$3" ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (exit=${rc})"
    while IFS= read -r line; do echo "    ${line}"; done <<<"${out}"
    fail=1
  fi
}

run base $'feat: a\n\n- why\n\nCloses #5'
expect "single Closes footer" 0 "Closes #5"

run base $'feat: a\n\nRelated #5' $'feat: b\n\nCloses #5'
expect "Related then Closes gives Closes" 0 "Closes #5"

run base $'feat: a\n\nCloses #5' $'fix: b\n\nRelated #5'
expect "Closes then Related is a conflict" 3 "CONFLICT #5"

run base $'feat: a\n\nFixes #7\nresolves: #8\nRelated: #9'
expect "keyword variants map to Closes or Related" 0 $'Closes #7\nCloses #8\nRelated #9'

run base $'feat: a\n\nCloses #12' $'feat: b\n\nRelated #3'
expect "issues are sorted by number" 0 $'Related #3\nCloses #12'

run base $'feat: a\n\nMentions #5 in prose only.'
expect "no footer prints nothing" 0 ""

run nope 'feat: a'
expect "unknown base exits 2" 2 "Usage: issue-refs.sh <base>"

exit "${fail}"
