#!/usr/bin/env bash
# Asks a fresh, read-only session of the given harness to review a worktree's uncommitted changes.
# Usage: self-review.sh <claude|codex|opencode> <worktree-path>
# Exit: 0 review ran and the worktree is unchanged, 1 review failed, 2 usage error, 3 reviewer changed the worktree.
set -uo pipefail

harness="${1:-}"
worktree="${2:-}"

case "${harness}" in
claude | codex | opencode) ;;
*)
  echo "Unsupported harness: ${harness:-<none>}" >&2
  exit 2
  ;;
esac
cd "${worktree}" 2>/dev/null || {
  echo "Not a directory: ${worktree:-<none>}" >&2
  exit 2
}

# Gitignored paths are left out so build output from local checks does not count as a change.
fingerprint() {
  {
    git status --porcelain=v1 --untracked-files=all
    git diff HEAD --binary
    git ls-files --others --exclude-standard | while IFS= read -r f; do git hash-object -- "${f}"; done
  } | git hash-object --stdin
}

out="$(mktemp "${TMPDIR:-/tmp}/self-review.XXXXXX")"
log="${out}.log"
trap 'rm -f "${out}" "${log}"' EXIT

before="$(fingerprint)"
# Read-only is pinned per CLI because user configuration can override each CLI's default sandbox.
# The Claude Code level is pinned because /code-review otherwise reuses the last level typed, and ultra is billed.
case "${harness}" in
claude)
  claude -p "/code-review high" --permission-mode plan --no-session-persistence </dev/null >"${out}" 2>"${log}"
  ;;
codex)
  codex exec review --uncommitted --ephemeral -c 'sandbox_mode="read-only"' -o "${out}" </dev/null >"${log}" 2>&1
  ;;
opencode)
  OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"deny","webfetch":"deny","bash":{"*":"deny","git diff*":"allow","git status*":"allow","git log*":"allow","git show*":"allow","git ls-files*":"allow"}}}' \
    opencode run --agent plan --command review </dev/null >"${out}" 2>"${log}"
  ;;
esac
reviewer_rc=$?
after="$(fingerprint)"

cat "${out}"
echo
if [[ "${before}" != "${after}" ]]; then
  echo "REVIEWER_CHANGED_WORKTREE"
  exit 3
fi
if [[ "${reviewer_rc}" -ne 0 ]]; then
  tail -n 20 "${log}"
  echo "REVIEWER_EXIT=${reviewer_rc}"
  exit 1
fi
exit 0
