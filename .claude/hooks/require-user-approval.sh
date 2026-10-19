#!/usr/bin/env bash
# PreToolUse hook: irreversible commands require explicit user approval within the conversation.
#
# Guarded commands:
#   - git push
#   - oe ship publish and oe land merge, the only oe subcommands that push, open a PR, or merge,
#     whether oe runs directly, by path, or through skills/orchestrate-epic/scripts/oe
#
# Approved commands must include "# user-approved" at the end of the command.
# Bash treats this as a comment, so the command never sees it.
#
# Examples:
#   git push origin feat/my-feature                            -> blocked
#   git push origin feat/my-feature # user-approved            -> allowed
#   skills/orchestrate-epic/scripts/oe --epic 3 ship publish   -> blocked
#   oe resolve --epic 3                                        -> allowed

# The command is flattened to one line: backslash-newline continuations are joined and every
# other newline becomes a space, so a guarded command split across lines is still seen, and
# the approval marker counts only at the very end of the whole command.
COMMAND=$(python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cmd = data.get('tool_input', {}).get('command', '')
    print(cmd.replace('\\\\\n', ' ').replace('\r', ' ').replace('\n', ' '))
except Exception:
    sys.exit(1)
" 2>/dev/null) || {
  printf 'hook: failed to parse hook input JSON from stdin\n' >&2
  exit 1
}

GIT_PUSH='(^|[[:space:]])git([[:space:]]+[^[:space:]]*)*[[:space:]]+push([[:space:]]|$)'
# An `oe` token: the bare name or the last path segment, or a shell variable that may hold the
# wrapper path, optionally quoted; then any words; then `ship ... publish` or `land ... merge`,
# where flags may sit between the two words.
OE_TOKEN="((^|[[:space:];&|(\`\"'/])oe[\"']?|\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?[\"']?)"
OE_WORDS='([[:space:]]+[^[:space:]]+)*[[:space:]]+'
OE_END="([[:space:]\"';&|)<>}]|$)"
OE_MUTATION="${OE_TOKEN}${OE_WORDS}(ship${OE_WORDS}publish|land${OE_WORDS}merge)${OE_END}"

guarded=''
if printf '%s' "${COMMAND}" | grep -qE "${GIT_PUSH}"; then
  guarded='git push'
elif printf '%s' "${COMMAND}" | grep -qE "${OE_MUTATION}"; then
  guarded='oe ship publish / oe land merge'
fi

# Allow commands that run nothing guarded
if [[ -z "${guarded}" ]]; then
  exit 0
fi

# Allow if the approval marker appears at the end of the command
if printf '%s' "${COMMAND}" | grep -qE '#[[:space:]]*user-approved[[:space:]]*$'; then
  exit 0
fi

# No marker -> block and explain how to proceed
printf '⚠️  Explicit user approval is required before running %s.\n' "${guarded}" >&2
printf '\nHow to proceed:\n' >&2
printf '  1. Ask the user: "May I run %s?"\n' "${guarded}" >&2
printf '  2. Once the user approves, re-run the command with "# user-approved" appended.\n' >&2
printf '\nExample: git push origin feat/my-feature # user-approved\n' >&2
exit 2
