#!/usr/bin/env bash
# PreToolUse hook: git push requires explicit user approval within the conversation.
#
# Approved commands must include "# user-approved" at the end of the command.
# Bash treats this as a comment, so git never sees it.
#
# Examples:
#   git push origin feat/my-feature                    -> blocked
#   git push origin feat/my-feature # user-approved   -> allowed

COMMAND=$(printf '%s' "${CLAUDE_TOOL_INPUT:-}" |
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('command', ''))
except Exception:
    pass
" 2>/dev/null) || COMMAND=""

# Allow commands that do not contain "git push"
if ! printf '%s' "${COMMAND}" | grep -qF "git push"; then
  exit 0
fi

# Allow if the approval marker is present
if printf '%s' "${COMMAND}" | grep -qF "# user-approved"; then
  exit 0
fi

# No marker -> block and explain how to proceed
printf '⚠️  Explicit user approval is required before running git push.\n'
printf '\nHow to proceed:\n'
printf '  1. Ask the user: "May I run git push?"\n'
printf '  2. Once the user approves, re-run the command with "# user-approved" appended.\n'
printf '\nExample: git push origin feat/my-feature # user-approved\n'
exit 2
