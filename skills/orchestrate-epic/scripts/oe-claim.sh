#!/usr/bin/env bash
# oe claim
#
# Claims an Issue: creates its branch on origin at the default branch head, then writes the claim record on it.
# GitHub's create-ref API refuses a ref that already exists, so two claims for one Issue never both succeed.
#
# Usage
#
#   oe claim <owner/repo> <issue-number>
#
# Output
#
# - On success, one line holding claimed, the branch, and its head SHA, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | Claimed | The branch and the claim record |
# | 1 | A GitHub read or write failed | Nothing, or only the branch when stderr says the record failed |
# | 2 | The arguments are invalid | Nothing |
# | 4 | The branch already exists | Nothing |
#
# The claim record is written after the branch, so a refused claim never writes one.
# A record written for a refused claim would reset the attempt count of whoever holds the branch.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe claim <owner/repo> <issue-number>" >&2
  exit 2
}

fail() {
  echo "oe claim: $1" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <issue-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"
branch="${branch_prefix}${n}"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

default="$(gh api "repos/${repo}" --jq '.default_branch' 2>"${err}")" ||
  fail "repository read failed: $(head -n1 "${err}")"
[[ "${default}" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "default branch unreadable"
sha="$(gh api "repos/${repo}/git/ref/heads/${default}" --jq '.object.sha' 2>"${err}")" ||
  fail "default branch head read failed: $(head -n1 "${err}")"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || fail "default branch head unreadable"

if ! gh api -X POST "repos/${repo}/git/refs" -f ref="refs/heads/${branch}" -f sha="${sha}" --jq '.ref' \
  >/dev/null 2>"${err}"; then
  if grep -q 'Reference already exists' "${err}"; then
    echo "oe claim: ${branch} already exists on ${repo}, so Issue #${n} is already claimed" >&2
    exit 4
  fi
  fail "creating ${branch} failed: $(head -n1 "${err}")"
fi

body="$(record_marker claim)"$'\n'"Claimed: created \`${branch}\` at ${sha}."
gh api -X POST "repos/${repo}/issues/${n}/comments" -f body="${body}" --jq '.html_url' >/dev/null 2>"${err}" ||
  fail "created ${branch}, but writing the claim record on Issue #${n} failed: $(head -n1 "${err}")"
printf 'claimed\t%s\t%s\n' "${branch}" "${sha}"
