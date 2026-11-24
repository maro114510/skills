#!/usr/bin/env bats
# Tests for tests/run-bats.sh: the command that runs every bats suite, one bats process per file.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.
# So each mid-test `[[ ]]` ends in `|| false`, which fails it on every bash.

setup() {
  # A checkout holding only the runner, so each test chooses the suites it discovers.
  repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}/tests" "${repo}/skills/a/scripts" "${repo}/skills/b/scripts"
  cp "${BATS_TEST_DIRNAME}/run-bats.sh" "${repo}/tests/run-bats.sh"
  runner="${repo}/tests/run-bats.sh"
  # A parallel that records its use, so a run that reaches for GNU parallel is seen.
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\necho used >"%s/parallel-used"\nexit 127\n' "${BATS_TEST_TMPDIR}" >"${BATS_TEST_TMPDIR}/bin/parallel"
  chmod +x "${BATS_TEST_TMPDIR}/bin/parallel"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

# suite <path> <test body>: writes a one-test bats file at <path> under the fixture checkout.
suite() {
  printf '#!/usr/bin/env bats\n@test "t" {\n  %s\n}\n' "$2" >"${repo}/$1"
}

@test "run-bats exits 0 and names every suite under skills and tests when all pass" {
  suite skills/a/scripts/test-a.bats true
  suite tests/top.bats true
  run bash "${runner}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ok skills/a/scripts/test-a.bats"* ]] || false
  [[ "${output}" == *"ok tests/top.bats"* ]] || false
}

@test "run-bats exits non-zero and names the failing file when one suite fails" {
  suite skills/a/scripts/test-a.bats true
  suite skills/b/scripts/test-b.bats false
  run bash "${runner}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"FAIL skills/b/scripts/test-b.bats"* ]] || false
  [[ "${output}" != *"FAIL skills/a/scripts/test-a.bats"* ]] || false
}

@test "run-bats runs two files at the same time when BATS_JOBS is 2" {
  marks="${BATS_TEST_TMPDIR}/marks"
  mkdir -p "${marks}"
  # Each suite passes only if the other one starts while it waits.
  suite skills/a/scripts/test-a.bats "touch ${marks}/a; for _ in \$(seq 50); do [ -e ${marks}/b ] && return 0; sleep 0.1; done; return 1"
  suite skills/b/scripts/test-b.bats "touch ${marks}/b; for _ in \$(seq 50); do [ -e ${marks}/a ] && return 0; sleep 0.1; done; return 1"
  BATS_JOBS=2 run bash "${runner}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ok skills/a/scripts/test-a.bats"* ]] || false
  [[ "${output}" == *"ok skills/b/scripts/test-b.bats"* ]] || false
}

@test "run-bats never calls GNU parallel" {
  suite skills/a/scripts/test-a.bats true
  suite skills/b/scripts/test-b.bats true
  run bash "${runner}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ok skills/b/scripts/test-b.bats"* ]] || false
  [ ! -e "${BATS_TEST_TMPDIR}/parallel-used" ]
}
