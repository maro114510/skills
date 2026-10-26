#!/usr/bin/env bats
# Tests for the implement reproduction repository under tests/implement-repro: its shell template and the seeded
# defects that skills/implement/scripts/gate-tests.sh must flag.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  repro="${BATS_TEST_DIRNAME}/implement-repro"
  repo="${BATS_TEST_TMPDIR}/repo"
  gate="${BATS_TEST_DIRNAME}/../skills/implement/scripts/gate-tests.sh"
  unset GATE_TESTS_SEED
}

# build <seed>... makes $repo from template/, with a bare origin whose main is its first commit, then commits each
# seed on top: the files under seeds/<seed>/ and its message file as the commit subject.
build() {
  local origin="${BATS_TEST_TMPDIR}/origin.git" seed
  git init -q --bare -b main "${origin}"
  git init -q -b main "${repo}"
  cp -R "${repro}/template/." "${repo}/"
  cd "${repo}" || return 1
  git config user.name repro
  git config user.email repro@example.invalid
  git add -A
  git commit -q -m "chore: init"
  git remote add origin "${origin}"
  git push -q -u origin main
  git remote set-head origin main
  for seed in "$@"; do
    tar -C "${repro}/seeds/${seed}" --exclude=./message -cf - . | tar -xf -
    git add -A
    git commit -q -F "${repro}/seeds/${seed}/message"
  done
}

@test "the template's suite passes in its default order" {
  build
  run bash tests/run.sh
  [ "${status}" -eq 0 ]
}

@test "the template's suite passes in shuffled order for seeds 1 to 5" {
  build
  for seed in 1 2 3 4 5; do
    run bash tests/run.sh --seed "${seed}"
    [ "${status}" -eq 0 ]
  done
}

@test "the runner exits 2 and prints an ERROR line when --only names no test" {
  build
  run bash tests/run.sh --only test_no_such_thing tests/test_cart.sh
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"ERROR: no test named test_no_such_thing"* ]]
}

@test "the runner reports a failed assertion as FAIL and any other failure as ERROR" {
  build
  cat >tests/test_probe.sh <<'EOF'
test_fails_an_assertion() { assert_eq 1 2; }
test_calls_a_missing_command() { no_such_command_anywhere; }
EOF
  run bash tests/run.sh tests/test_probe.sh
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL: test_fails_an_assertion"* ]]
  [[ "${output}" == *"ERROR: test_calls_a_missing_command"* ]]
}

@test "the template, the seeds, and the cases name no project and hold no URL, e-mail address, or licence text" {
  [ -d "${repro}/cases" ]
  run grep -rniE 'https?://|www\.|[a-z0-9_.]+@[a-z0-9-]+\.|github|gitlab|copyright|licen[sc]e' "${repro}/template" "${repro}/seeds" "${repro}/cases"
  [ "${status}" -eq 1 ]
}

@test "gate-tests flags a regression test that passes on the code without the fix" {
  build rates-naive-test rates-cache-fix
  run bash "${gate}" origin/main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"test_convert_uses_the_rate_set_by_rates_set: passed on the parent"* ]]
  [[ "${output}" == *"before-change: fail"* ]]
}

@test "a regression test that fills the cache first passes gate-tests" {
  build rates-regression-test rates-cache-fix
  run bash "${gate}" origin/main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed on the parent"* ]]
  [[ "${output}" == *"before-change: pass"* ]]
}

@test "gate-tests flags a test that passes in default order but fails when run alone" {
  build cart-remove-stub cart-remove-tests-shared cart-remove
  run bash "${gate}" origin/main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"test_remove_2_removing_the_last_pen_empties_the_pen_line: failed when run alone"* ]]
  [[ "${output}" == *"isolation: fail"* ]]
}

@test "tests that build their own cart pass gate-tests and the whole suite in default and shuffled order" {
  build cart-remove-stub cart-remove-tests cart-remove
  run bash "${gate}" origin/main
  [ "${status}" -eq 0 ]
  for seed in "" 1 2 3 4 5; do
    run bash tests/run.sh ${seed:+--seed "${seed}"}
    [ "${status}" -eq 0 ]
  done
}

@test "tests that share a cart fixture break the whole suite in a shuffled order" {
  build cart-remove-stub cart-remove-tests-shared cart-remove
  run bash tests/run.sh
  [ "${status}" -eq 0 ]
  broken=0
  for seed in 1 2 3 4 5; do
    bash tests/run.sh --seed "${seed}" >/dev/null 2>&1 || broken=$((broken + 1))
  done
  [ "${broken}" -ge 1 ]
}
