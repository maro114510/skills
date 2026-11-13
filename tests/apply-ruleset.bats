#!/usr/bin/env bats
# Tests for .github/rulesets: the main-branch ruleset file and the script that applies it.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  apply="${root}/.github/rulesets/apply.sh"
  ruleset="${root}/.github/rulesets/main.json"
  calls="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  # A gh that logs each call and answers the list request with $STUB_LIST; a call whose arguments contain $STUB_FAIL exits 1.
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${CALLS}"
if [[ -n "${STUB_FAIL:-}" && "$*" == *"${STUB_FAIL}"* ]]; then echo "gh: boom" >&2; exit 1; fi
if [[ "$*" == *"--method"* ]]; then echo '{"id": 1}'; else echo "${STUB_LIST:-[]}"; fi
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export CALLS="${calls}" PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

@test "apply creates the ruleset with the file when none carries its name" {
  STUB_LIST='[{"id": 7, "name": "other"}]' run bash "${apply}" owner/repo
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"created"* ]]
  grep -q -- "--method POST repos/owner/repo/rulesets" "${calls}"
  grep -q -- "--input ${ruleset}" "${calls}"
}

@test "apply updates the ruleset by id when one carries its name" {
  STUB_LIST='[{"id": 7, "name": "other"}, {"id": 42, "name": "Protect main"}]' run bash "${apply}" owner/repo
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"updated 42"* ]]
  grep -q -- "--method PUT repos/owner/repo/rulesets/42" "${calls}"
  ! grep -q -- "--method POST" "${calls}"
}

@test "apply exits 2 without a repository" {
  run bash "${apply}"
  [ "${status}" -eq 2 ]
  [ ! -e "${calls}" ]
}

@test "apply exits 1 and reports the error when the write fails" {
  STUB_FAIL="--method POST" run bash "${apply}" owner/repo
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"boom"* ]]
}

@test "the ruleset targets main only and lets repository admins bypass it" {
  run jq -e '.target == "branch" and .enforcement == "active"
    and .conditions.ref_name.include == ["refs/heads/main"]
    and any(.bypass_actors[]; .actor_type == "RepositoryRole" and .actor_id == 5 and .bypass_mode == "always")' "${ruleset}"
  [ "${status}" -eq 0 ]
}

@test "the ruleset requires a pull request with a code owner's review" {
  run jq -e 'any(.rules[]; .type == "pull_request" and .parameters.required_approving_review_count >= 1
    and .parameters.require_code_owner_review == true)' "${ruleset}"
  [ "${status}" -eq 0 ]
}

@test "every required check is a job of a workflow that runs on every pull request" {
  run jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "${ruleset}"
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
  while IFS= read -r context; do
    # A job name with a matrix, as `APM install (${{ matrix.target }})`, matches by the part before the expression.
    prefix="${context%% (*}"
    file="$(grep -lF "name: ${prefix}" "${root}"/.github/workflows/*.yml | head -n 1)"
    [ -n "${file}" ] || { echo "no workflow job named ${context}"; return 1; }
    # The `on:` block ends at `permissions:`; a `paths:` there leaves a pull request that misses the paths waiting.
    if sed -n '/^on:/,/^permissions:/p' "${file}" | grep -q 'paths:'; then
      echo "${context} is in ${file}, which is path-filtered"
      return 1
    fi
  done <<<"${output}"
}

@test "the ruleset requires the checks of the always-running workflows" {
  run jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "${ruleset}"
  for context in "Validate plugin structure" "Test plugin installation" "Gitleaks" "Validate agent portability (static)" \
    "APM install (claude)" "APM install (codex)" "APM install (opencode)"; do
    [[ "${output}" == *"${context}"* ]]
  done
}
