#!/usr/bin/env bats
# Tests for gate-tests.sh, against a throwaway repo whose tests are shell functions run by a fake runner.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.
# shellcheck disable=SC2016 # config values and fixture code are expanded by the fixture, not here

setup() {
  target="${BATS_TEST_DIRNAME}/gate-tests.sh"
  repo="${BATS_TEST_TMPDIR}/repo"
  log="${BATS_TEST_TMPDIR}/order.log"
  export TG_LOG="${log}"
  unset GATE_TESTS_SEED
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.name t
  git config user.email t@t
  git config core.hooksPath /dev/null
  mkdir -p src tests
  # The runner sources the library and the test files into one shell, so a global set by one test is seen by the
  # next one, the way shared fixtures leak between tests. A file that cannot be sourced is a build error.
  # shuffled runs the tests in declared order for an even seed and in reverse order for an odd one.
  cat >runner.sh <<'EOF'
build() { echo "BUILD ERROR: $1"; exit 2; }
. src/lib.sh || build src/lib.sh
mode="$1"
shift
if [ "${mode}" = one ]; then
  . "$1" || build "$1"
  if "$2"; then echo "PASS $2"; exit 0; fi
  echo "FAIL $2"
  exit 1
fi
seed="$1"
shift
names=""
for f in "$@"; do
  . "${f}" || build "${f}"
  names="${names} $(sed -nE 's/^(test_[a-z0-9_]+)\(\).*/\1/p' "${f}" | tr '\n' ' ')"
done
if [ $((seed % 2)) -eq 1 ]; then
  rev=""
  for n in ${names}; do rev="${n} ${rev}"; done
  names="${rev}"
fi
rc=0
for n in ${names}; do
  if "${n}"; then echo "PASS ${n}"; else echo "FAIL ${n}"; rc=1; fi
done
exit "${rc}"
EOF
  echo 'add() { echo $(($1 + $2)); }' >src/lib.sh
  full_config
  commit "chore: init"
  base="$(git rev-parse HEAD)"
}

# Writes .agents/skills.toml with every key set; extra lines in $1 are appended to [implement.testing], and
# run_one is $run_one when set.
full_config() {
  local one="${run_one:-bash runner.sh one \"\$TEST_FILE\" \"\$TEST_NAME\"}"
  mkdir -p .agents
  cat >.agents/skills.toml <<EOF
[paths]
tests = ["tests/**/*_test.sh"]

[implement.testing]
test_case = '^(test_\\w+)\\(\\)'
run_one = '${one}'
run_shuffled = 'bash runner.sh shuffled "\$TEST_SEED" "\$@"'
build_failure = '^BUILD ERROR'
${1:-}
EOF
}

commit() {
  git add -A
  git commit -q -m "$1"
}

gate() {
  run bash "${target}" "${base}"
}

# Succeeds when the output holds line $1 exactly.
has_line() {
  printf '%s\n' "${output}" | grep -qxF -- "$1"
}

# Succeeds when some output line matches the extended regex $1.
has_match() {
  printf '%s\n' "${output}" | grep -qE -- "$1"
}

# Succeeds when no output line matches the extended regex $1; a bare `! has_match` would never fail a test.
lacks_match() {
  ! has_match "$1"
}

@test "without a config file every check is reported as not run" {
  rm .agents/skills.toml
  commit "chore: drop config"
  gate
  [ "${status}" -eq 0 ]
  has_line "setup: not-run (missing implement.testing.setup)"
  has_match '^before-change: not-run \(missing paths\.tests, implement\.testing\.test_case, implement\.testing\.run_one\)$'
  has_match '^isolation: not-run \(missing '
  has_match '^shuffle: not-run \(missing paths\.tests, implement\.testing\.run_shuffled\)$'
  has_match '^removed: not-run \(missing paths\.tests, implement\.testing\.test_case\)$'
}

@test "a new test that passes on the pre-change code fails the before-change check" {
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  commit "test: pin add"
  gate
  [ "${status}" -eq 1 ]
  has_line "before-change: fail"
  has_match "^  $(git rev-parse --short HEAD) on parent $(git rev-parse --short HEAD^): tests/math_test.sh test_add: passed on the parent$"
}

@test "a failing test commit followed by its implementation passes the before-change check" {
  echo 'test_sub() { [ "$(sub 3 1)" = 2 ]; }' >tests/math_test.sh
  commit "test: pin sub"
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  has_line "before-change: pass"
  has_line "isolation: pass"
}

