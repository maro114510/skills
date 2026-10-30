#!/usr/bin/env bash
# oe claim
#
# Claims an Issue: creates its branch on origin at the default branch head, then records the claim on this host.
# GitHub's create-ref API refuses a ref that already exists, so two claims for one Issue never both succeed.
# The claim record goes to the record store that oe-store.sh defines, never to GitHub.
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
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | Claimed | The branch on GitHub and the claim record |
# | 1 | A GitHub read or write, or the record store, failed | Nothing, or only the branch when stderr says the record failed |
# | 2 | The arguments are invalid | Nothing |
# | 4 | The branch already exists | Nothing |
#
# The claim record is written after the branch, so a refused claim never writes one.
# A record written for a refused claim would reset the attempt count of whoever holds the branch.
# When only the record fails, oe ready still sees the branch, and counts every attempt record of the Issue.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

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

at="$(record_now 2>"${err}")" || usage "$(head -n1 "${err}")"

if ! gh api -X POST "repos/${repo}/git/refs" -f ref="refs/heads/${branch}" -f sha="${sha}" --jq '.ref' \
  >/dev/null 2>"${err}"; then
  if grep -q 'Reference already exists' "${err}"; then
    echo "oe claim: ${branch} already exists on ${repo}, so Issue #${n} is already claimed" >&2
    exit 4
  fi
  fail "creating ${branch} failed: $(head -n1 "${err}")"
fi

records_add "${repo}" "${n}" '{"kind":"claim","at":"'"${at}"'"}' 2>"${err}" ||
  fail "created ${branch}, but recording the claim of Issue #${n} failed: $(head -n1 "${err}")"
printf 'claimed\t%s\t%s\n' "${branch}" "${sha}"
