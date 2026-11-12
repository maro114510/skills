#!/usr/bin/env bats
# Tests for scan-secrets.sh, against a throwaway repository.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/scan-secrets.sh"
  repo="${BATS_TEST_TMPDIR}/repo"
  # A developer's global config and hooks must not reach the repository under test.
  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.name t
  git config user.email t@t
  git config core.hooksPath /dev/null
  echo 'base' >app.yml
  git add app.yml
  git commit -q -m "chore: init"
}

scan() {
  run bash "${target}"
}

# Succeeds when the output holds line $1 exactly.
has_line() {
  printf '%s\n' "${output}" | grep -qxF -- "$1"
}

@test "a staged line assigning a GitHub fine-grained token is excluded with its line number" {
  fine_grained='A1b2C3d4E5f6G7h8I9j0Kl'
  printf 'token: github_pat_%s\n' "${fine_grained}" >config.yml
  git add config.yml

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: config.yml:1: token"
}

@test "a clean change is not excluded" {
  echo 'base2' >app.yml
  git add app.yml

  scan

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "a staged file named for a secret is excluded by its name" {
  printf 'FOO=\n' >.env
  git add .env

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: .env: secret file"
}

@test "a placeholder file named for a secret is not excluded by its name" {
  printf 'TOKEN=\n' >.env.example
  git add .env.example

  scan

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "an untracked file holding an AWS access key is excluded" {
  suffix="$(printf 'B%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)"
  printf 'aws_access_key_id = AKIA%s\n' "${suffix}" >notes.txt

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: notes.txt:1: token"
}

@test "an unstaged line assigning a literal password is excluded" {
  printf 'base2\npassword = "%s"\n' 'hunter2hunter2' >app.yml

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: app.yml:2: assignment"
}

@test "the matched value is never printed" {
  fine_grained='A1b2C3d4E5f6G7h8I9j0Kl'
  printf 'token: github_pat_%s\n' "${fine_grained}" >config.yml
  git add config.yml

  scan

  [ "${status}" -eq 10 ]
  if printf '%s\n' "${output}" | grep -qF -- "${fine_grained}"; then
    echo "the output holds the matched value" >&2
    return 1
  fi
}

@test "a staged path holding a space is excluded with its whole path" {
  fine_grained='A1b2C3d4E5f6G7h8I9j0Kl'
  mkdir -p 'sub dir'
  printf 'token: github_pat_%s\n' "${fine_grained}" >'sub dir/my config.yml'
  git add 'sub dir/my config.yml'

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: sub dir/my config.yml:1: token"
}

@test "a staged path holding a quote is excluded with its real path" {
  fine_grained='A1b2C3d4E5f6G7h8I9j0Kl'
  printf 'token: github_pat_%s\n' "${fine_grained}" >'say "hi".txt'
  git add 'say "hi".txt'

  scan

  [ "${status}" -eq 10 ]
  has_line 'excluded: say "hi".txt:1: token'
}

@test "a staged private key header is excluded" {
  printf -- '-----BEGIN %s PRIVATE KEY-----\n' 'RSA' >key.txt
  git add key.txt

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: key.txt:1: private key"
}

@test "a run from a subdirectory screens an untracked file at the repository root" {
  suffix="$(printf 'B%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)"
  printf 'aws_access_key_id = AKIA%s\n' "${suffix}" >notes.txt
  mkdir -p sub
  cd sub || return 1

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: notes.txt:1: token"
}

@test "a repository without a commit is screened" {
  fresh="${BATS_TEST_TMPDIR}/fresh"
  git init -q -b main "${fresh}"
  cd "${fresh}" || return 1
  git config user.name t
  git config user.email t@t
  fine_grained='A1b2C3d4E5f6G7h8I9j0Kl'
  printf 'token: github_pat_%s\n' "${fine_grained}" >config.yml
  git add config.yml

  scan

  [ "${status}" -eq 10 ]
  has_line "excluded: config.yml:1: token"
}
