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
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Not a Git worktree: ${worktree}" >&2
  exit 2
}

# Gitignored paths are left out so build output from local checks does not count as a change.
fingerprint() {
  {
    git status --porcelain=v1 --untracked-files=all
    git diff HEAD --binary
    git ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do git hash-object -- "${f}"; done
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
  # OpenCode has no OS sandbox, so write-capable git options and redirects are denied explicitly.
  # `--standalone` is required for OPENCODE_CONFIG_CONTENT to be read at all: the shared background
  # service drops it, so without the flag this whole deny block is inert and the reviewer keeps its
  # write, shell, and fetch tools. With it, denied tools disappear from the tool list.
  # The review prompt is the message, with no flag at all: OpenCode V2's `run` has no `--command`
  # flag and no `review` command is installed for it, so a flag form fails argument parsing and the
  # review never runs. Nothing is pinned with `--agent` either, since a plan agent only appends a
  # plan reply; edits stay denied here.
  # The one-command rule keeps the reviewer off pipes and 2>&1, which the redirect deny would reject.
  # The last matching rule wins, so denies for options that run another program follow the allows.
  # OpenCode does not apply `*>*` to a redirect inside a compound command, so a write outside the
  # worktree is not prevented; the fingerprint only catches writes inside it.
  OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"deny","webfetch":"deny","bash":{"*":"deny",
    "git diff*":"allow","git status*":"allow","git log*":"allow","git show*":"allow","git ls-files*":"allow",
    "git branch --show-current":"allow","git rev-parse*":"allow","git merge-base*":"allow","git blame*":"allow",
    "echo*":"allow","head*":"allow","cat*":"allow","ls*":"allow","rg*":"allow","go vet*":"allow","go test*":"allow",
    "go *-exec*":"deny","go *-toolexec*":"deny","go vet*-vettool*":"deny","rg*--pre*":"deny",
    "rg*--hostname-bin*":"deny",
    "*--output*":"deny","*>*":"deny"}}}' \
    opencode run --standalone "Review the uncommitted changes. Run exactly one command per bash call, with no pipes, &&, ;, or redirects such as 2>&1." </dev/null >"${out}" 2>"${log}"
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
