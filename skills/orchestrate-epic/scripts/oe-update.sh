#!/usr/bin/env bash
# oe update
#
# Updates an Issue branch with the base branch through GitHub, so a sibling PR's merge never leaves another PR waiting for a person.
# oe ready prints this command as the fourth field of an update-branch line. No agent starts and no attempt is spent.
#
# Usage
#
#   oe update <owner/repo> <issue-number>
#
# Updating
#
# - The branch is the Issue's, and the pull request is its newest open one from that branch in this repository.
# - GitHub merges the base into the head and answers before the new head exists, so the next oe ready shows the new head.
#   That head has no verdict, and CI and a Verifier run on it as on any new head.
# - The call names the head it read, so a head that moved since is refused and nothing is merged.
# - GitHub refuses the update when the merge conflicts. oe ready then reads the PR as conflicting and starts an Owner,
#   which resolves the conflict as it resolves any other.
# - The new head's checks start only when the update runs under an identity whose pushes start workflows.
#   A push made with the workflow's own GITHUB_TOKEN starts none, and oe ready parks a head that still has no checks after no_checks_grace.
#
# Records
#
# - An update record holds the head the branch has before the call, written before the call so a crash never leaves a merge unrecorded.
#   oe-starts.jq reads it so that a merge the session made is never counted as a push of the latest Owner start.
# - Repeating the call on the same head writes no second record.
#
# Output
#
# - On success, one line holding updated, the pull request number, and the head SHA the update replaced, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | GitHub accepted the update | An update record, and the branch on GitHub |
# | 1 | A GitHub read or write, or the record store, failed | Nothing, or only the record when stderr says the update failed |
# | 2 | The arguments are invalid | Nothing |
# | 4 | The branch has no open pull request, the head moved, or the merge conflicts | Nothing, or only the record |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe update <owner/repo> <issue-number>" >&2
  exit 2
}

fail() {
  echo "oe update: $1" >&2
  exit 1
}

refuse() {
  echo "oe update: $1" >&2
  exit 4
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <issue-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"
branch="${branch_prefix}${n}"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

at="$(record_now 2>"${err}")" || usage "$(head -n1 "${err}")"
found="$(open_pr_head "${repo}" "${branch}" 2>"${err}")" || fail "$(head -n1 "${err}")"
pr="${found%%$'\t'*}"
sha="${found#*$'\t'}"
[[ -n "${pr}" ]] || refuse "${branch} has no open pull request on ${repo}, so nothing was updated"

records="$(records_read "${repo}" "${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
if ! jq -e --arg sha "${sha}" 'last // {} | .kind == "update" and .head == $sha' <<<"${records}" >/dev/null 2>&1; then
  record="$(jq -cn --arg at "${at}" --arg head "${sha}" '{kind: "update", at: $at, head: $head}')" ||
    fail "cannot build the record of Issue #${n}"
  records_add "${repo}" "${n}" "${record}" 2>"${err}" ||
    fail "recording the update of Issue #${n} failed: $(head -n1 "${err}")"
fi

if ! gh api -X PUT "repos/${repo}/pulls/${pr}/update-branch" -f expected_head_sha="${sha}" >/dev/null 2>"${err}"; then
  message="$(head -n1 "${err}")"
  case "$(tr '[:upper:]' '[:lower:]' <<<"${message}")" in
  *"merge conflict"*) refuse "PR #${pr} conflicts with its base, so GitHub did not update it: ${message}" ;;
  *"expected head sha"*) refuse "PR #${pr} moved since its head ${sha:0:7} was read, so nothing was updated: ${message}" ;;
  *) fail "updating PR #${pr} failed: ${message}" ;;
  esac
fi
printf 'updated\t%s\t%s\n' "${pr}" "${sha}"
