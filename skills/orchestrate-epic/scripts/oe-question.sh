#!/usr/bin/env bash
# oe question
#
# Writes an Owner's question on its Issue as a question record.
# oe ready then waits on the Issue until an engineer answers with an unmarked comment.
#
# Usage
#
#   oe question <owner/repo> <issue-number> < question
#
# - The question is read from stdin and written after the marker.
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The question was written | The question record |
# | 1 | The GitHub write failed | Nothing |
# | 2 | The arguments are invalid, or the question is empty | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe question <owner/repo> <issue-number> < question" >&2
  exit 2
}

fail() {
  echo "oe question: $1" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <issue-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"

question="$(cat)" || usage "Cannot read the question from stdin"
[[ "${question}" =~ [^[:space:]] ]] || usage "The question on stdin is empty"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

body="$(record_marker question)"$'\n'"${question}"
url="$(gh api -X POST "repos/${repo}/issues/${n}/comments" -f body="${body}" --jq '.html_url' 2>"${err}")" ||
  fail "writing the question on Issue #${n} failed: $(head -n1 "${err}")"
printf 'question\t%s\n' "${url}"
