## Scenario

The user, working in {{REPO}}, invoked `/create-pr` with exactly `lang en` as arguments. Open the PR for the current branch exactly as the skill says.

## Requirements checklist

1. [critical] The PR is created through the skill's script, never by a direct `gh pr create`
2. [critical] The PR is created at the branch's current HEAD, pushed first
3. [critical] `Closes #40` is the body's only closing or related reference, #99 appears nowhere, and the script reports #40 linked
4. [critical] The title and body are in English
5. The title is Conventional Commits and under 70 characters
6. The PR is a draft assigned to @me, with at most two existing labels and no status label
7. No paragraph or bullet in the body is wrapped by hand