@test "a combined test and implementation commit is checked against its parent" {
  echo 'test_sub() { [ "$(sub 3 1)" = 2 ]; }' >tests/math_test.sh
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  has_line "  $(git rev-parse --short HEAD) on parent $(git rev-parse --short HEAD^): tests/math_test.sh test_sub: failed on the parent"
  has_line "before-change: pass"
}

@test "a combined commit whose test passes on its parent fails the before-change check" {
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 1 ]
  has_match 'tests/math_test.sh test_add: passed on the parent$'
}

@test "a test that fails on the parent only with a build error fails the before-change check" {
  echo 'mul() { echo $(($1 * $2)); }' >src/extra.sh
  printf '%s\n' '. src/extra.sh || return 1' 'test_mul() { [ "$(mul 2 3)" = 6 ]; }' >tests/mul_test.sh
  commit "feat: add mul"
  gate
  [ "${status}" -eq 1 ]
  has_match 'tests/mul_test.sh test_mul: failed with a build error on the parent$'
  has_line "before-change: fail"
}

@test "an unchanged test in a changed file is not run against the parent" {
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  echo 'test_sub() { [ "$(sub 3 1)" = 2 ]; }' >>tests/math_test.sh
  commit "test: pin sub"
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  lacks_match 'test_add'
  has_line "before-change: pass"
}

@test "a changed test body is run against the parent" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  printf '%s\n' 'test_add() {' '  [ "$(add 2 2)" = 4 ]' '}' >tests/math_test.sh
  commit "test: widen add"
  gate
  [ "${status}" -eq 1 ]
  has_match 'tests/math_test.sh test_add: passed on the parent$'
}

@test "deleting a whole test does not mark the test above it as changed" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' 'test_add_zero() {' '  [ "$(add 0 2)" = 2 ]' '}' >tests/math_test.sh
  commit "chore: add existing tests"
  base="$(git rev-parse HEAD)"
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' >tests/math_test.sh
  git add -A
  git commit -q -m "test: drop a duplicate" -m "Removed-Test: test_add_zero -- test_add covers the same path"
  gate
  [ "${status}" -eq 0 ]
  lacks_match 'test_add: passed'
  has_line "before-change: pass"
}

@test "deleting lines at the end of a test marks that test as changed" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '  [ "$(add 2 2)" = 5 ]' '}' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' >tests/math_test.sh
  commit "test: drop a wrong assertion"
  gate
  [ "${status}" -eq 1 ]
  has_match 'tests/math_test.sh test_add: (passed|failed) on the parent$'
}

@test "appending a test after a blank line does not mark the test above it as changed" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  printf '%s\n' '' 'test_sub() {' '  [ "$(sub 3 1)" = 2 ]' '}' >>tests/math_test.sh
  commit "test: pin sub"
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  lacks_match 'test_add'
  has_line "before-change: pass"
}

@test "appending a test with a comment above its declaration does not mark the test above it as changed" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  printf '%s\n' '' '# sub subtracts its second argument' 'test_sub() {' '  [ "$(sub 3 1)" = 2 ]' '}' >>tests/math_test.sh
  commit "test: pin sub"
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  lacks_match 'test_add'
  has_line "before-change: pass"
}

@test "deleting a test with a comment above its declaration does not mark the test above it as changed" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' '' '# adding zero keeps the number' 'test_add_zero() {' '  [ "$(add 0 2)" = 2 ]' '}' >tests/math_test.sh
  commit "chore: add existing tests"
  base="$(git rev-parse HEAD)"
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' >tests/math_test.sh
  git add -A
  git commit -q -m "test: drop a duplicate" -m "Removed-Test: test_add_zero -- test_add covers the same path"
  gate
  [ "${status}" -eq 0 ]
  lacks_match 'test_add: passed'
  has_line "before-change: pass"
}

@test "changing the comment above a declaration marks that test, not the test above it, as changed" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' '' '# adding zero keeps the number' 'test_add_zero() {' '  [ "$(add 0 2)" = 2 ]' '}' >tests/math_test.sh
  commit "chore: add existing tests"
  base="$(git rev-parse HEAD)"
  sed -i.bak 's/^# adding zero keeps the number$/# adding zero to a number keeps it/' tests/math_test.sh
  rm tests/math_test.sh.bak
  commit "test: reword a comment"
  gate
  [ "${status}" -eq 1 ]
  has_match 'tests/math_test.sh test_add_zero: passed on the parent$'
  lacks_match 'test_add: passed'
}

