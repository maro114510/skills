#!/usr/bin/env bash
# oe update
#
# Merges the base branch into an Issue's PR branch, as GitHub's Update branch button does, and waits for the new head.
# oe ready prints this command, filled in, for a head that lacks the merge commit of a sibling PR.
# No agent starts, so an Epic with many siblings spends no Owner attempts on it.
#
# Usage
#
#   oe update <owner/repo> <issue-number> <sha>
#
# - <sha> is the head oe ready read; GitHub refuses the update once the head moved from it.
# - The PR is the open PR from the Issue's branch in this repository.
# - OE_NOW sets the record time in epoch seconds, as in oe ready.
# - OE_UPDATE_TIMEOUT and OE_UPDATE_INTERVAL set the seconds to wait for the new head and between two head reads,
#   update_timeout and update_interval by default.
#
# Writes, in order
#
# 1. An update record on this host that names the SHA.
#    oe ready counts these per head, and parks the Issue once max_updates requests left the head unchanged.
# 2. The update request to GitHub, with the SHA as the expected head.
#
# The record goes first, so a refused or stalled request still counts.
# A conflict with the base leaves the PR conflicting, which oe ready hands to an Owner as a repair.
#
# Output
#
# - On success, one line holding update, the PR number, and the new head SHA, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | GitHub moved the head | The update record, and the PR branch on GitHub |
# | 1 | A GitHub read or the record store failed, or GitHub refused the update | Nothing, or only the update record when stderr says the request failed |
# | 2 | The arguments are invalid | Nothing |
# | 4 | The Issue's branch has no open PR, or its head is no longer the SHA | Nothing |
# | 5 | GitHub accepted the update, and the head did not move within the timeout | The update record |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe update <owner/repo> <issue-number> <sha>" >&2
  exit 2
}

fail() {
  echo "oe update: $1" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage "Expected <owner/repo> <issue-number> <sha>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
[[ "$3" =~ ^[0-9a-f]{40}$ ]] || usage "Invalid SHA, expected 40 hex digits: $3"
repo="$1"
n="$2"
sha="$3"
branch="${branch_prefix}${n}"
timeout="${OE_UPDATE_TIMEOUT:-${update_timeout}}"
interval="${OE_UPDATE_INTERVAL:-${update_interval}}"
[[ "${timeout}" =~ ^[0-9]+$ ]] || usage "OE_UPDATE_TIMEOUT must be whole seconds"
[[ "${interval}" =~ ^[0-9]+$ ]] || usage "OE_UPDATE_INTERVAL must be whole seconds"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

found="$(open_pr_head "${repo}" "${branch}" 2>"${err}")" || fail "$(head -n1 "${err}")"
pr="${found%%$'\t'*}"
head="${found#*$'\t'}"

if [[ -z "${pr}" ]]; then
  echo "oe update: ${branch} has no open pull request on ${repo}, so nothing was requested" >&2
  exit 4
fi
if [[ "${head}" != "${sha}" ]]; then
  echo "oe update: PR #${pr} head is ${head}, not ${sha}, so nothing was requested" >&2
  exit 4
fi

at="$(record_now 2>"${err}")" || usage "$(head -n1 "${err}")"
record="$(jq -cn --arg at "${at}" --arg sha "${sha}" '{kind: "update", at: $at, sha: $sha}')" ||
  fail "cannot build the update record, so nothing was requested"
records_add "${repo}" "${n}" "${record}" 2>"${err}" ||
  fail "recording the update of Issue #${n} failed, so nothing was requested: $(head -n1 "${err}")"

gh api -X PUT "repos/${repo}/pulls/${pr}/update-branch" -f expected_head_sha="${sha}" >/dev/null 2>"${err}" ||
  fail "recorded the update, but GitHub refused to update PR #${pr}: $(head -n1 "${err}")"

# GitHub merges in the background, so the new head appears some seconds after the request was accepted.
deadline=$(($(date -u +%s) + timeout))
while :; do
  found="$(open_pr_head "${repo}" "${branch}" 2>"${err}")" || fail "$(head -n1 "${err}")"
  head="${found#*$'\t'}"
  if [[ -n "${found}" && "${head}" != "${sha}" ]]; then
    printf 'update\t%s\t%s\n' "${pr}" "${head}"
    exit 0
  fi
  (($(date -u +%s) < deadline)) || break
  sleep "${interval}"
done
echo "oe update: GitHub accepted the update, but PR #${pr} head stayed ${sha} for ${timeout}s" >&2
exit 5
