# Problem and done definition

## Where it stops today

Status Fact. After a person approves an Epic, the orchestration skill implements child Issues and opens pull requests, then stops in four places until a person acts.

| Stop | Cause |
|---|---|
| Conversation ends | Orchestration runs inside a session. Closing it halts everything |
| Pull request opened | Nobody fixes CI failures or review comments |
| Dependent Issue | Work waits for the dependency to merge and close, and only a person merges |
| Approval kinds | Human approval and reviewer pass are not distinguished. Approving reviews are never read |

## Done

Status Agreed. An Epic left alone ends with every child Issue in one state.

| State |
|---|
| Merged |
| Pull request open, waiting for human review |
| Stopped for a human decision, and the person notified |
| Not started because a dependency is in one of the two states above |

The last state was added because work never stacks on an unmerged dependency.

## Priority

Status Agreed. Meeting the done definition unattended comes first. Auto-merge is a means, limited to changes that need no human review.

## Scope

Status Agreed.

| In | Out |
|---|---|
| Implementation and pull request creation | Turning retrospectives into deduplicated Issues |
| CI failure repair | Deploy and release |
| Reviewer review and repair of its findings | Automatic rollback |
| Merge | |
| Starting the next Issue after a dependency closes | |
