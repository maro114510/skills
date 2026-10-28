#!/usr/bin/env bash
# PreToolUse hook: irreversible commands require explicit user approval within the conversation.
#
# Guarded commands:
#   - git push
#
# Approved commands must include "# user-approved" at the end of the command.
# Bash treats this as a comment, so the command never sees it.
#
# Examples:
#   git push origin feat/my-feature                  -> blocked
#   git push origin feat/my-feature # user-approved  -> allowed
#   git status                                       -> allowed

# Backslash-newline continuations are joined, because bash runs them as one command; every
# other newline stays, because it separates commands.
COMMAND=$(python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cmd = data.get('tool_input', {}).get('command', '')
    print(cmd.replace('\\\\\r\n', ' ').replace('\\\\\n', ' ').replace('\r', '\n'))
except Exception:
    sys.exit(1)
" 2>/dev/null) || {
  printf 'hook: failed to parse hook input JSON from stdin\n' >&2
  exit 1
}

# Command boundaries before a command word and after its last word, so `cd x&&git push`,
# `(git push)`, or `git push>log` are seen as well.
START="(^|[[:space:];&|(\`\"'/{])"
END="([[:space:]\"';&|)<>}]|$)"
GIT_PUSH="${START}git([[:space:]]+[^[:space:]]*)*[[:space:]]+push${END}"
MARKER='#[[:space:]]*user-approved[[:space:]]*$'

# guarded_in <text> prints what <text> runs that needs approval, or nothing. Backslashes and
# quotes are removed first, because bash drops them before running a word: `\git`, `'g'it`, and
# `g"i"t` all run the real command.
guarded_in() {
  local text
  text="$(printf '%s' "$1" | tr -d "\\\\'\"")"
  if printf '%s' "${text}" | grep -qE "${GIT_PUSH}"; then
    printf 'git push'
  fi
}

# The whole command flattened to one line still catches a guarded command spread over lines.
guarded="$(guarded_in "${COMMAND//$'\n'/ }")"

# Allow commands that run nothing guarded
if [[ -z "${guarded}" ]]; then
  exit 0
fi

# Allow only when every line that runs a guarded command ends with the approval marker itself.
# A marker on another line, such as a lone `# user-approved` after `git push`, approves nothing,
# and a guarded command visible only across lines cannot be approved at all.
approved=0
while IFS= read -r line; do
  [[ -n "$(guarded_in "${line}")" ]] || continue
  if ! printf '%s' "${line}" | grep -qE "${MARKER}"; then
    approved=0
    break
  fi
  approved=1
done <<<"${COMMAND}"

if [[ "${approved}" -eq 1 ]]; then
  exit 0
fi

# No marker -> block and explain how to proceed
printf '⚠️  Explicit user approval is required before running %s.\n' "${guarded}" >&2
printf '\nHow to proceed:\n' >&2
printf '  1. Ask the user: "May I run %s?"\n' "${guarded}" >&2
printf '  2. Once the user approves, re-run the command with "# user-approved" appended to the same line.\n' >&2
printf '\nExample: git push origin feat/my-feature # user-approved\n' >&2
exit 2
