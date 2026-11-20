#!/usr/bin/env bats
# Tests for the oe dispatcher.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  cd "${BATS_TEST_TMPDIR}" || return 1
}

@test "each dropped subcommand is unknown: it exits 2 with the dispatcher's usage" {
  for sub in lock attempt records rereview update status board continue claim; do
    run --separate-stderr bash "${oe}" "${sub}"

    [ "${status}" -eq 2 ]
    [ "${stderr_lines[0]}" = "Usage: oe ready <owner/repo> <epic-number> [--running <issue-number>]..." ]
  done
}
