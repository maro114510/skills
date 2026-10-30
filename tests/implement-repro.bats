#!/usr/bin/env bats
# Tests for the implement reproduction repository under tests/implement-repro: its shell template and the seeded
# defects, each shown by running the template's own runner.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  repro="${BATS_TEST_DIRNAME}/implement-repro"
  repo="${BATS_TEST_TMPDIR}/repo"
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

@test "a regression test that omits the cache precondition passes on the code without the fix" {
  build rates-naive-test
  run bash tests/run.sh --only test_convert_uses_the_rate_set_by_rates_set tests/test_rate_updates.sh
  [ "${status}" -eq 0 ]
}

@test "a regression test that fills the cache first fails at its assertion without the fix and passes with it" {
  build rates-regression-test
  run bash tests/run.sh --only test_convert_uses_a_rate_set_after_the_first_conversion tests/test_rate_updates.sh
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL: test_convert_uses_a_rate_set_after_the_first_conversion"* ]]
  [[ "${output}" != *"ERROR:"* ]]
  tar -C "${repro}/seeds/rates-cache-fix" --exclude=./message -cf - . | tar -xf -
  run bash tests/run.sh --only test_convert_uses_a_rate_set_after_the_first_conversion tests/test_rate_updates.sh
  [ "${status}" -eq 0 ]
}

@test "a test on the shared cart passes in default order but fails when run alone" {
  build cart-remove-stub cart-remove-tests-shared cart-remove
  run bash tests/run.sh tests/test_cart_remove.sh
  [ "${status}" -eq 0 ]
  run bash tests/run.sh --only test_remove_2_removing_the_last_pen_empties_the_pen_line tests/test_cart_remove.sh
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL: test_remove_2_removing_the_last_pen_empties_the_pen_line"* ]]
}

@test "tests that build their own cart pass alone and in the whole suite in default and shuffled order" {
  build cart-remove-stub cart-remove-tests cart-remove
  local name
  for name in test_remove_without_a_quantity_drops_the_whole_line \
    test_remove_with_a_quantity_drops_only_those_units \
    test_removing_more_than_the_cart_holds_fails_with_3_and_keeps_the_line \
    test_removing_an_unknown_sku_fails_with_2; do
    run bash tests/run.sh --only "${name}" tests/test_cart_remove.sh
    [ "${status}" -eq 0 ]
  done
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
  # The order a seed gives depends on the awk in use, so many seeds keep a lucky run of orders from passing this.
  for seed in $(seq 1 20); do
    bash tests/run.sh --seed "${seed}" >/dev/null 2>&1 || broken=$((broken + 1))
  done
  [ "${broken}" -ge 1 ]
}
