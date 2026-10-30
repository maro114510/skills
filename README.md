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
| `babysit` | Watch a pull request without waking the model until checks, comments, or readiness change, and with `drive` fix and push CI failures and review feedback on your own PR. |
| `create-pr` | Create a pull request with a useful description. |
| `diagram-conventions` | Create or review a diagram in the right type's notation without adding or dropping meaning. |
| `domain-master` | Review domain model and state-transition code for illegal states that bypass validation. |
| `frame-problem` | Frame a vague problem before implementation and converge on a direction. |
| `orchestrate-epic` | Turn an Epic's child Issues into verified PRs in dependency order, leaving every merge to a human. |
| `pr-doc-review-pe` | Review design documents from a Principal Engineer perspective. |
| `pr-review-pe` | Review code diffs from a Principal Engineer perspective. |
| `research-transfer-checker` | Check whether a claim stays within the scope of its cited research. |
| `skill-cleaner` | Audit and slim down skill definitions. |
| `tear-down` | Blank-slate red-team a plan or design instead of defending or polishing it. |
| `write-researched-document` | Research, verify, and draft an evidence-backed Markdown document. |
| `why-man` | Challenge assumptions with higher-level Why questions. |

## Agents

APM deploys `agents/` to multiple harnesses.

| Agent | Started by | Job |
|---|---|---|
| `pr-owner` | `orchestrate-epic` | Implement or repair one Issue's PR, or ask a question on the Issue |
| `pr-verify` | `orchestrate-epic` | Check one PR head SHA against its Issue's acceptance criteria and record the verdict |

| Rule | Detail |
|---|---|
| Allowed frontmatter | `name`, `description` |
| Forbidden frontmatter | `model`, `tools`, permissions, `color`, skill preload fields |
| Runtime policy | Invoking skill or harness configuration |
| Before committing | Run `make validate` |
