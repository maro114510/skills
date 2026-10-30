#!/usr/bin/env bash
# Tests for lang.sh in throwaway Git repositories whose only configuration is what each case sets.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${script_dir}/lang.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fail=0
# The user's own skills.lang must not leak into a case.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# A fresh repository, so local config set by one case never reaches another.
repo_with() { # [skills.lang value]
  repo="$(mktemp -d "${work}/repo.XXXXXX")"
  git init -q "${repo}"
  [[ $# -gt 0 ]] && git -C "${repo}" config skills.lang "$1"
  return 0
}

run() {
  out="$(cd "${repo}" && bash "${target}" "$@" 2>"${work}/err")"
  rc=$?
  err="$(cat "${work}/err")"
}

check() { # name, condition result (0 pass)
  if [[ "$2" == 0 ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (exit=${rc})"
    echo "    stdout: ${out}"
    echo "    stderr: ${err}"
    fail=1
  fi
}

repo_with en
run
[[ "${rc}" == 0 && "${out}" == "en (git config)" ]]
check "skills.lang=en and no argument: en from git config" $?

repo_with en
run ja
[[ "${rc}" == 0 && "${out}" == "ja (argument)" ]]
check "argument ja with skills.lang=en: the argument wins" $?

repo_with
run
[[ "${rc}" == 0 && "${out}" == "ja (default)" ]]
check "no argument and no skills.lang: ja by default" $?

repo_with fr
run
[[ "${rc}" == 2 && -z "${out}" && "${err}" == 'Invalid language "fr" from git config skills.lang; use ja or en.' ]]
check "skills.lang=fr: exit 2 naming the value and the key, nothing on stdout" $?

repo_with
run fr
[[ "${rc}" == 2 && -z "${out}" && "${err}" == 'Invalid language "fr" from argument lang; use ja or en.' ]]
check "argument fr: exit 2 naming the value and the argument" $?

repo_with ''
run
[[ "${rc}" == 2 && -z "${out}" && "${err}" == 'Invalid language "" from git config skills.lang; use ja or en.' ]]
check "empty skills.lang: exit 2 instead of the default" $?

repo_with
run ''
[[ "${rc}" == 2 && -z "${out}" && "${err}" == 'Invalid language "" from argument lang; use ja or en.' ]]
check "empty argument: exit 2 instead of reading git config" $?

repo_with fr
run en
[[ "${rc}" == 0 && "${out}" == "en (argument)" ]]
check "argument en with skills.lang=fr: a broken config cannot block the argument" $?

repo_with
run ja en
[[ "${rc}" == 2 && -z "${out}" && "${err}" == "Usage: lang.sh [<value>]" ]]
check "two arguments: exit 2 with usage" $?

repo_with
printf '[broken\n' >>"${repo}/.git/config"
run
[[ "${rc}" == 1 && -z "${out}" && "${err}" == *"config"* ]]
check "unreadable git config: exit 1 with git's error, not the default" $?

exit "${fail}"
