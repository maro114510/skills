# Issue Footer

SKILL.md Step 3 reads this file whenever an issue number is inferable from the branch name, `$ARGUMENTS`, or the conversation.
Judge whether merging the whole branch, not this commit alone, resolves the issue:

- `Closes #NNN` by default, unless `gh issue view NNN --json subIssuesSummary` shows open sub-issues, `completed` below `total`: a partial branch must not close a parent, and a squash merge keeps commit footers. If the command fails, keep `Closes`.
- `Related #NNN` only when the branch leaves part of the issue's required implementation undone, or the issue is only cited in passing rather than being the one this branch works on. Undone needs an explicit signal: the caller reports a deferred requirement or criterion that still needs implementing, such as one in `SKIPPED`, or the user says the implementation is partial.

Post-merge verification, QA, E2E tests, and release or deploy work never make an issue `Related`, even when the caller reports them as deferred or lists them in `SKIPPED`: they happen after merge by nature, so a branch whose only remaining work is of that kind takes `Closes`.
A criterion that lacks evidence but was not deferred does not by itself make it `Related`.

On a follow-up commit, such as a review fix, keep `Closes` if an earlier branch commit, from the `origin/HEAD..HEAD` log, already carries it for the issue; never downgrade it to `Related` without one of the signals above. An earlier `Related` does not carry forward: judge afresh.

create-pr copies this keyword into the PR, and a merge commit closes the issue from it alone.
