# skills

Personal agent skills for Claude Code and compatible coding agents.

## Install

### npx

```sh
npx --yes skills add maro114510/skills --agent claude-code --skill '*' --global --yes
```

### GitHub CLI

```sh
gh skill install maro114510/skills --agent claude-code --scope user
```

## Skills

| Skill | Goal |
|---|---|
| `create-pr` | Create a pull request with a useful description. |
| `frame-problem` | Frame a vague problem before implementation and converge on a direction. |
| `ja-style-check` | Review and improve Japanese technical writing. |
| `md-review` | Preview and review Markdown changes. |
| `pr-doc-review-pe` | Review design documents from a Principal Engineer perspective. |
| `pr-lessons` | Extract reusable lessons from past PR reviews. |
| `pr-review-pe` | Review code diffs from a Principal Engineer perspective. |
| `security-review` | Review PRs or files for security risks. |
| `skill-cleaner` | Audit and slim down skill definitions. |
| `tdd-test-cases` | Design practical TDD test cases. |
