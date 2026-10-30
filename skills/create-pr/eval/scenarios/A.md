## Scenario

The user, working in the repository at {{REPO}}, invoked `/create-pr` with NO arguments (the arguments block is empty). Open the PR for the current branch exactly as the skill says.

## Requirements checklist

1. [critical] The PR is created through the skill's script, not a direct `gh pr create`.
2. [critical] The PR is created at the branch's current HEAD (pushed first).
3. [critical] The body has `Closes #12` on its own line, as its only closing reference, and the script reports #12 linked.
4. [critical] The body follows the repository's PR template, every section filled.
5. Title is Conventional Commits, under 70 characters, with a Japanese subject.
6. The PR is a draft, assigned to @me, with at most two existing labels and no status label.
7. No item under 動作確認 is checked, because nothing in the repository can run it.
8. No paragraph or bullet in the body is manually wrapped across lines.
