#!/usr/bin/env bash
# Identify a GitHub PR from an argument and emit `gh pr view` metadata JSON.
# Used by the pr-review-pe skill in Step 1.
#
# Usage: pr-review-pe-identify-pr.sh [<pr-number-or-url>]
# Exit codes:
#   0 — success; JSON metadata on stdout
#   2 — cannot identify PR (no current-branch PR and no/unparsable argument)
#   3 — gh CLI failed (network, auth, or remote error)

set -euo pipefail

input="${1:-}"
pr_number=""
repo=""

if [[ -z "${input}" ]]; then
  if ! pr_number="$(gh pr view --json number --jq '.number' 2>/dev/null)"; then
    printf 'Cannot identify PR: no PR for current branch and no argument provided.\n' >&2
    exit 2
  fi
elif [[ "${input}" =~ ^[0-9]+$ ]]; then
  pr_number="${input}"
elif [[ "${input}" =~ ^https?://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
  repo="${BASH_REMATCH[1]}"
  pr_number="${BASH_REMATCH[2]}"
else
  printf "Cannot identify PR from argument '%s'. Expected PR number, https://github.com/org/repo/pull/N URL, or empty.\n" "${input}" >&2
  exit 2
fi

json_fields="title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,comments,reviews,number"

if [[ -n "${repo}" ]]; then
  if ! gh pr view "${pr_number}" --repo "${repo}" --json "${json_fields}"; then
    printf 'gh pr view failed for PR #%s in %s.\n' "${pr_number}" "${repo}" >&2
    exit 3
  fi
else
  if ! gh pr view "${pr_number}" --json "${json_fields}"; then
    printf 'gh pr view failed for PR #%s.\n' "${pr_number}" >&2
    exit 3
  fi
fi