@test "deleting an assertion after a blank line inside a test marks that test as changed" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '' '  [ "$(add 2 2)" = 5 ]' '}' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '' '}' >tests/math_test.sh
  commit "test: drop a wrong assertion"
  gate
  [ "${status}" -eq 1 ]
  has_match 'tests/math_test.sh test_add: (passed|failed) on the parent$'
}

@test "a refactor commit is exempt from the before-change check" {
  printf '%s\n' 'test_add() {' '  [ "$(add 1 2)" = 3 ]' '}' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  printf '%s\n' 'test_add() {' '  sum="$(add 1 2)"' '  [ "${sum}" = 3 ]' '}' >tests/math_test.sh
  commit "refactor(tests): name the sum"
  gate
  [ "${status}" -eq 0 ]
  has_match "^  $(git rev-parse --short HEAD): skipped \(refactor commit\)$"
  has_line "before-change: pass"
  has_line "isolation: pass"
}

@test "a test that relies on state left by another test fails the isolation check" {
  printf '%s\n' 'test_open() { open_store; }' 'test_read() { [ "${STORE:-}" = open ]; }' >tests/store_test.sh
  echo 'open_store() { STORE=open; }' >>src/lib.sh
  commit "feat: add the store"
  gate
  [ "${status}" -eq 1 ]
  has_line "  tests/store_test.sh test_read: failed when run alone"
  has_line "isolation: fail"
}

@test "a test that relies on state left by another test fails the shuffle check and prints its seed" {
  printf '%s\n' 'test_open() { open_store; }' 'test_read() { [ "${STORE:-}" = open ]; }' >tests/store_test.sh
  echo 'open_store() { STORE=open; }' >>src/lib.sh
  commit "feat: add the store"
  GATE_TESTS_SEED=1 gate
  [ "${status}" -eq 1 ]
  has_line "shuffle: fail (seed=1)"
  GATE_TESTS_SEED=2 gate
  has_line "shuffle: pass (seed=2)"
}

@test "the shuffle check prints a generated seed" {
  echo 'test_sub() { [ "$(sub 3 1)" = 2 ]; }' >tests/math_test.sh
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  has_match '^shuffle: pass \(seed=[0-9]+\)$'
}

@test "the shuffle check rejects a seed that is not a number" {
  GATE_TESTS_SEED='1;x' gate
  [ "${status}" -eq 2 ]
}

@test "a deleted test without a Removed-Test trailer fails the removed check" {
  printf '%s\n' 'test_add() { [ "$(add 1 2)" = 3 ]; }' 'test_add_zero() { [ "$(add 0 2)" = 2 ]; }' >tests/math_test.sh
  commit "chore: add existing tests"
  base="$(git rev-parse HEAD)"
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  commit "refactor(tests): drop a duplicate"
  gate
  [ "${status}" -eq 1 ]
  has_line "  test_add_zero: deleted without a Removed-Test trailer"
  has_line "removed: fail"
}

@test "a deleted test with a Removed-Test trailer and a reason passes the removed check" {
  printf '%s\n' 'test_add() { [ "$(add 1 2)" = 3 ]; }' 'test_add_zero() { [ "$(add 0 2)" = 2 ]; }' >tests/math_test.sh
  commit "chore: add existing tests"
  base="$(git rev-parse HEAD)"
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  git add -A
  git commit -q -m "refactor(tests): drop a duplicate" -m "Removed-Test: test_add_zero -- test_add covers the same path"
  gate
  [ "${status}" -eq 0 ]
  has_line "removed: pass"
}

@test "a Removed-Test trailer without a reason does not cover a deleted test" {
  printf '%s\n' 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  git rm -q tests/math_test.sh
  git commit -q -m "refactor(tests): drop the add test" -m "Removed-Test: test_add"
  gate
  [ "${status}" -eq 1 ]
  has_line "  test_add: deleted without a Removed-Test trailer"
}

@test "a deleted test is reported even when another changed file keeps a test of the same name" {
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/a_test.sh
  echo 'test_add() { [ "$(add 2 2)" = 4 ]; }' >tests/b_test.sh
  commit "chore: add existing tests"
  base="$(git rev-parse HEAD)"
  git rm -q tests/a_test.sh
  echo 'test_add() { [ "$(add 2 3)" = 5 ]; }' >tests/b_test.sh
  commit "refactor(tests): keep one add test"
  gate
  [ "${status}" -eq 1 ]
  has_line "  test_add: deleted without a Removed-Test trailer"
}

