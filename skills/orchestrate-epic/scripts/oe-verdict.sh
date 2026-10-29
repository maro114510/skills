#!/usr/bin/env bash
# oe verdict
#
# Writes a Verifier's verdict on the PR head SHA it checked, with its findings.
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
# 1. The findings, as a PR comment that starts with the verdict record marker and names the state and the SHA.
#    The next Owner reads the latest such comment.
# 2. The verify_context status on the SHA, whose target URL links that comment.
#    oe ready reads it as the verdict.
#
# The comment goes first, so a verdict never exists without its findings.
# A comment whose status write failed leaves the SHA without a verdict, which oe ready treats as unverified.
#
# Output
#
# - On success, one line holding verdict, the state, the SHA, and the findings URL, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The verdict was written | The findings comment and the status |
# | 1 | A GitHub read or write failed | Nothing, or only the findings comment when stderr says the status failed |
# | 2 | The arguments are invalid, or the findings are empty | Nothing |
# | 4 | The Issue's branch has no open PR, or its head is no longer the SHA | Nothing |
#
# A push between the head read and the status write leaves the status on the old SHA, which the new head never shows.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

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

body="$(record_marker verdict)"$'\n'"Verdict **${state}** on ${sha}."$'\n\n'"${findings}"
url="$(gh api -X POST "repos/${repo}/issues/${pr}/comments" -f body="${body}" --jq '.html_url' 2>"${err}")" ||
  fail "writing the findings on PR #${pr} failed, so no verdict was written: $(head -n1 "${err}")"
[[ "${url}" =~ ^https:// ]] || fail "writing the findings on PR #${pr} returned no URL, so no verdict was written"

gh api -X POST "repos/${repo}/statuses/${sha}" -f state="${state}" -f context="${verify_context}" \
  -f description="Verifier ${state}; findings on PR #${pr}" -f target_url="${url}" --jq '.state' \
  >/dev/null 2>"${err}" ||
  fail "wrote the findings at ${url}, but writing the ${verify_context} status on ${sha} failed: $(head -n1 "${err}")"
printf 'verdict\t%s\t%s\t%s\n' "${state}" "${sha}" "${url}"
