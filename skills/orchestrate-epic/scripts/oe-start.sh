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
# | owner --claim | oe claim, oe attempt, oe worktree add, oe brief owner | pr-owner |
# | owner | oe attempt, oe worktree add, oe brief owner | pr-owner |
# | verifier | oe worktree add --detach, oe brief verifier | pr-verify |
#
# - The first step that fails ends the run with its exit code.
# - A worktree this run created is removed when a later step fails, so a failed start leaves no worktree.
#
# Output
#
# - On success, the agent's prompt: the canonical path of the agent's SKILL.md on the first line, then the brief.
# - The steps' own output goes to stderr.
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

# Runs oe subcommand $1 with the rest as arguments, its output to stderr, and ends the run with its code on failure.
step() {
  local rc
  bash "${dir}/oe" "$@" >&2
  rc=$?
  ((rc == 0)) || exit "${rc}"
}

skills_root="$(cd "${dir}/../.." && pwd -P)"
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

if [[ "${role}" == owner ]]; then
  if [[ "${claim}" == true ]]; then
    step claim "${repo}" "${n}"
  fi
  step attempt "${repo}" "${n}"
  worktree="$(bash "${dir}/oe" worktree add "${n}")" || exit $?
  brief="$(bash "${dir}/oe" brief owner "${repo}" "${n}" "${worktree}" ${reason:+"${reason}"})" || exit $?
  printf '%s\n%s\n' "${skills_root}/pr-owner/SKILL.md" "${brief}"
else
  worktree="$(bash "${dir}/oe" worktree add "${n}" --detach)" || exit $?
  brief="$(bash "${dir}/oe" brief verifier "${repo}" "${n}" "${worktree}")" || exit $?
  printf '%s\n%s\n' "${skills_root}/pr-verify/SKILL.md" "${brief}"
fi
