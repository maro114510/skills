#!/usr/bin/env bats
# Tests for classify-approval.sh, against a throwaway repository.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/classify-approval.sh"
  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.name t
  git config user.email t@t
  git config core.hooksPath /dev/null
  mkdir -p src tests
  echo 'one' >src/app.sh
  echo 'old' >tests/app_test.sh
  commit "chore: init"
  base="$(git rev-parse HEAD)"
}

commit() {
  git add -A
  git commit -q -m "$1"
}

# Writes .agents/skills.toml from stdin.
config() {
  mkdir -p .agents
  cat >.agents/skills.toml
}

staged() {
  git add -A
  run bash "${target}" --staged "$@"
}

# Succeeds when the output holds line $1 exactly.
has_line() {
  printf '%s\n' "${output}" | grep -qxF -- "$1"
}

# Succeeds when some output line matches the extended regex $1.
has_match() {
  printf '%s\n' "${output}" | grep -qE -- "$1"
}

required() {
  [ "${status}" -eq 10 ]
  has_line "approval: required"
}

not_required() {
  [ "${status}" -eq 0 ]
  has_line "approval: not-required"
}

@test "a small diff touching no condition does not need approval" {
  echo 'two' >>src/app.sh
  staged
  not_required
}

@test "an empty staged diff does not need approval" {
  staged
  not_required
}

@test "a workflow file needs approval without any config" {
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  staged
  required
  has_line "reason: release or CI config: .github/workflows/ci.yml"
}

@test "a workflow file needs approval even when the config lists other paths" {
  config <<'EOF'
[commit.approval]
paths = ["src/billing/**"]
EOF
  commit "chore: config"
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  staged
  required
  has_line "reason: release or CI config: .github/workflows/ci.yml"
}

@test "release config and version manifests need approval at any depth" {
  local f
  for f in Makefile cliff.toml .claude-plugin/plugin.json .claude-plugin/marketplace.json \
    web/package.json Cargo.toml py/pyproject.toml; do
    git reset -q --hard "${base}"
    git clean -qfd
    mkdir -p "$(dirname "${f}")"
    echo x >"${f}"
    staged
    required
    has_line "reason: release or CI config: ${f}"
  done
}

@test "a diff touching a configured path needs approval" {
  config <<'EOF'
[commit.approval]
paths = ["src/billing/**", "db/*.sql"]
EOF
  commit "chore: config"
  mkdir -p src/billing/core
  echo 'x' >src/billing/core/charge.sh
  staged
  required
  has_line "reason: configured path: src/billing/core/charge.sh"
}

@test "a configured path given as a string needs approval" {
  config <<'EOF'
[commit.approval]
paths = "db/*.sql"
EOF
  commit "chore: config"
  mkdir -p db
  echo 'x' >db/001.sql
  staged
  required
  has_line "reason: configured path: db/001.sql"
}

@test "a small diff touching no configured path does not need approval" {
  config <<'EOF'
[commit.approval]
paths = ["src/billing/**"]
EOF
  commit "chore: config"
  echo 'two' >>src/app.sh
  staged
  not_required
}

@test "a config that tries to remove a built-in condition does not remove it" {
  config <<'EOF'
[commit.approval]
builtin = false
exclude = [".github/workflows/**"]
max_files = 1000
paths = []
EOF
  commit "chore: config"
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  staged
  required
  has_line "reason: release or CI config: .github/workflows/ci.yml"
  has_match '^classify-approval: warning: \[commit\.approval\] builtin is ignored'
  has_match '^classify-approval: warning: \[commit\.approval\] exclude is ignored'
  has_match '^classify-approval: warning: \[commit\.approval\] max_files is ignored'
}

@test "a config cannot raise the size limits" {
  config <<'EOF'
[commit.approval]
max_files = 1000
max_lines = 100000
EOF
  commit "chore: config"
  local i
  for i in $(seq 1 21); do echo x >"src/f${i}.sh"; done
  staged
  required
  has_line "reason: large diff: 21 files, 21 changed lines (limit 20 files, 1000 lines)"
}

@test "a critical decision requires approval even for a small diff" {
  echo 'two' >>src/app.sh
  staged --require "critical decision: tokens are now stored unhashed"
  required
  has_line "reason: critical decision: tokens are now stored unhashed"
}

@test "every --require reason is reported" {
  echo 'two' >>src/app.sh
  staged --require "mixed concerns" --require "unclear type"
  required
  has_line "reason: mixed concerns"
  has_line "reason: unclear type"
}

@test "more than 20 files need approval and 20 do not" {
  local i
  for i in $(seq 1 20); do echo x >"src/f${i}.sh"; done
  staged
  not_required
  echo x >src/f21.sh
  staged
  required
  has_line "reason: large diff: 21 files, 21 changed lines (limit 20 files, 1000 lines)"
}

@test "more than 1000 changed lines need approval and 1000 do not" {
  seq 1 999 >>src/app.sh
  staged
  not_required
  seq 1 2 >>src/app.sh
  staged
  required
  has_line "reason: large diff: 1 files, 1001 changed lines (limit 20 files, 1000 lines)"
}

