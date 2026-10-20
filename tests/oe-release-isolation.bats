#!/usr/bin/env bats
# An oe-v tag publishes the oe binaries and must change nothing about plugin v releases.
# That covers the release workflow, git-cliff version inference, and make next-version.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  work="$(mktemp -d)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
}

teardown() {
  rm -rf "${work}"
}

# Prints the tag globs a workflow triggers on, one per line.
tag_globs() {
  awk '
    /^[[:space:]]+tags:[[:space:]]*$/ { in_tags = 1; next }
    in_tags && /^[[:space:]]+-[[:space:]]/ {
      glob = $0
      sub(/^[[:space:]]+-[[:space:]]+/, "", glob)
      gsub(/[\047"]/, "", glob)
      print glob
      next
    }
    { in_tags = 0 }
  ' "$1"
}

# Succeeds when a tag filter glob matches the whole tag name, as GitHub matches them.
matches_any() {
  local name="$1" glob
  shift
  for glob in "$@"; do
    # shellcheck disable=SC2254 # the glob is data to match against.
    case "${name}" in
    ${glob}) return 0 ;;
    esac
  done
  return 1
}

# Builds a repository with a plugin release tag and a releasable commit.
# With the argument with-oe, an oe-v9.0.0 tag and another releasable commit follow.
make_repo() {
  mkdir "${work}/repo"
  cd "${work}/repo" || return 1
  git init -q
  git config user.email t@example.com
  git config user.name tester
  git config commit.gpgsign false
  mkdir .claude-plugin
  printf '{\n  "version": "0.27.0"\n}\n' >.claude-plugin/plugin.json
  printf '{\n  "version": "0.27.0"\n}\n' >.claude-plugin/marketplace.json
  cp "${repo_root}/cliff.toml" "${repo_root}/Makefile" .
  git add .
  git -c core.hooksPath=/dev/null commit -q -m 'chore: baseline'
  git tag -a v0.27.0 -m v0.27.0
  git -c core.hooksPath=/dev/null commit -q --allow-empty -m 'feat: add a thing'
  if [ "${1:-}" = "with-oe" ]; then
    git tag -a oe-v9.0.0 -m oe-v9.0.0
    git -c core.hooksPath=/dev/null commit -q --allow-empty -m 'fix: repair a thing'
  else
    git -c core.hooksPath=/dev/null commit -q --allow-empty -m 'fix: repair a thing'
  fi
}

@test "cliff tag_pattern matches plugin release tags" {
  pattern="$(sed -nE 's/^tag_pattern[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "${repo_root}/cliff.toml")"
  [ -n "${pattern}" ]
  for tag in v0.27.0 v0.28.0 v1.0.0 v10.20.30; do
    printf '%s\n' "${tag}" | grep -Eq -- "${pattern}"
  done
}

@test "cliff tag_pattern does not match oe tags" {
  pattern="$(sed -nE 's/^tag_pattern[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "${repo_root}/cliff.toml")"
  [ -n "${pattern}" ]
  for tag in oe-v1.0.0 oe-v0.1.0 oe-v10.2.3 other-v1.0.0; do
    if printf '%s\n' "${tag}" | grep -Eq -- "${pattern}"; then false; fi
  done
}

@test "git-cliff infers the same next version with and without an oe tag" {
  command -v git-cliff >/dev/null || skip "git-cliff is not installed"
  make_repo without-oe
  without="$(git-cliff --bumped-version 2>/dev/null)"
  cd "${work}" && rm -rf repo
  make_repo with-oe
  with="$(git-cliff --bumped-version 2>/dev/null)"
  [ "${without}" = "v0.28.0" ]
  [ "${with}" = "${without}" ]
}

@test "make next-version prints the same result with and without an oe tag" {
  command -v git-cliff >/dev/null || skip "git-cliff is not installed"
  make_repo without-oe
  without="$(make next-version 2>&1 | tail -n 1)"
  cd "${work}" && rm -rf repo
  make_repo with-oe
  with="$(make next-version 2>&1 | tail -n 1)"
  [ "${without}" = "0.28.0" ]
  [ "${with}" = "${without}" ]
}

@test "release.yml does not trigger on an oe tag" {
  globs=()
  while IFS= read -r glob; do globs+=("${glob}"); done < <(tag_globs "${repo_root}/.github/workflows/release.yml")
  [ "${#globs[@]}" -gt 0 ]
  matches_any v0.28.0 "${globs[@]}"
  if matches_any oe-v1.0.0 "${globs[@]}"; then false; fi
}

@test "oe-release.yml triggers on oe tags and never on plugin tags" {
  globs=()
  while IFS= read -r glob; do globs+=("${glob}"); done < <(tag_globs "${repo_root}/.github/workflows/oe-release.yml")
  [ "${#globs[@]}" -gt 0 ]
  matches_any oe-v1.0.0 "${globs[@]}"
  if matches_any v0.28.0 "${globs[@]}"; then false; fi
}
