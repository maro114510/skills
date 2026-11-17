#!/usr/bin/env bats
# Tests for the release path: `make release` in a sandbox clone with a bare origin, and the guards and notes of
# .github/scripts/release.sh, which .github/workflows/release.yml runs, against a sandbox repository.
# shellcheck disable=SC2030,SC2031 # output_has and output_lacks read ${output} inside the same @test subshell that `run` set it in.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

bats_require_minimum_version 1.5.0

setup() {
  root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  origin="${BATS_TEST_TMPDIR}/origin.git"
  repo="${BATS_TEST_TMPDIR}/repo"
  stub="${BATS_TEST_TMPDIR}/git-cliff"
  printf '#!/bin/sh\necho v9.9.9\n' >"${stub}"
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
  printf '{\n  "version": "0.1.0"\n}\n' >.claude-plugin/plugin.json
  printf '{\n  "version": "0.1.0"\n}\n' >.claude-plugin/marketplace.json
  cp "${root}/Makefile" Makefile
  git add -A
  git commit -q -m "chore: init"
  git tag -a v0.1.0 -m v0.1.0
  echo one >feature
  git add feature
  git commit -q -m "feat: add feature"
  git remote add origin "${origin}"
  git push -q origin main v0.1.0
}

release() {
  make release CLAUDE=true GIT_CLIFF="${stub}"
}

origin_has_tag() {
  git -C "${origin}" rev-parse -q --verify "refs/tags/v9.9.9" >/dev/null
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
  [[ "${output}" == *"[rejected]"* ]]
  assert_origin_lacks_tag
  [ "$(git -C "${origin}" rev-parse main)" = "${ahead}" ]
}

@test "make release creates no tag when git commit fails" {
  sandbox
  mkdir -p .git/hooks
  printf '#!/bin/sh\nexit 1\n' >.git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  run release
  [ "${status}" -ne 0 ]
  [ -z "$(git tag -l v9.9.9)" ]
  assert_origin_lacks_tag
}

# Release flow sandbox. main holds the legacy tag v1.2.0, which is its own Run commit, then the Run commit $run and
# one commit after it, all pushed to a bare $origin. Releases are cut on a branch from a Run commit.
flow_sandbox() {
  git init -q --bare -b main "${origin}"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.name release
  git config user.email release@example.invalid
  git config core.hooksPath "${repo}/.git/hooks"
  mkdir .claude-plugin
  printf '{"name":"skills","version":"1.2.0"}\n' >.claude-plugin/plugin.json
  printf '{"name":"m","version":"1.2.0","plugins":[{"name":"skills","source":{"source":"github","repo":"o/r","ref":"v1.2.0"}}]}\n' \
    >.claude-plugin/marketplace.json
  printf 'npx skills add o/r#v1.2.0\napm install o/r#^1.0.0\nplain text\n' >README.md
  cp "${root}/cliff.toml" cliff.toml
  git add -A
  git commit -q -m "feat: before the previous release"
  echo base >file
  git add file
  git commit -q -m "chore: release v1.2.0"
  git tag -a v1.2.0 -m v1.2.0
  commit_on_main "feat: first run" first
  run="$(git rev-parse HEAD)"
  commit_on_main "fix: after the run" second
  git remote add origin "${origin}"
  git push -q origin main v1.2.0
  git fetch -q origin
}

commit_on_main() {
  echo "$2" >"$2"
  git add "$2"
  git commit -q -m "$1"
}

# bump_release starts a Release branch at $1 and rewrites every field the Bump commit sets for version $2.
# The APM range names major version $3.
bump_release() {
  git checkout -q -b "release-$2" "$1"
  local v="$2" major="$3" tag="v$2"
  jq --arg v "${v}" '.version = $v' .claude-plugin/plugin.json >p.tmp && mv p.tmp .claude-plugin/plugin.json
  jq --arg v "${v}" --arg t "${tag}" '.version = $v | .plugins[0].source.ref = $t' .claude-plugin/marketplace.json \
    >m.tmp && mv m.tmp .claude-plugin/marketplace.json
  sed -E -i.bak "s/#v[0-9]+\.[0-9]+\.[0-9]+/#${tag}/; s/#\^[0-9]+\.0\.0/#^${major}.0.0/" README.md
  rm -f README.md.bak
}

