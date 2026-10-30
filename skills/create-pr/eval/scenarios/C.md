## Scenario

The user, working in {{REPO}}, invoked `/create-pr` with exactly `lang en` as arguments. Open the PR for the current branch exactly as the skill says.

## Requirements checklist

1. [critical] The PR is created through the skill's script, never by a direct `gh pr create`
2. [critical] The PR is created at the branch's current HEAD, pushed first
3. [critical] The PR targets `feat/export-api`, the branch's configured `gh-merge-base`, its only closing or related reference is `Closes #8` on its own line, and nothing is linked through the API
4. [critical] The title and body are in English, in the skill's default structure, since no template exists
5. The title is Conventional Commits and under 70 characters
6. The PR is a draft assigned to @me, with at most two existing labels and no status label
7. The user is told every NOTICE from the script and what to do next
8. No paragraph or bullet in the body is wrapped by hand
