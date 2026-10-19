#!/usr/bin/env bats
# Tests for check-rule-inventory.sh against fixtures, plus the live orchestrate-epic inventory.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/check-rule-inventory.sh"
  fx="${BATS_TEST_DIRNAME}/fixtures/rule-inventory"
  live="${BATS_TEST_DIRNAME}/../docs/design/orchestrate-epic-v2/rule-inventory.tsv"
}

@test "an incomplete inventory may leave owners empty" {
  run bash "${target}" "${fx}/valid-incomplete.tsv"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK 3 rows (incomplete)"* ]]
}

@test "a complete inventory with every disposition and owner passes" {
  run bash "${target}" "${fx}/valid-complete.tsv"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK 3 rows (complete)"* ]]
}

@test "a duplicate ID fails and names the row" {
  run bash "${target}" "${fx}/duplicate-id.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"GL-01"*"duplicate id"* ]]
}

@test "a quote missing from its source fails as a dangling anchor and names the row" {
  run bash "${target}" "${fx}/dangling-quote.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"MQ-01"*"dangling source anchor"* ]]
}

@test "a missing source file fails as a dangling anchor and names the row" {
  run bash "${target}" "${fx}/dangling-source.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"MQ-01"*"dangling source anchor"* ]]
}

@test "an owner naming an absent test fails as a dangling anchor, even when incomplete" {
  run bash "${target}" "${fx}/dangling-owner.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"GL-01"*"dangling owner anchor"* ]]
}

@test "an owner with an empty quote or test name fails instead of matching every file" {
  for owner in "prose:tests/fixtures/rule-inventory/source.md#" "test:tests/fixtures/rule-inventory/source.md::"; do
    awk -F'\t' -v OFS='\t' -v o="${owner}" '$1 == "MQ-01" { $7 = o } 1' "${fx}/valid-incomplete.tsv" >"${BATS_TEST_TMPDIR}/inv.tsv"
    run bash "${target}" "${BATS_TEST_TMPDIR}/inv.tsv"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"MQ-01"*"dangling owner anchor"* ]]
  done
}

@test "complete mode rejects a row whose disposition was deleted and names it" {
  run bash "${target}" "${fx}/complete-missing-disposition.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"MQ-01"*"missing disposition"* ]]
}

@test "complete mode rejects a row without an owner and names it" {
  run bash "${target}" "${fx}/complete-missing-owner.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"GL-01"*"missing owner"* ]]
}

@test "the same rows without disposition or owner pass while incomplete" {
  sed 's/^#status: complete$/#status: incomplete/' "${fx}/complete-missing-disposition.tsv" >"${BATS_TEST_TMPDIR}/inv.tsv"
  run bash "${target}" "${BATS_TEST_TMPDIR}/inv.tsv"
  [ "${status}" -eq 0 ]
}

@test "a retired row without a reason fails" {
  run bash "${target}" "${fx}/retired-without-reason.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"EV-06"*"needs a reason"* ]]
}

@test "a row with the wrong column count fails and names its line" {
  run bash "${target}" "${fx}/malformed-row.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"line 4"*"8 columns"* ]]
}

@test "an unknown disposition fails" {
  run bash "${target}" "${fx}/bad-disposition.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"MQ-01"*"disposition"* ]]
}

@test "a missing status line fails" {
  run bash "${target}" "${fx}/missing-status.tsv"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"#status:"* ]]
}

@test "a missing inventory file is a usage error" {
  run bash "${target}" "${fx}/no-such-file.tsv"
  [ "${status}" -eq 2 ]
}

@test "the live orchestrate-epic inventory passes" {
  run bash "${target}" "${live}"
  [ "${status}" -eq 0 ]
}

@test "the live inventory carries the ten critical rules" {
  for id in GL-03 MQ-01 GL-14 RV-09 FZ-01 GL-21 GL-17 LO-02 PH-05 GL-01; do
    awk -F'\t' -v id="${id}" '$1 == id && $5 == "kept" { found = 1 } END { exit !found }' "${live}" ||
      {
        echo "critical rule ${id} missing or not kept"
        return 1
      }
  done
}

@test "every YAGNI cut of Epic #277 is recorded as retired with a reason" {
  for id in BD-06 CMD-08 SN-10 ST-08 SN-09 RD-09 IN-06 EC-01 EC-12 TP-15 TP-16 TP-17 CM-04; do
    awk -F'\t' -v id="${id}" '$1 == id && $5 == "retired" && $8 != "-" { found = 1 } END { exit !found }' "${live}" ||
      {
        echo "YAGNI cut ${id} missing or not retired with a reason"
        return 1
      }
  done
}