# commit_tag commits what the Bump commit changed and tags it as v$1.
commit_tag() {
  git add -A
  git commit -q -m "chore: release v$1"
  git tag -a "v$1" -m "v$1"
}

# cut makes a valid Release v$2 from $1 with the APM range of major version $3.
cut() {
  bump_release "$1" "$2" "$3"
  commit_tag "$2"
}

# output_has and output_lacks fail by returning, because a failed [[ ]] in the middle of a test passes under bash 3.2.
output_has() {
  case "${output}" in
  *"$1"*) ;;
  *)
    echo "output lacks: $1"
    return 1
    ;;
  esac
}

output_lacks() {
  case "${output}" in
  *"$1"*)
    echo "output has: $1"
    return 1
    ;;
  esac
}

release_guard() {
  bash "${root}/.github/scripts/release.sh" guard "$@"
}

@test "guard passes a Bump commit on a Release branch above the Run commit" {
  flow_sandbox
  cut "${run}" 1.3.0 1
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -eq 0 ]
}

@test "guard passes a major release whose Bump commit moves the APM range" {
  flow_sandbox
  cut "${run}" 2.0.0 2
  run release_guard v2.0.0 v1.2.0
  [ "${status}" -eq 0 ]
}

@test "guard refuses a version that is not above the previous release" {
  flow_sandbox
  cut "${run}" 1.1.9 1
  run release_guard v1.1.9 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "not above"
}

@test "guard refuses a tag that is not v<major>.<minor>.<patch>" {
  flow_sandbox
  cut "${run}" 1.3.0-rc1 1
  run release_guard v1.3.0-rc1 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "not v<major>.<minor>.<patch>"
}

@test "guard refuses a tag commit with two parents" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  git add -A
  git commit -q -m "chore: release v1.3.0"
  git checkout -q main
  git merge -q --no-ff -m "chore: release v1.3.0" release-1.3.0
  git tag -a v1.3.0 -m v1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "one parent"
}

@test "guard refuses a Run commit that main does not reach" {
  flow_sandbox
  git checkout -q -b side "${run}"
  commit_on_main "feat: side only" side
  cut "$(git rev-parse HEAD)" 1.3.0 1
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "not reachable from origin/main"
}

@test "guard refuses a Run commit that does not descend from the previous release's Run commit" {
  flow_sandbox
  cut "${run}" 1.3.0 1
  git checkout -q main
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -eq 0 ]
  cut "$(git rev-parse "${run}^")" 1.4.0 1
  run release_guard v1.4.0 v1.3.0
  [ "${status}" -ne 0 ]
  output_has "does not descend from the previous release's Run commit"
}

@test "guard takes a previous Release tag's parent as its Run commit" {
  flow_sandbox
  cut "${run}" 1.3.0 1
  git checkout -q main
  git push -q origin v1.3.0
  commit_on_main "feat: second run" third
  git push -q origin main
  git fetch -q origin
  cut "$(git rev-parse HEAD)" 1.4.0 1
  run release_guard v1.4.0 v1.3.0
  [ "${status}" -eq 0 ]
}

@test "guard refuses a Bump commit that changes another file" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  echo changed >file
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "changes file, which a Bump commit may not"
}

@test "guard refuses a Bump commit that changes a manifest field other than the version and ref" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  jq '.name = "renamed"' .claude-plugin/plugin.json >p.tmp && mv p.tmp .claude-plugin/plugin.json
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has ".claude-plugin/plugin.json changes more than the version"
}

@test "guard refuses a Bump commit that changes a marketplace field other than the version and ref" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  jq '.plugins[0].name = "renamed"' .claude-plugin/marketplace.json >m.tmp && mv m.tmp .claude-plugin/marketplace.json
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has ".claude-plugin/marketplace.json changes more than the version"
}

