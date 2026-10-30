#!/usr/bin/env bash
# oe verdict
#
# Writes a Verifier's verdict on the PR head SHA it checked, and keeps its findings on this host.
# The verdict is a commit status on that SHA, so a push leaves the new head without one and nothing else must reset it.
#
# Usage
#
#   oe verdict <owner/repo> <issue-number> <sha> success|failure < findings
#
# - The findings are read from stdin, one line per acceptance criterion, as pr-verify writes them.
# - The PR is the open PR from the Issue's branch in this repository.
#
# Writes, in order
#
# 1. The findings, as a verdict record on this host that names the state and the SHA.
#    The next Owner reads the latest one for its PR head with oe records.
# 2. The verify_context status on the SHA.
#    oe ready reads it as the verdict.
#
# The findings go first, so a verdict never exists without its findings.
# Findings whose status write failed leave the SHA without a verdict, which oe ready treats as unverified.
# Nothing goes to a PR or Issue comment.
#
# Output
#
# - On success, one line holding verdict, the state, and the SHA, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | The verdict was written | The verdict record and the status |
# | 1 | A GitHub read or write, or the record store, failed | Nothing, or only the verdict record when stderr says the status failed |
# | 2 | The arguments are invalid, or the findings are empty | Nothing |
# | 4 | The Issue's branch has no open PR, or its head is no longer the SHA | Nothing |
#
# A push between the head read and the status write leaves the status on the old SHA, which the new head never shows.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe verdict <owner/repo> <issue-number> <sha> success|failure < findings" >&2
  exit 2
}

fail() {
  echo "oe verdict: $1" >&2
  exit 1
}

[[ $# -eq 4 ]] || usage "Expected <owner/repo> <issue-number> <sha> success|failure"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
[[ "$3" =~ ^[0-9a-f]{40}$ ]] || usage "Invalid SHA, expected 40 hex digits: $3"
[[ "$4" == success || "$4" == failure ]] || usage "Invalid verdict, expected success or failure: $4"
repo="$1"
n="$2"
sha="$3"
state="$4"
branch="${branch_prefix}${n}"

findings="$(cat)" || usage "Cannot read the findings from stdin"
[[ "${findings}" =~ [^[:space:]] ]] || usage "The findings on stdin are empty"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

found="$(open_pr_head "${repo}" "${branch}" 2>"${err}")" || fail "$(head -n1 "${err}")"
pr="${found%%$'\t'*}"
head="${found#*$'\t'}"

if [[ -z "${pr}" ]]; then
  echo "oe verdict: ${branch} has no open pull request on ${repo}, so nothing was written" >&2
  exit 4
fi
if [[ "${head}" != "${sha}" ]]; then
  echo "oe verdict: PR #${pr} head is ${head}, not ${sha}, so nothing was written" >&2
  exit 4
fi

at="$(record_now 2>"${err}")" || usage "$(head -n1 "${err}")"
record="$(jq -cn --arg at "${at}" --arg sha "${sha}" --arg state "${state}" --arg findings "${findings}" \
  '{kind: "verdict", at: $at, sha: $sha, state: $state, findings: $findings}')" ||
  fail "cannot build the verdict record, so no verdict was written"
records_add "${repo}" "${n}" "${record}" 2>"${err}" ||
  fail "recording the findings of Issue #${n} failed, so no verdict was written: $(head -n1 "${err}")"

gh api -X POST "repos/${repo}/statuses/${sha}" -f state="${state}" -f context="${verify_context}" \
  -f description="Verifier ${state} on PR #${pr}" --jq '.state' >/dev/null 2>"${err}" ||
  fail "recorded the findings, but writing the ${verify_context} status on ${sha} failed: $(head -n1 "${err}")"
printf 'verdict\t%s\t%s\n' "${state}" "${sha}"
