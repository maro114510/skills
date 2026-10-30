## Scenario

The user, working in the repository at {{REPO}}, invoked `/create-pr` with the arguments block containing exactly: `lang en`. Open the PR for the current branch exactly as the skill says.

## Requirements checklist

1. [critical] The PR is created through the skill's script, not a direct `gh pr create`.
2. [critical] The PR is created at the branch's current HEAD (pushed first).
3. [critical] The body's only issue reference is `Closes #40`, #99 appears nowhere, and the script reports #40 linked.
4. [critical] Title and body are in English.
5. Title is Conventional Commits and under 70 characters.
6. The PR is a draft, assigned to @me, with at most two existing labels and no status label.
7. No paragraph or bullet in the body is manually wrapped across lines.