@test "a deleted file needs approval" {
  git rm -q src/app.sh
  staged
  required
  has_line "reason: deleted file: src/app.sh"
}

@test "a renamed file is not a deletion" {
  git mv src/app.sh src/main.sh
  staged
  not_required
}

@test "a deleted test file covered by a Removed-Test trailer does not need approval" {
  config <<'EOF'
[paths]
tests = "tests/**/*_test.sh"
EOF
  commit "chore: config"
  git rm -q tests/app_test.sh
  staged --removed-test
  not_required
}

@test "a Removed-Test trailer does not cover a deleted file outside the test paths" {
  config <<'EOF'
[paths]
tests = "tests/**/*_test.sh"
EOF
  commit "chore: config"
  git rm -q src/app.sh
  staged --removed-test
  required
  has_line "reason: deleted file: src/app.sh"
}

@test "without test paths a Removed-Test trailer covers no deletion" {
  git rm -q tests/app_test.sh
  staged --removed-test
  required
  has_line "reason: deleted file: tests/app_test.sh"
}

@test "the staged mode ignores unstaged changes" {
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  echo 'two' >>src/app.sh
  git add src/app.sh
  run bash "${target}" --staged
  not_required
}

@test "the range mode classifies every commit in base..HEAD" {
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  commit "ci: add workflow"
  git rm -q .github/workflows/ci.yml
  commit "ci: drop workflow"
  echo 'two' >>src/app.sh
  commit "feat: grow"
  run bash "${target}" "${base}"
  required
  has_line "reason: release or CI config: .github/workflows/ci.yml"
}

@test "the range mode ignores uncommitted changes" {
  echo 'two' >>src/app.sh
  commit "feat: grow"
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  git add -A
  run bash "${target}" "${base}"
  not_required
}

@test "the range mode accepts a Removed-Test trailer from a commit in the range" {
  config <<'EOF'
[paths]
tests = "tests/**/*_test.sh"
EOF
  commit "chore: config"
  local start
  start="$(git rev-parse HEAD)"
  git rm -q tests/app_test.sh
  git commit -q -m "test: drop app test" -m "Removed-Test: test_app -- superseded"
  run bash "${target}" "${start}"
  not_required
}

@test "the range mode starts at the merge base with the base" {
  git switch -q -c topic
  echo 'two' >>src/app.sh
  commit "feat: grow"
  git switch -q main
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  commit "ci: on main"
  git switch -q topic
  run bash "${target}" main
  not_required
}

@test "editing the config needs approval, so dropping a configured path cannot hide its change" {
  config <<'EOF'
[commit.approval]
paths = ["src/**"]
EOF
  commit "chore: config"
  config <<'EOF'
[commit.approval]
paths = []
EOF
  echo 'two' >>src/app.sh
  staged
  required
  has_line "reason: release or CI config: .agents/skills.toml"
}

@test "the staged mode reads the config from the index, not the working tree" {
  config <<'EOF'
[commit.approval]
paths = ["src/**"]
EOF
  commit "chore: config"
  echo 'two' >>src/app.sh
  git add src/app.sh
  config <<'EOF'
[commit.approval]
paths = []
EOF
  run bash "${target}" --staged
  required
  has_line "reason: configured path: src/app.sh"
}

@test "the range mode reads the config from HEAD, not the working tree" {
  config <<'EOF'
[commit.approval]
paths = ["src/**"]
EOF
  commit "chore: config"
  local start
  start="$(git rev-parse HEAD)"
  echo 'two' >>src/app.sh
  commit "feat: grow"
  config <<'EOF'
[commit.approval]
paths = []
EOF
  run bash "${target}" "${start}"
  required
  has_line "reason: configured path: src/app.sh"
}

@test "a configured path git rejects is an error, not a silent pass" {
  config <<'EOF'
[commit.approval]
paths = ["../outside/**"]
EOF
  commit "chore: config"
  echo 'two' >>src/app.sh
  staged
  [ "${status}" -eq 2 ]
}

@test "a malformed config is an error" {
  config <<'EOF'
[commit.approval]
paths = 3
EOF
  commit "chore: config"
  staged
  [ "${status}" -eq 2 ]
  has_match '^classify-approval: commit\.approval\.paths must be'
}

@test "an unknown base is an error" {
  run bash "${target}" no-such-ref
  [ "${status}" -eq 2 ]
  has_match '^classify-approval: Unknown base: no-such-ref'
}

@test "--staged and a base together are an error" {
  run bash "${target}" --staged main
  [ "${status}" -eq 2 ]
}

@test "--require without a reason is an error" {
  run bash "${target}" --staged --require
  [ "${status}" -eq 2 ]
}

@test "--removed-test is an unknown option, so a deleted test file cannot be exempted" {
  git rm -q tests/app_test.sh
  git add -A
  run bash "${target}" --staged --removed-test
  [ "${status}" -eq 2 ]
  has_match '^classify-approval: Usage: '
}
