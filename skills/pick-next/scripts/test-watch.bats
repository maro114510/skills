#!/usr/bin/env bats
# Tests for watch.sh. pick.sh is faked: watch.sh runs from a copy next to a stub pick.sh that prints the file
# pick.json, or fails with the message in pick.err while that file exists.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.email t@example.invalid
  git config user.name t
  git config core.hooksPath /dev/null
  git commit -q --allow-empty -m base
  git remote add origin https://github.com/o/r.git
  scripts="${BATS_TEST_TMPDIR}/scripts"
  mkdir -p "${scripts}"
  cp "${BATS_TEST_DIRNAME}/watch.sh" "${scripts}/"
  cat >"${scripts}/pick.sh" <<EOF
#!/usr/bin/env bash
[ "\$#" -eq 0 ] || { echo "unexpected arguments: \$*" >&2; exit 2; }
if [ -e "${BATS_TEST_TMPDIR}/pick.err" ]; then cat "${BATS_TEST_TMPDIR}/pick.err" >&2; exit 1; fi
cat "${BATS_TEST_TMPDIR}/pick.json"
EOF
  pick '[]' '[]'
}

# Makes the fake pick.sh print a pick whose owner group holds pull requests $1 and next group Issues $2, each a JSON
# array of numbers, and whose blocked group holds Issues $3 and local group worktrees $4, when given.
pick() {
  rm -f "${BATS_TEST_TMPDIR}/pick.err"
  jq -nc --argjson o "$1" --argjson n "$2" --argjson b "${3:-[]}" --argjson l "${4:-[]}" \
    '{repo: "o/r", viewer: "me",
      owner: [$o[] | {kind: "pr", number: ., title: ("PR title " + tostring)}],
      next: [$n[] | {kind: "issue", number: ., title: ("Issue title " + tostring)}], nextTotal: ($n | length),
      blocked: [$b[] | {kind: "issue", number: ., title: ("Blocked " + tostring)}], blockedTotal: ($b | length),
      local: [$l[] | {path: ("/w/" + tostring), branch: ("b" + tostring), dirty: true}]}' \
    >"${BATS_TEST_TMPDIR}/pick.json"
}

# Makes the fake pick.sh fail with message $1.
pick_fails() {
  echo "$1" >"${BATS_TEST_TMPDIR}/pick.err"
}

watch() {
  run bash "${scripts}/watch.sh"
}

silent() {
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "the first run only records the pick and stays silent" {
  pick '[]' '[1, 2]'
  watch
  silent
}

@test "a pick that did not change stays silent" {
  pick '[]' '[1, 2]'
  watch
  watch
  silent
}

@test "a change under start next exits 3 with one line naming the first item" {
  pick '[]' '[1, 2]'
  watch
  pick '[]' '[2, 1]'
  watch
  [ "${status}" -eq 3 ]
  [ "${output}" = "o/r: start next: Issue title 2 (Issue 2)" ]
}

@test "a change under waits on you exits 3 with one line naming the first pull request" {
  pick '[]' '[1]'
  watch
  pick '[7]' '[1]'
  watch
  [ "${status}" -eq 3 ]
  [ "${output}" = "o/r: waits on you: PR title 7 (PR 7)" ]
}

@test "when waits on you empties, the line names the first item under start next" {
  pick '[7]' '[1]'
  watch
  pick '[]' '[1]'
  watch
  [ "${status}" -eq 3 ]
  [ "${output}" = "o/r: start next: Issue title 1 (Issue 1)" ]
}

@test "when both groups are empty after a change, the line says nothing is left" {
  pick '[]' '[1]'
  watch
  pick '[]' '[]'
  watch
  [ "${status}" -eq 3 ]
  [ "${output}" = "o/r: start next: nothing" ]
}

@test "a change only under blocked or local state stays silent" {
  pick '[]' '[1]' '[4]' '[]'
  watch
  pick '[]' '[1]' '[5]' '[9]'
  watch
  silent
}

@test "a change is told once, and the run after it is silent" {
  pick '[]' '[1]'
  watch
  pick '[]' '[2]'
  watch
  [ "${status}" -eq 3 ]
  watch
  silent
}

@test "a failed pick is told once with its first line, and later failures stay silent" {
  pick '[]' '[1]'
  watch
  pick_fails $'pick-next: cannot read the open Issues of o/r\nmore detail'
  watch
  [ "${status}" -eq 3 ]
  [ "${output}" = "o/r: pick-next failed: pick-next: cannot read the open Issues of o/r" ]
  watch
  silent
}

@test "after a failure, a recovered pick equal to the last one stays silent and a different one is told" {
  pick '[]' '[1]'
  watch
  pick_fails "offline"
  watch
  pick '[]' '[1]'
  watch
  silent
  pick_fails "offline"
  watch
  pick '[]' '[2]'
  watch
  [ "${status}" -eq 3 ]
  [ "${output}" = "o/r: start next: Issue title 2 (Issue 2)" ]
}

@test "a failure on the first run is told" {
  pick_fails "offline"
  watch
  [ "${status}" -eq 3 ]
  [ "${output}" = "o/r: pick-next failed: offline" ]
}

@test "a linked worktree shares the record of the main worktree" {
  pick '[]' '[1]'
  watch
  git worktree add -q "${BATS_TEST_TMPDIR}/linked"
  cd "${BATS_TEST_TMPDIR}/linked"
  watch
  silent
}

@test "outside a Git repository it exits 2 with a message" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p plain
  cd plain
  GIT_CEILING_DIRECTORIES="${BATS_TEST_TMPDIR}" run bash "${scripts}/watch.sh"
  [ "${status}" -eq 2 ]
  [ -n "${output}" ]
}
