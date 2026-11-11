#!/usr/bin/env bats
# Tests for check-range.sh, in a throwaway skills root whose classifier and difit review are stubs.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  root="${BATS_TEST_TMPDIR}/skills"
  mkdir -p "${root}/create-pr/scripts" "${root}/commit/scripts" "${root}/implement/scripts"
  cp "${BATS_TEST_DIRNAME}/check-range.sh" "${root}/create-pr/scripts/"
  review_args="${BATS_TEST_TMPDIR}/review-args"

  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  commit init
  git -C "${repo}" branch base
  base_sha="$(git -C "${repo}" rev-parse base)"
  commit change
}

commit() {
  git -C "${repo}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"
}

# A classifier that prints $2 and exits $1.
classifier() {
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$2" "$1" >"${root}/commit/scripts/classify-approval.sh"
}

# A difit review that records its arguments, prints $2, and exits $1.
review() {
  printf '#!/bin/sh\necho "$@" >"%s"\nprintf "%%s\\n" "%s"\nexit %s\n' "${review_args}" "$2" "$1" \
    >"${root}/implement/scripts/review-range.sh"
}

check() {
  cd "${repo}" || return 1
  run bash "${root}/create-pr/scripts/check-range.sh" "$@"
}

@test "a range the classifier does not flag is approved without opening difit" {
  classifier 0 "approval: not-required"
  review 0 "DIFIT_RESULT status=closed comments=none"
  check base
  [ "${status}" -eq 0 ]
  [ "${output}" = "approval: not-required" ]
  [ ! -e "${review_args}" ]
}

@test "a flagged range opens difit from the merge base to HEAD and is approved when it closes without comments" {
  classifier 10 "reason: deleted file: a"
  review 0 "DIFIT_RESULT status=closed comments=none"
  check base
  [ "${status}" -eq 0 ]
  [ "$(cat "${review_args}")" = "HEAD ${base_sha}" ]
  [ "${lines[0]}" = "reason: deleted file: a" ]
  [ "${lines[1]}" = "DIFIT_RESULT status=closed comments=none" ]
}

@test "a flagged range is not approved when difit closes with comments" {
  classifier 10 "reason: deleted file: a"
  review 10 "DIFIT_RESULT status=closed comments=present"
  check base
  [ "${status}" -eq 10 ]
  [ "${lines[1]}" = "DIFIT_RESULT status=closed comments=present" ]
}

@test "a classifier error opens difit as a flagged range does" {
  classifier 2 "classify-approval: Unknown base: base"
  review 0 "DIFIT_RESULT status=closed comments=none"
  check base
  [ "${status}" -eq 0 ]
  [ "$(cat "${review_args}")" = "HEAD ${base_sha}" ]
}

@test "a call without a base ref exits 2 and opens no difit" {
  classifier 10 "reason: deleted file: a"
  review 0 "DIFIT_RESULT status=closed comments=none"
  check
  [ "${status}" -eq 2 ]
  [ ! -e "${review_args}" ]
}
