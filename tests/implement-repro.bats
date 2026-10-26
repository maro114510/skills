#!/usr/bin/env bats
# Tests for the implement reproduction repository under tests/implement-repro: its shell template and the seeded
# defects that skills/implement/scripts/gate-tests.sh must flag.
# shellcheck disable=SC2119,SC2120 # build takes seeds, and some tests build none
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  repro="${BATS_TEST_DIRNAME}/implement-repro"
  repo="${BATS_TEST_TMPDIR}/repo"
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

@test "the template names no project and holds no URL, e-mail address, or licence text" {
  [ -d "${repro}/template" ]
  run grep -rniE 'https?://|www\.|[a-z0-9_.]+@[a-z0-9-]+\.|github|gitlab|copyright|licen[sc]e' "${repro}/template"
  [ "${status}" -eq 1 ]
}
