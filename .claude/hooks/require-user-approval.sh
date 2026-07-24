#!/usr/bin/env bash
# PreToolUse hook: git push requires explicit user approval within the conversation.
#
# Approved commands must include "# user-approved" at the end of the command.
# Bash treats this as a comment, so git never sees it.
#
# Examples:
#   git push origin feat/my-feature                    -> blocked
#   git push origin feat/my-feature # user-approved   -> allowed

COMMAND=$(python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('command', ''))
except Exception:
    sys.exit(1)
" 2>/dev/null) || {
  printf 'hook: failed to parse hook input JSON from stdin\n' >&2
  exit 1
}

# Allow commands that do not contain "git push" (word-boundary aware)
if ! printf '%s' "${COMMAND}" | grep -qE '(^|[[:space:]])git([[:space:]]+[^[:space:]]*)*[[:space:]]+push([[:space:]]|$)'; then
  exit 0
fi

# Allow if the approval marker appears at the end of the command
if printf '%s' "${COMMAND}" | grep -qE '#[[:space:]]*user-approved[[:space:]]*$'; then
  exit 0
fi

# No marker -> block and explain how to proceed
printf '⚠️  Explicit user approval is required before running git push.\n' >&2
printf '\nHow to proceed:\n' >&2
printf '  1. Ask the user: "May I run git push?"\n' >&2
printf '  2. Once the user approves, re-run the command with "# user-approved" appended.\n' >&2
printf '\nExample: git push origin feat/my-feature # user-approved\n' >&2
exit 2
