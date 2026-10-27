#!/usr/bin/env bash
# Re-runs the failed jobs of a workflow run once, to rule out a flaky check, and records the failed check run's id
# so wait treats the item as waiting until a newer run of that check finishes.
# Usage: rerun.sh <owner/repo> <pr> --session <token> --key <item key> --workflow-run <id> --run-id <failed check run id>
# The ids come from the check_failed event: check.workflowRunId and check.runId. Test hook BABYSIT_GH replaces gh.
# GitHub refusing the re-run records nothing, and the caller then repairs the check as if it had been confirmed.
# Exit: 0 re-run and recorded, 1 GitHub refused or the record failed, 2 usage error, 3 the lock is not ours.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

GH="${BABYSIT_GH:-gh}"

usage() {
  echo "$1" >&2
  echo "Usage: rerun.sh <owner/repo> <pr> --session <token> --key <item key> --workflow-run <id> --run-id <failed check run id>" >&2
  exit 2
}

repo="${1:-}"
pr="${2:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 2
token=""
key=""
workflow_run=""
run_id=""
while (($# > 0)); do
  case "$1" in
  --session) token="${2:-}" ;;
  --key) key="${2:-}" ;;
  --workflow-run) workflow_run="${2:-}" ;;
  --run-id) run_id="${2:-}" ;;
  *) usage "Unknown option: $1" ;;
  esac
  (($# >= 2)) || usage "$1 needs a value"
  shift 2
done
[[ "${token}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
[[ "${key}" == k:* ]] || usage "--key needs a check item key"
[[ "${workflow_run}" =~ ^[0-9]+$ ]] || usage "--workflow-run needs a number"
[[ "${run_id}" =~ ^[0-9]+$ ]] || usage "--run-id needs a number"

# The lock check comes first, so a session that lost the PR re-runs nothing.
bash "${script_dir}/ledger.sh" touch "${repo}" "${pr}" "${token}" || exit $?
"${GH}" run rerun "${workflow_run}" --failed --repo "${repo}" >&2 </dev/null || {
  echo "GitHub did not re-run workflow run ${workflow_run}" >&2
  exit 1
}
# Recording comes after, so a crash in between shows the failure again and re-runs once more instead of waiting for nothing.
bash "${script_dir}/ledger.sh" record "${repo}" "${pr}" "${token}" "${key}" rerun --run-id "${run_id}" || exit 1