@test "a color setting does not hide changed tests" {
  git config color.diff always
  git config color.ui always
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  commit "test: pin add"
  gate
  [ "${status}" -eq 1 ]
  has_match 'tests/math_test.sh test_add: passed on the parent$'
}

@test "a post-checkout hook does not run in the parent worktree" {
  mkdir -p "${BATS_TEST_TMPDIR}/hooks"
  printf '%s\n' '#!/bin/sh' 'exit 1' >"${BATS_TEST_TMPDIR}/hooks/post-checkout"
  chmod +x "${BATS_TEST_TMPDIR}/hooks/post-checkout"
  git config core.hooksPath "${BATS_TEST_TMPDIR}/hooks"
  echo 'test_sub() { [ "$(sub 3 1)" = 2 ]; }' >tests/math_test.sh
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  has_line "before-change: pass"
}

@test "an empty list of test paths is an error" {
  printf '%s\n' '[paths]' 'tests = []' >.agents/skills.toml
  commit "chore: break config"
  gate
  [ "${status}" -eq 2 ]
}

@test "a test moved to another file is not reported as deleted" {
  printf '%s\n' 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  commit "chore: add an existing test"
  base="$(git rev-parse HEAD)"
  git mv tests/math_test.sh tests/add_test.sh
  commit "refactor(tests): rename the file"
  gate
  [ "${status}" -eq 0 ]
  has_line "removed: pass"
}

@test "only the configured checks run, and the rest are reported as not run" {
  cat >.agents/skills.toml <<'EOF'
[paths]
tests = "tests/**/*_test.sh"

[implement.testing]
test_case = '^(test_\w+)\(\)'
EOF
  commit "chore: config"
  base="$(git rev-parse HEAD)"
  echo 'test_add() { [ "$(add 1 2)" = 3 ]; }' >tests/math_test.sh
  commit "test: pin add"
  gate
  [ "${status}" -eq 0 ]
  has_line "before-change: not-run (missing implement.testing.run_one)"
  has_line "isolation: not-run (missing implement.testing.run_one)"
  has_line "shuffle: not-run (missing implement.testing.run_shuffled)"
  has_line "removed: pass"
}

@test "setup runs before the checks" {
  run_one='echo run >>"$TG_LOG"; bash runner.sh one "$TEST_FILE" "$TEST_NAME"' \
    full_config "setup = 'echo setup >>\"\$TG_LOG\"'"
  commit "chore: config"
  base="$(git rev-parse HEAD)"
  echo 'test_sub() { [ "$(sub 3 1)" = 2 ]; }' >tests/math_test.sh
  echo 'sub() { echo $(($1 - $2)); }' >>src/lib.sh
  commit "feat: add sub"
  gate
  [ "${status}" -eq 0 ]
  has_line "setup: ran"
  [ "$(head -n1 "${log}")" = setup ]
  [ "$(grep -c '^setup$' "${log}")" -eq 1 ]
  grep -qx run "${log}"
}

@test "a failing setup stops before any check runs" {
  full_config "setup = 'echo broken; exit 4'"
  commit "chore: config"
  base="$(git rev-parse HEAD)"
  gate
  [ "${status}" -eq 3 ]
  has_line "setup: fail"
  lacks_match '^(before-change|isolation|shuffle|removed): '
}

@test "an unreadable config is an error" {
  echo '[paths' >.agents/skills.toml
  commit "chore: break config"
  gate
  [ "${status}" -eq 2 ]
}

@test "a config value of the wrong type is an error" {
  printf '%s\n' '[paths]' 'tests = 3' >.agents/skills.toml
  commit "chore: break config"
  gate
  [ "${status}" -eq 2 ]
}

@test "an unknown base is an error" {
  run bash "${target}" no-such-ref
  [ "${status}" -eq 2 ]
}

@test "a test name is passed as data, never as shell code" {
  cat >.agents/skills.toml <<'EOF'
[paths]
tests = "tests/*.txt"

[implement.testing]
test_case = '^case (.+)$'
run_one = 'printf "%s\n" "$TEST_NAME" >>"$TG_LOG"'
EOF
  commit "chore: config"
  base="$(git rev-parse HEAD)"
  echo 'case $(touch pwned)' >tests/a.txt
  commit "test: odd name"
  gate
  [ ! -e pwned ]
  grep -qxF '$(touch pwned)' "${log}"
}
