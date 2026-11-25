#!/usr/bin/env bats
# Tests for tests/validate-skill-descriptions.sh: the check that keeps each model-invocable skill description within 400 bytes.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.
# So each mid-test `[[ ]]` ends in `|| false`, which fails it on every bash.

setup() {
  script="${BATS_TEST_DIRNAME}/validate-skill-descriptions.sh"
  skills="${BATS_TEST_TMPDIR}/skills"
  mkdir -p "${skills}"
}

# skill <name> <frontmatter lines...>: writes skills/<name>/SKILL.md with the lines between the --- fences.
skill() {
  local name="$1"
  shift
  mkdir -p "${skills}/${name}"
  {
    echo '---'
    printf '%s\n' "$@"
    echo '---'
    echo 'Body.'
  } >"${skills}/${name}/SKILL.md"
}

# chars <n>: n ASCII characters.
chars() {
  printf '%*s' "$1" '' | tr ' ' 'a'
}

@test "passes when every description is at most 400 bytes, 400 included" {
  skill short "name: short" "description: $(chars 10)"
  skill edge "name: edge" "description: $(chars 400)"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 0 ]
}

@test "fails at 401 bytes and names the skill and its size" {
  skill ok "name: ok" "description: $(chars 400)"
  skill long "name: long" "description: $(chars 401)"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"long"*"401"* ]] || false
  [[ "${output}" != *"ok"*"400 bytes"* ]] || false
}

@test "counts bytes, not characters" {
  # 134 characters of 3 bytes each is 402 bytes.
  ja="$(printf 'あ%.0s' $(seq 134))"
  skill ja "name: ja" "description: ${ja}"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"402"* ]] || false
}

@test "joins a folded value's lines with one space" {
  # 200 + space + 199 is 400 bytes, and the trailing newline of a folded scalar is not counted.
  skill folded "name: folded" "description: >" "  $(chars 200)" "  $(chars 199)" "argument-hint: x"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 0 ]
  skill folded "name: folded" "description: >" "  $(chars 200)" "  $(chars 200)" "argument-hint: x"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"401"* ]] || false
}

@test "skips a skill with disable-model-invocation true" {
  skill manual "name: manual" "description: $(chars 900)" "disable-model-invocation: true"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 0 ]
}

@test "checks a skill with disable-model-invocation false" {
  skill auto "name: auto" "description: $(chars 900)" "disable-model-invocation: false"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 1 ]
}

@test "ignores the quotes around a single-line value" {
  skill quoted "name: quoted" "description: \"$(chars 400)\""
  run bash "${script}" "${skills}"
  [ "${status}" -eq 0 ]
}

@test "fails a skill that has no description" {
  skill bare "name: bare"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"bare"* ]] || false
}

@test "reports every skill over the limit in one run" {
  skill one "name: one" "description: $(chars 500)"
  skill two "name: two" "description: $(chars 600)"
  run bash "${script}" "${skills}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"one"* ]] || false
  [[ "${output}" == *"two"* ]] || false
}

@test "the skills in this repository pass" {
  run bash "${script}"
  [ "${status}" -eq 0 ]
}