@test "guard refuses a plugin manifest version that differs from the tag" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  jq '.version = "1.3.1"' .claude-plugin/plugin.json >p.tmp && mv p.tmp .claude-plugin/plugin.json
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has ".claude-plugin/plugin.json has version 1.3.1, expected 1.3.0"
}

@test "guard refuses a marketplace version that differs from the tag" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  jq '.version = "1.2.0"' .claude-plugin/marketplace.json >m.tmp && mv m.tmp .claude-plugin/marketplace.json
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has ".claude-plugin/marketplace.json has version 1.2.0, expected 1.3.0"
}

@test "guard refuses a marketplace entry ref that does not name the tag" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  jq '.plugins[0].source.ref = "v1.2.0"' .claude-plugin/marketplace.json >m.tmp && mv m.tmp .claude-plugin/marketplace.json
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "ref v1.2.0, expected v1.3.0"
}

@test "guard refuses a README npx skills tag that does not name the tag" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  sed -i.bak 's/#v1.3.0/#v1.2.0/' README.md
  rm -f README.md.bak
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "README.md names #v1.2.0, expected #v1.3.0"
}

@test "guard refuses a README APM range that does not name the major version" {
  flow_sandbox
  bump_release "${run}" 2.0.0 1
  commit_tag 2.0.0
  run release_guard v2.0.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "README.md names #^1.0.0, expected #^2.0.0"
}

@test "guard refuses a Bump commit that changes a README line other than those tokens" {
  flow_sandbox
  bump_release "${run}" 1.3.0 1
  echo "added line" >>README.md
  commit_tag 1.3.0
  run release_guard v1.3.0 v1.2.0
  [ "${status}" -ne 0 ]
  output_has "README.md changes more than"
}

# notes_for prints the Release notes of v$1 against the previous release $2.
notes_for() {
  bash "${root}/.github/scripts/release.sh" notes "$@"
}

# back_merge adds to main what a squash-merged Back-merge PR for v$1 adds: a commit with a subject of the owner's choosing
# that changes only the version fields.
back_merge() {
  jq --arg v "$1" '.version = $v' .claude-plugin/plugin.json >p.tmp && mv p.tmp .claude-plugin/plugin.json
  jq --arg v "$1" '.version = $v | .plugins[0].source.ref = "v\($v)"' .claude-plugin/marketplace.json >m.tmp &&
    mv m.tmp .claude-plugin/marketplace.json
  git add -A
  git commit -q -m "feat: bring release $1 back to main (#9)"
}

# notes_sandbox adds the commits of a Release range to flow_sandbox on top of $run, then cuts v1.3.0 from the last one.
notes_sandbox() {
  flow_sandbox
  git checkout -q main
  git reset -q --hard "${run}"
  commit_on_main "feat: plain feature" n1
  git commit -q --allow-empty -m "$(printf 'feat(api)!: drop the old flag\n\nBREAKING CHANGE: the old flag is gone\nand needs migration')"
  git commit -q --allow-empty -m "$(printf 'fix: tidy up\n\nBREAKING-CHANGE: hyphen footer text')"
  git commit -q --allow-empty -m "feat!: subject only"
  back_merge 1.2.1
  cut "$(git rev-parse HEAD)" 1.3.0 1
}

@test "notes open with each breaking commit's footer text, or its subject when it has no footer" {
  notes_sandbox
  run --separate-stderr notes_for v1.3.0 v1.2.0
  [ "${status}" -eq 0 ]
  expected="$(printf '%s\n' \
    '### Breaking changes' \
    '' \
    '- the old flag is gone' \
    'and needs migration' \
    '- hyphen footer text' \
    '- feat!: subject only')"
  [ "$(printf '%s\n' "${output}" | head -n 6)" = "${expected}" ]
}

@test "notes cover only the Release range and leave out Bump commits" {
  notes_sandbox
  run --separate-stderr notes_for v1.3.0 v1.2.0
  [ "${status}" -eq 0 ]
  output_has "Plain feature"
  output_has "First run"
  output_lacks "Before the previous release"
  output_lacks "After the run"
  output_lacks "Bring release 1.2.1 back to main"
}
