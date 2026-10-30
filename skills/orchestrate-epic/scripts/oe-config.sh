# shellcheck shell=bash
# The limits, names, and shared reads that every oe subcommand uses.
# Each subcommand sources this file, so a reader and a writer never disagree on a limit or a name.
#
# | Name | Value | Meaning |
# |---|---|---|
# | no_checks_grace | 600 | Seconds a commit may go without checks before its CI counts as missing |
# | max_attempts | 3 | Owner attempts after the latest claim before the Issue parks |
# | max_verifier_starts | 2 | Verifier starts on one commit before the Issue parks |
# | verify_context | oe/verify | The commit status context that holds the verdict |
# | branch_prefix | feat/issue- | The prefix of an Issue branch, followed by the Issue number |
# | wait_timeout | 540 | Seconds one oe wait call waits for oe ready's output to change, under the 10-minute limit Claude Code puts on a background command |
# | wait_interval | 60 | Seconds between two oe ready runs inside oe wait |
# | idle_limit | 14400 | Seconds the output may stay unchanged with no agent running before the session ends |
#
# oe-records.jq defines which comments count as records when oe reads them, and oe-store.sh where the host-local records live.
# shellcheck disable=SC2034 # The sourcing subcommand reads these.
no_checks_grace=600
max_attempts=3
max_verifier_starts=2
verify_context=oe/verify
branch_prefix=feat/issue-
wait_timeout=540
wait_interval=60
idle_limit=14400

# Prints the marker that starts the body of a record of kind $1, such as claim.
# It must equal marker($kind) in oe-records.jq, which reads what this writes.
record_marker() {
  printf '<!-- oe:%s -->' "$1"
}

# Prints the number and head SHA of the newest open PR from Issue branch $2 in repository $1, separated by a tab.
# Prints nothing when the branch has no open PR in that repository; a fork's PR never counts.
# Returns 1 with the reason on stderr when the read fails or is unreadable.
open_pr_head() {
  local repo="$1" branch="$2" prs number number_sha ghe
  ghe="$(mktemp)" || {
    echo "mktemp failed" >&2
    return 1
  }
  prs="$(gh api "repos/${repo}/pulls?state=open&head=${repo%%/*}:${branch}&per_page=100" --jq '.[]
    | select((.head.repo.full_name // "" | ascii_downcase) == ("'"${repo}"'" | ascii_downcase)
      and .head.ref == "'"${branch}"'")
    | "\(.number)\t\(.head.sha)"' 2>"${ghe}")" || {
    echo "pull request read for ${branch} failed: $(head -n1 "${ghe}")" >&2
    rm -f "${ghe}"
    return 1
  }
  rm -f "${ghe}"
  while IFS=$'\t' read -r number number_sha; do
    [[ -n "${number}" ]] || continue
    if ! [[ "${number}" =~ ^[1-9][0-9]*$ && "${number_sha}" =~ ^[0-9a-f]{40}$ ]]; then
      echo "pull request read for ${branch} unreadable" >&2
      return 1
    fi
    printf '%s\t%s\n' "${number}" "${number_sha}"
    return 0
  done <<<"${prs}"
}
