#!/usr/bin/env bats
# Tests for the release path: `make release` in a sandbox clone with a bare origin, and the guard step of
# .github/workflows/release.yml run against a sandbox repository.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  origin="${BATS_TEST_TMPDIR}/origin.git"
  repo="${BATS_TEST_TMPDIR}/repo"
  stub="${BATS_TEST_TMPDIR}/git-cliff"
  printf '#!/bin/sh\necho v9.9.9\n' > "${stub}"
  chmod +x "${stub}"
}

# sandbox makes $repo on main with the release manifests, a v0.1.0 tag, and one feat commit after it, all pushed to a
# bare $origin.
sandbox() {
  git init -q --bare -b main "${origin}"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.name release
  git config user.email release@example.invalid
  git config core.hooksPath "${repo}/.git/hooks"
  mkdir .claude-plugin
  printf '{\n  "version": "0.1.0"\n}\n' > .claude-plugin/plugin.json
  printf '{\n  "version": "0.1.0"\n}\n' > .claude-plugin/marketplace.json
  cp "${root}/Makefile" Makefile
  git add -A
  git commit -q -m "chore: init"
  git tag -a v0.1.0 -m v0.1.0
  echo one > feature
  git add feature
  git commit -q -m "feat: add feature"
  git remote add origin "${origin}"
  git push -q origin main v0.1.0
}

release() {
  make release CLAUDE=true GIT_CLIFF="${stub}"
}

origin_has_tag() {
  git -C "${origin}" rev-parse -q --verify "refs/tags/v9.9.9" > /dev/null
}

assert_origin_lacks_tag() {
  run origin_has_tag
  [ "${status}" -ne 0 ]
}

@test "make release publishes main and the tag together when main is up to date" {
  sandbox
  run release
  [ "${status}" -eq 0 ]
  run origin_has_tag
  [ "${status}" -eq 0 ]
  [ "$(git -C "${origin}" rev-parse main)" = "$(git rev-parse HEAD)" ]
  [ "$(git -C "${origin}" rev-parse 'v9.9.9^{commit}')" = "$(git rev-parse HEAD)" ]
}

@test "make release publishes neither main nor the tag when local main is behind origin/main" {
  sandbox
  git clone -q "${origin}" "${BATS_TEST_TMPDIR}/other"
  git -C "${BATS_TEST_TMPDIR}/other" -c user.name=o -c user.email=o@example.invalid commit -q --allow-empty -m "fix: ahead"
  git -C "${BATS_TEST_TMPDIR}/other" push -q origin main
  ahead="$(git -C "${origin}" rev-parse main)"
  run release
  [ "${status}" -ne 0 ]
  assert_origin_lacks_tag
  [ "$(git -C "${origin}" rev-parse main)" = "${ahead}" ]
}

@test "make release creates no tag when git commit fails" {
  sandbox
  mkdir -p .git/hooks
  printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  run release
  [ "${status}" -ne 0 ]
  [ -z "$(git tag -l v9.9.9)" ]
  assert_origin_lacks_tag
}

# guard runs the tag-reachability step of release.yml for the commit $1, with the sandbox repository as the checkout.
guard() {
  local script="${BATS_TEST_TMPDIR}/guard.sh"
  ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0])["jobs"]["github-release"]["steps"]
    step = steps.find { |s| s["name"] == "Verify tag is reachable from main" } or abort "step missing"
    puts step["run"]
  ' "${root}/.github/workflows/release.yml" > "${script}" || return 99
  cd "${repo}" || return 1
  GITHUB_SHA="$1" bash "${script}"
}

@test "release.yml fails for a tag commit that is not reachable from main" {
  sandbox
  git checkout -q -b side
  echo side > side
  git add side
  git commit -q -m "feat: side"
  git push -q origin side
  git checkout -q main
  git fetch -q origin
  run guard "$(git rev-parse side)"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not reachable from main"* ]]
}

@test "release.yml passes for a tag commit reachable from main" {
  sandbox
  git fetch -q origin
  run guard "$(git rev-parse HEAD)"
  [ "${status}" -eq 0 ]
}

@test "release.yml checks out full history so origin/main exists" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0])["jobs"]["github-release"]["steps"]
    puts steps.first.dig("with", "fetch-depth")
  ' "${root}/.github/workflows/release.yml"
  [ "${output}" = "0" ]
}
