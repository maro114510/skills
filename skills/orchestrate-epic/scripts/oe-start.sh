#!/usr/bin/env bash
# oe start
#
# Runs every step that starts an agent for one Issue, and prints the agent's whole prompt.
# The steps live here, not in SKILL.md, so a session that lost the skill to a compaction still starts agents correctly.
#
# Usage
#
#   oe start owner <owner/repo> <issue-number> [--claim] [<reason>]
#   oe start verifier <owner/repo> <issue-number>
#
# - Run it from the shared checkout, as oe worktree requires.
# - oe ready prints this command, filled in, as the fourth field of each line that starts an agent.
# - --claim is accepted and ignored, so a caller written for it still runs: oe worktree creates a missing Issue branch.
#
# | Role | Steps, in order | Agent type |
# |---|---|---|
# | owner | oe worktree add, oe brief owner, the working marker | pr-owner |
# | verifier | oe worktree add --detach, oe brief verifier, the working marker with the worktree's SHA | pr-verify |
#
# - The working marker is one hidden line at the end of the Issue body, replacing any earlier one:
#
#   <!-- oe:working role=<owner|verifier> at=<UTC start time> [sha=<SHA>] [session=<ID>] -->
#
#   oe ready reads it as the docs/design/orchestrate-epic.md Source of Truth says, and the session ID is there only for a person to trace.
# - The marker is written last, so a failed start leaves none.
# - The first step that fails ends the run with its exit code.
# - A worktree this run created is removed when a later step fails, so a failed start leaves no worktree.
#
# Output
#
# - On success, the agent's prompt: the canonical path of the agent's SKILL.md on the first line, then the brief.
# - The steps' own output is dropped on success, and goes to stderr when a step fails.
#
# Exit codes
#
# | Code | Meaning |
# |---|---|
# | 0 | The prompt was printed; start the agent with it |
# | 1 | A GitHub read or write, or Git, failed |
# | 2 | The arguments are invalid |
# | 4 | A state change: the Verifier's head moved |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-bot.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe start owner <owner/repo> <issue-number> [--claim] [<reason>]" >&2
  echo "       oe start verifier <owner/repo> <issue-number>" >&2
  exit 2
}

fail() {
  echo "oe start: $1" >&2
  exit 1
}

[[ $# -ge 3 ]] || usage "Expected a role, <owner/repo>, and <issue-number>"
role="$1"
repo="$2"
n="$3"
shift 3
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: ${repo}"
[[ "${n}" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: ${n}"
reason=""
case "${role}" in
owner)
  [[ "${1:-}" != "--claim" ]] || shift
  [[ $# -le 1 ]] || usage "Expected at most one <reason>"
  reason="${1:-}"
  ;;
verifier)
  [[ $# -eq 0 ]] || usage "A Verifier takes no reason"
  ;;
*) usage "Unknown role: ${role}" ;;
esac
now="${OE_NOW:-$(date -u +%s)}"
[[ "${now}" =~ ^[0-9]+$ ]] || usage "OE_NOW must be epoch seconds"

# A clone that opts in starts no agent when its Bot helper cannot mint a token: acting as the
# person instead would make the agent's work look like the person's.
bot_require_ready "${repo}" || {
  echo "oe start: not starting an agent because the Bot identity is not ready" >&2
  exit 1
}

# The steps below write the branch, the assignee, and the Verifier's pending status, so they take a
# Bot token; one that cannot be minted starts nothing instead of writing as the person.
bot_env_start "${repo}" || {
  echo "oe start: not starting an agent because the Bot token could not be minted" >&2
  exit 1
}

# The canonical path of the agent's SKILL.md, resolved before any step writes, so a missing skill starts nothing.
agent=pr-owner
[[ "${role}" == owner ]] || agent=pr-verify
skill="$(cd "${dir}/../../${agent}" 2>/dev/null && pwd -P)/SKILL.md"
[[ -f "${skill}" ]] || {
  echo "Cannot find ${agent}/SKILL.md next to orchestrate-epic" >&2
  exit 1
}
worktree=""
err="$(mktemp)" || fail "mktemp failed"
# Removes the worktree this run created, when a step after it fails.
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  local rc=$?
  rm -f "${err}"
  if ((rc != 0)) && [[ -n "${worktree}" ]]; then
    bash "${dir}/oe" worktree remove "${n}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Prints the session ID the harness set, or nothing when it set none.
# The first set among OE_SESSION_ID, CLAUDE_CODE_SESSION_ID, CODEX_THREAD_ID, and DSH_SESSION_ID wins.
# A value holding a space, a control character, or a dash pair reads as empty, so no value can end or break the marker line.
harness_session_id() {
  local name
  for name in OE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID DSH_SESSION_ID; do
    if [[ -n "${!name:-}" ]]; then
      [[ "${!name}" =~ ^[A-Za-z0-9._:/-]+$ && "${!name}" != *--* ]] && printf '%s\n' "${!name}"
      return 0
    fi
  done
}

# Writes the working marker of this start at the end of the Issue body, with the SHA $1 for a Verifier.
# Every earlier marker line is dropped, and every other line of the body stays as it was.
write_marker() {
  local at session marker body updated
  at="$(jq -nr --argjson t "${now}" '$t | todate')" || fail "cannot format the start time"
  session="$(harness_session_id)"
  marker="<!-- oe:working role=${role} at=${at}${1:+ sha=$1}${session:+ session=${session}} -->"
  body="$(gh api "repos/${repo}/issues/${n}" --jq '.body // ""' 2>"${err}")" ||
    fail "reading the body of Issue #${n} failed: $(head -n1 "${err}")"
  updated="$(jq -rn --arg body "${body}" --arg marker "${marker}" '
    ($body | if test("\r\n") then "\r\n" else "\n" end) as $nl
    | [$body | split($nl)[] | select(test("^<!-- oe:working ") | not)] | join($nl) | sub("\\s+$"; "")
    | (if . == "" then "" else . + $nl + $nl end) + $marker')" || fail "composing the marker for Issue #${n} failed"
  gh api -X PATCH "repos/${repo}/issues/${n}" -f body="${updated}" >/dev/null 2>"${err}" ||
    fail "writing the working marker on Issue #${n} failed: $(head -n1 "${err}")"
}

if [[ "${role}" == owner ]]; then
  worktree="$(bash "${dir}/oe" worktree add "${n}")" || exit $?
  brief="$(bash "${dir}/oe" brief owner "${repo}" "${n}" "${worktree}" ${reason:+"${reason}"})" || exit $?
  write_marker ""
else
  worktree="$(bash "${dir}/oe" worktree add "${n}" --detach)" || exit $?
  brief="$(bash "${dir}/oe" brief verifier "${repo}" "${n}" "${worktree}")" || exit $?
  write_marker "$(git -C "${worktree}" rev-parse HEAD)"
fi
printf '%s\n%s\n' "${skill}" "${brief}"
