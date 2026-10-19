#!/usr/bin/env bats
# Tests for .claude/hooks/require-user-approval.sh: git push and the irreversible oe subcommands
# need the approval marker, whether oe runs directly or through the orchestrate-epic wrapper.
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

@test "oe ship publish is blocked when invoked directly" {
  assert_blocked 'oe ship publish'
  assert_blocked 'oe --epic 3 ship publish'
  assert_blocked './oe ship publish'
  assert_blocked '/usr/local/bin/oe --repo a/b ship publish'
  assert_blocked 'cd oe && ./oe ship publish'
}

@test "oe land merge is blocked when invoked directly" {
  assert_blocked 'oe land merge'
  assert_blocked 'oe --epic 3 land merge --pr 9'
}

@test "the irreversible subcommands are blocked through the wrapper path" {
  assert_blocked 'skills/orchestrate-epic/scripts/oe ship publish --epic 3'
  assert_blocked 'bash skills/orchestrate-epic/scripts/oe land merge'
  # shellcheck disable=SC2016 # The variable must reach the hook unexpanded, as the model writes it.
  assert_blocked '"${CLAUDE_PLUGIN_ROOT}/skills/orchestrate-epic/scripts/oe" --epic 3 land merge'
  assert_blocked "'/plugins/skills/orchestrate-epic/scripts/oe' ship publish"
}

@test "shell-escaped or split-quoted command names do not bypass the hook" {
  assert_blocked '\oe ship publish'
  assert_blocked "'o'e ship publish"
  assert_blocked '"o"e land merge'
  assert_blocked 'o\e land merge'
  assert_blocked '\git push origin x'
  assert_blocked "g'i't push origin x"
  assert_blocked 'git "push" origin x'
  assert_allowed '\oe ship publish # user-approved'
}

@test "flags between the subcommand words do not bypass the hook" {
  assert_blocked 'oe ship --epic 3 publish'
  assert_blocked 'skills/orchestrate-epic/scripts/oe land --pr 9 merge'
}

@test "a guarded oe subcommand inside a compound command is blocked" {
  assert_blocked 'true && oe ship publish'
  assert_blocked 'echo start; skills/orchestrate-epic/scripts/oe land merge; echo done'
  assert_blocked '(oe land merge)'
}

@test "a guarded command split across lines is blocked" {
  assert_blocked $'oe --epic 3 ship \\\n  publish'
  assert_blocked $'skills/orchestrate-epic/scripts/oe \\\n  --epic 3 land merge'
  assert_blocked $'echo start\noe land merge'
}

@test "the wrapper path held in a variable does not bypass the hook" {
  # shellcheck disable=SC2016 # The variables must reach the hook unexpanded, as the model writes them.
  assert_blocked 'OE=skills/orchestrate-epic/scripts/oe; "$OE" ship publish'
  # shellcheck disable=SC2016
  assert_blocked '"${OE}" --epic 3 land merge'
}

@test "redirection or a closing brace right after the subcommand does not bypass the hook" {
  assert_blocked 'oe ship publish>out.json'
  assert_blocked 'oe land merge<in'
  assert_blocked '{ oe land merge;}'
  assert_blocked 'f() { oe land merge}'
}

@test "the marker approves only on the guarded command's own line" {
  assert_blocked $'echo hi # user-approved\noe ship publish'
  assert_blocked $'echo hi # user-approved\ngit push origin feat/x'
  assert_blocked $'git push origin main\n# user-approved'
  assert_blocked $'oe ship publish\n# user-approved'
  assert_blocked $'oe ship publish # user-approved\ngit push origin main'
  assert_blocked $'oe ship\npublish # user-approved'
  assert_allowed $'oe --epic 3 \\\n  ship publish # user-approved'
  assert_allowed $'cd repo\ngit push origin feat/x # user-approved'
  assert_allowed $'git push origin a # user-approved\ngit push origin b # user-approved'
}

@test "the irreversible subcommands with the marker are allowed" {
  assert_allowed 'oe ship publish # user-approved'
  assert_allowed 'skills/orchestrate-epic/scripts/oe --epic 3 land merge # user-approved'
}

@test "read-only oe subcommands are allowed" {
  assert_allowed 'oe resolve --epic 3'
  assert_allowed 'skills/orchestrate-epic/scripts/oe --snapshot s.json resolve --epic 3'
  assert_allowed 'oe ship'
  assert_allowed 'oe --version'
}

@test "commands that only mention the words are allowed" {
  assert_allowed 'go test ./oe/...'
  assert_allowed 'echo shoe ship publish'
  assert_allowed 'grep -r "land merge" docs'
}

@test "unparseable hook input fails" {
  run bash "${hook}" <<<'not json'
  [ "${status}" -eq 1 ]
}
