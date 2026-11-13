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
#
# | Role | Steps, in order | Agent type |
# |---|---|---|
# | owner --claim | oe claim, oe attempt, oe worktree add, oe brief owner, run record | pr-owner |
# | owner | oe attempt, oe worktree add, oe brief owner, run record | pr-owner |
# | verifier | oe worktree add --detach, oe brief verifier, run record | pr-verify |
#
# - The run record, in the store oe-store.sh lays out, is how oe ready finds the agent running until its worktree is removed.
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
# | 1 | A GitHub read or write, Git, or the record store failed |
# | 2 | The arguments are invalid |
# | 4 | A limit or a state change: the branch already exists, the attempts are used, or the Verifier's head moved or reached its start limit |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-bot.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe start owner <owner/repo> <issue-number> [--claim] [<reason>]" >&2
  echo "       oe start verifier <owner/repo> <issue-number>" >&2
  exit 2
}

[[ $# -ge 3 ]] || usage "Expected a role, <owner/repo>, and <issue-number>"
role="$1"
repo="$2"
n="$3"
shift 3
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: ${repo}"
[[ "${n}" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: ${n}"
claim=false
reason=""
case "${role}" in
owner)
  if [[ "${1:-}" == "--claim" ]]; then
    claim=true
    shift
  fi
  [[ $# -le 1 ]] || usage "Expected at most one <reason>"
  reason="${1:-}"
  ;;
verifier)
  [[ $# -eq 0 ]] || usage "A Verifier takes no reason"
  ;;
*) usage "Unknown role: ${role}" ;;
esac

# A clone that opts in starts no agent when its Bot helper cannot mint a token: acting as the
# person instead would make the agent's work look like the person's.
bot_require_ready "${repo}" || {
  echo "oe start: not starting an agent because the Bot identity is not ready" >&2
  exit 1
}

# Runs oe subcommand $1 with the rest as arguments, and ends the run with its code on failure.
# Its output is dropped on success, because a harness shows stderr merged into the prompt, and goes to stderr on failure.
step() {
  local rc out
  out="$(bash "${dir}/oe" "$@" 2>&1)"
  rc=$?
  ((rc == 0)) || {
    printf '%s\n' "${out}" >&2
    exit "${rc}"
  }
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
# Removes the worktree this run created, when a step after it fails.
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  local rc=$?
  if ((rc != 0)) && [[ -n "${worktree}" ]]; then
    bash "${dir}/oe" worktree remove "${n}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Records the agent of this role as running, after every other step, so a failed start leaves no running agent.
record_run() {
  local at
  at="$(record_now)" &&
    records_add "${repo}" "${n}" "$(jq -cn --arg at "${at}" --arg role "${role}" '{kind: "run", at: $at, role: $role}')" ||
    exit 1
}

if [[ "${role}" == owner ]]; then
  if [[ "${claim}" == true ]]; then
    step claim "${repo}" "${n}"
  fi
  step attempt "${repo}" "${n}"
  worktree="$(bash "${dir}/oe" worktree add "${n}")" || exit $?
  brief="$(bash "${dir}/oe" brief owner "${repo}" "${n}" "${worktree}" ${reason:+"${reason}"})" || exit $?
  record_run
  printf '%s\n%s\n' "${skill}" "${brief}"
else
  worktree="$(bash "${dir}/oe" worktree add "${n}" --detach)" || exit $?
  brief="$(bash "${dir}/oe" brief verifier "${repo}" "${n}" "${worktree}")" || exit $?
  record_run
  printf '%s\n%s\n' "${skill}" "${brief}"
fi
