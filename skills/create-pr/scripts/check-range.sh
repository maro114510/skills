#!/usr/bin/env bash
# Checks the Range, every commit from the merge base of <base ref> with HEAD, before create-pr pushes it.
# Usage: check-range.sh <base ref>   (run from inside the repository)
# Classifies the Range with commit's classify-approval.sh. When approval is required, or the classifier fails,
# it opens difit on the whole Range with implement's review-range.sh and waits until the window closes.
# HEAD is pinned when the check starts; on approval the last line is `approved-head=<sha>`, the only commit
# the caller may push.
# Exit:
#   0      Approved: the classifier requires no approval, or difit closed without comments.
#   2      Usage or repository error; nothing was reviewed.
#   4      HEAD moved during the check, so the commit that was checked is no longer the branch tip.
#   other  Not approved: review-range.sh's own exit code, explained by its header and the output above.
set -uo pipefail

base="${1:-}"
if [[ -z "${base}" ]]; then
  echo "Usage: check-range.sh <base ref>" >&2
  exit 2
fi

skills_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
head="$(git rev-parse --verify 'HEAD^{commit}')" || exit 2

approve() {
  if [[ "$(git rev-parse HEAD)" != "${head}" ]]; then
    echo "check-range: HEAD moved from ${head} during the check; nothing is approved" >&2
    exit 4
  fi
  echo "approved-head=${head}"
  exit 0
}

if bash "${skills_root}/commit/scripts/classify-approval.sh" "${base}"; then
  approve
fi

merge_base="$(git merge-base "${base}" "${head}")" || exit 2
bash "${skills_root}/implement/scripts/review-range.sh" "${head}" "${merge_base}" || exit
approve
