#!/usr/bin/env bats
# Tests for .claude/hooks/require-user-approval.sh: git push needs the approval marker.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  hook="${BATS_TEST_DIRNAME}/../.claude/hooks/require-user-approval.sh"
}

# hook_on <command> runs the hook on a Bash tool call carrying that command.
hook_on() {
  local payload
  payload="$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}}))' "$1")"
  run bash "${hook}" <<<"${payload}"
}

assert_blocked() {
  hook_on "$1"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"approval is required"* ]]
}

assert_allowed() {
  hook_on "$1"
  [ "${status}" -eq 0 ]
}

@test "git push stays blocked without the marker" {
  assert_blocked 'git push origin feat/x'
}

@test "git push next to a shell operator is blocked" {
  assert_blocked 'cd repo&&git push origin x'
  assert_blocked '(git push origin x)'
  assert_blocked 'echo a;git push'
  assert_blocked 'git push;echo done'
  assert_blocked 'git push>log'
  assert_blocked '/usr/bin/git push origin x'
  assert_blocked '{ git push; }'
}

@test "git commands that are not a push are allowed" {
  assert_allowed 'git pushx origin'
  assert_allowed 'git status&&git log'
  assert_allowed 'echo legit push'
}

@test "git push with the marker is allowed" {
  assert_allowed 'git push origin feat/x # user-approved'
}

@test "shell-escaped or split-quoted git push does not bypass the hook" {
  assert_blocked '\git push origin x'
  assert_blocked "g'i't push origin x"
  assert_blocked 'git "push" origin x'
}

@test "a git push split across lines or joined by a continuation is blocked" {
  assert_blocked $'git \\\n  push origin x'
  assert_blocked $'echo start\ngit push origin x'
}

@test "the marker approves only on the git push's own line" {
  assert_blocked $'echo hi # user-approved\ngit push origin feat/x'
  assert_blocked $'git push origin main\n# user-approved'
  assert_blocked $'git push origin a # user-approved\ngit push origin main'
  assert_allowed $'git \\\n  push origin feat/x # user-approved'
  assert_allowed $'cd repo\ngit push origin feat/x # user-approved'
  assert_allowed $'git push origin a # user-approved\ngit push origin b # user-approved'
}

@test "unparseable hook input fails" {
  run bash "${hook}" <<<'not json'
  [ "${status}" -eq 1 ]
}

@test "create-pr's documented push-and-create call is blocked until its push line carries the marker" {
  local documented
  documented="$(awk '/^\*\*6\.1 Run one command\*\*/ { s = 1 } s && /^```bash/ { b = 1; next } b && /^```$/ { exit } b' \
    "${BATS_TEST_DIRNAME}/../skills/create-pr/SKILL.md")"
  [ "${documented#git push }" != "${documented}" ]
  [ "${documented#*create-linked-pr.sh}" != "${documented}" ]
  assert_blocked "${documented}"
  assert_allowed "${documented/&&/&& # user-approved}"
}
