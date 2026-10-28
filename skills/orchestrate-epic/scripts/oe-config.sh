# shellcheck shell=bash
# The limits and names that every oe subcommand shares.
# Each subcommand sources this file, so a reader and a writer never disagree on a limit or a name.
#
# | Name | Value | Meaning |
# |---|---|---|
# | no_checks_grace | 600 | Seconds a commit may go without checks before its CI counts as missing |
# | max_attempts | 3 | Owner attempts after the latest claim before the Issue parks |
# | max_verifier_starts | 2 | Verifier starts on one commit before the Issue parks |
# | verify_context | oe/verify | The commit status context that holds the verdict |
# | branch_prefix | feat/issue- | The prefix of an Issue branch, followed by the Issue number |
#
# oe-records.jq holds the markers of the records that oe writes on an Issue.
# shellcheck disable=SC2034 # The sourcing subcommand reads these.
no_checks_grace=600
max_attempts=3
max_verifier_starts=2
verify_context=oe/verify
branch_prefix=feat/issue-
