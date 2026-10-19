#!/usr/bin/env bats
# Tests for board-edges.sh, commands §1 call 2. Filtering cases run on --snapshot; the live path runs
# against a stub gh on PATH, and the regression cases run the real gh offline, since gh rejects
# unknown arguments while parsing flags, before any auth or network call.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

bats_require_minimum_version 1.5.0

setup() {
  target="${BATS_TEST_DIRNAME}/board-edges.sh"
  # Epic 10 owns Tn 11 (leaf) and 12 (container, closed). 13 is a Tn.m under 12, 20 belongs to
  # another Epic, 30 has no parent. Closed blockers are dropped.
  board='[
    {"number":11,"parent":{"number":10},"blockedBy":{"nodes":[{"number":5,"state":"OPEN"},{"number":6,"state":"CLOSED"}]}},
    {"number":13,"parent":{"number":12},"blockedBy":{"nodes":[{"number":11,"state":"OPEN"}]}},
    {"number":20,"parent":{"number":99},"blockedBy":{"nodes":[{"number":11,"state":"OPEN"}]}},
    {"number":30,"parent":null,"blockedBy":{"nodes":[]}}
  ]'
  stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${stub_dir}"
}

# Installs a stub gh that records its arguments, one per line, then runs the body $1.
stub_gh() {
  cat >"${stub_dir}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${BATS_TEST_TMPDIR}/gh-args"
$1
EOF
  chmod +x "${stub_dir}/gh"
}

# Runs the real gh with no credentials and an empty config, so nothing reaches the network.
offline_gh() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    GH_CONFIG_DIR="${BATS_TEST_TMPDIR}/gh-config" GH_PROMPT_DISABLED=1 "$@"
}

@test "rejects bad arguments with exit 2" {
  run bash "${target}"
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo
  [ "${status}" -eq 2 ]
  run bash "${target}" noslash 10
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 0
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo ten
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 10 '{"a":1}'
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 10 '["12"]'
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 10 'not json'
  [ "${status}" -eq 2 ]
  run bash "${target}" --snapshot
  [ "${status}" -eq 2 ]
}

@test "regression: the old call 2 command line is rejected by gh as unknown arguments" {
  command -v gh >/dev/null || skip "gh not installed"
  # shellcheck disable=SC2016 # the old jq program, verbatim.
  run offline_gh gh issue list --repo o/r --state open --limit 200 \
    --json number,blockedBy,parent \
    --jq --argjson containers '[12]' \
    '[.[]|select(.parent.number == (env.EPIC|tonumber) or ([.parent.number] | inside($containers)))]'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown arguments"* ]]
}

@test "regression: the gh arguments the script passes are accepted by gh" {
  command -v gh >/dev/null || skip "gh not installed"
  run offline_gh bash "${target}" o/r 10 '[12]'
  # Offline, gh stops at authentication; a flag gh rejects would fail earlier with this message.
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"gh issue list failed"* ]]
  [[ "${output}" != *"unknown arguments"* ]]
  [[ "${output}" != *"unknown flag"* ]]
}

@test "live path passes no jq flags to gh and filters the board with jq" {
  stub_gh "printf '%s' '${board}'"
  PATH="${stub_dir}:${PATH}" run --separate-stderr bash "${target}" owner/repo 10 '[12]'
  [ "${status}" -eq 0 ]
  [ "${output}" = '[{"n":11,"b":[5]},{"n":13,"b":[11]}]' ]
  run ! grep -qx -e '--jq' -e '-q' "${BATS_TEST_TMPDIR}/gh-args"
  grep -qx -- 'number,blockedBy,parent' "${BATS_TEST_TMPDIR}/gh-args"
  grep -qx -- 'owner/repo' "${BATS_TEST_TMPDIR}/gh-args"
}

@test "BOARD_EDGES_LIMIT raises gh's --limit and rejects a non-integer" {
  stub_gh "printf '%s' '[]'"
  PATH="${stub_dir}:${PATH}" BOARD_EDGES_LIMIT=500 run --separate-stderr bash "${target}" owner/repo 10
  [ "${status}" -eq 0 ]
  [ "${output}" = '[]' ]
  grep -qx -- '500' "${BATS_TEST_TMPDIR}/gh-args"
  BOARD_EDGES_LIMIT=lots run bash "${target}" owner/repo 10
  [ "${status}" -eq 2 ]
}

@test "an open Tn.m under a closed container Tn keeps its open blockedBy edges" {
  run --separate-stderr bash "${target}" --snapshot - 10 '[12]' <<<"${board}"
  [ "${status}" -eq 0 ]
  [ "$(jq -c '.[] | select(.n == 13)' <<<"${output}")" = '{"n":13,"b":[11]}' ]
}

@test "an Issue whose parent is another Epic, or that has no parent, is excluded" {
  run --separate-stderr bash "${target}" --snapshot - 10 '[12]' <<<"${board}"
  [ "${status}" -eq 0 ]
  [ "$(jq -c '[.[].n]' <<<"${output}")" = '[11,13]' ]
}

@test "without containers only direct Tn children are read" {
  run --separate-stderr bash "${target}" --snapshot - 10 <<<"${board}"
  [ "${status}" -eq 0 ]
  [ "${output}" = '[{"n":11,"b":[5]}]' ]
}

@test "a gh failure exits 1 and prints no dependency list" {
  stub_gh "echo 'HTTP 502' >&2; exit 1"
  PATH="${stub_dir}:${PATH}" run --separate-stderr bash "${target}" owner/repo 10 '[12]'
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  [[ "${stderr}" == *"do not classify"* ]]
}

@test "a gh response that is not a JSON array exits 1 and prints no dependency list" {
  stub_gh "printf '%s' 'not json'"
  PATH="${stub_dir}:${PATH}" run --separate-stderr bash "${target}" owner/repo 10
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  stub_gh "printf '%s' '{\"message\":\"x\"}'"
  PATH="${stub_dir}:${PATH}" run --separate-stderr bash "${target}" owner/repo 10
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "an empty board response exits 1 and prints no dependency list" {
  stub_gh "exit 0"
  PATH="${stub_dir}:${PATH}" run --separate-stderr bash "${target}" owner/repo 10
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  : >"${BATS_TEST_TMPDIR}/empty.json"
  run --separate-stderr bash "${target}" --snapshot "${BATS_TEST_TMPDIR}/empty.json" 10
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "an Issue missing its blockedBy connection exits 1 instead of reading as no dependencies" {
  run --separate-stderr bash "${target}" --snapshot - 10 <<<'[{"number":11,"parent":{"number":10}}]'
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "a truncated blockedBy connection exits 1 instead of dropping edges" {
  run --separate-stderr bash "${target}" --snapshot - 10 \
    <<<'[{"number":11,"parent":{"number":10},"blockedBy":{"totalCount":2,"nodes":[{"number":5,"state":"OPEN"}]}}]'
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}
