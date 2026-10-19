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

# Command boundaries before a command word and after its last word, shared by both patterns, so
# `cd x&&git push`, `(git push)`, or `oe land merge>log` are seen as well.
START="(^|[[:space:];&|(\`\"'/{])"
END="([[:space:]\"';&|)<>}]|$)"
GIT_PUSH="${START}git([[:space:]]+[^[:space:]]*)*[[:space:]]+push${END}"
# An `oe` token: the bare name or the last path segment, or a shell variable that may hold the
# wrapper path, optionally quoted; then any words; then `ship ... publish` or `land ... merge`,
# where flags may sit between the two words.
OE_TOKEN="(${START}oe[\"']?|\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?[\"']?)"
OE_WORDS='([[:space:]]+[^[:space:]]+)*[[:space:]]+'
OE_MUTATION="${OE_TOKEN}${OE_WORDS}(ship${OE_WORDS}publish|land${OE_WORDS}merge)${END}"
MARKER='#[[:space:]]*user-approved[[:space:]]*$'

# guarded_in <text> prints what <text> runs that needs approval, or nothing.
guarded_in() {
  if printf '%s' "$1" | grep -qE "${GIT_PUSH}"; then
    printf 'git push'
  elif printf '%s' "$1" | grep -qE "${OE_MUTATION}"; then
    printf 'oe ship publish / oe land merge'
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
