# skills

Agent skills with one mission: what the owner decides to build becomes a change that solves the problem it came from. See [MISSION.md](MISSION.md).

Today, agents take an Issue to a verified PR with TDD, a separate-context self-review, and Principal Engineer-level reviews, and a human makes only the calls that matter, such as the merge.

## Supported Harnesses

- Claude Code
- OpenCode
- Codex

## Install

Each install below resolves a release the owner has already run. The owner runs `main`, which can be ahead of the latest release.

### APM

APM is the recommended route. [APM](https://github.com/microsoft/apm) installs every skill and both agents into Claude Code, Codex, and OpenCode with one command.

It resolves the newest release within the major version its range names.

```sh
apm install -g 'maro114510/skills#^1.0.0' -t claude,codex,opencode
```

### Claude Code plugin

Requires Claude Code 2.1.275 or later. It installs the release that the marketplace entry on `main` names.

```sh
/plugin install skills --marketplace maro114510/skills
```

### npx

It installs the exact release tag named below.

```sh
npx --yes skills add 'maro114510/skills#v1.2.0' --agent claude-code --skill '*' --global --yes
```

### GitHub CLI

It installs the latest release.

```sh
gh skill install maro114510/skills --all --agent claude-code --scope user
```

## Skills

| Skill | Goal |
|---|---|
| `commit` | Commit the working tree with a Conventional Commits message. |
| `create-github-issues` | Turn a plan or TODO list into Issues, under an Epic only when tasks depend on each other. |
| `create-pr` | Create a pull request with a useful description. |
| `diagram-conventions` | Create or review a diagram in the right type's notation without adding or dropping meaning. |
| `domain-master` | Review domain model and state-transition code for illegal states that bypass validation and for names or operations that misstate the business rules. |
| `extreme-compact` | Compact writing down to its essential point without changing its meaning. |
| `frame-problem` | Frame a vague problem before implementation and converge on a direction. |
| `implement` | Implement a change with quality first: ground it in the repository, test it, and self-review it before push. |
| `locate` | Find the local worktree, branch, and current state for a pull request or Issue URL before working on it. |
| `manage-design-documents` | Decide whether a change needs a Design Doc, an ADR, both, or neither, and keep them small and free of metadata Git already holds. |
| `orchestrate-epic` | Turn an Epic's child Issues into verified PRs in dependency order, leaving every merge to a human. |
| `pick-next` | Pick what to work on next in the current repository, and say what waits on you and what is blocked; optionally list open Discussions. |
| `pr-doc-review-pe` | Review design documents from a Principal Engineer perspective. |
| `pr-review-pe` | Review code diffs from a Principal Engineer perspective. |
| `shakedown` | Generate a pre-release QA runbook from a diff or design document. |
| `skill-cleaner` | Audit and slim down skill definitions. |
| `tear-down` | Blank-slate red-team a plan or design instead of defending or polishing it. |
| `why-man` | Challenge assumptions with higher-level Why questions. |

`shared` is not a skill; `skills/shared` holds files that several skills use.

## Agents

APM deploys `agents/` to multiple harnesses.

| Agent | Started by | Job |
|---|---|---|
| `pr-owner` | `orchestrate-epic` | Implement or repair one Issue's PR, or ask a question on the Issue |
| `pr-verify` | `orchestrate-epic` | Check one PR head SHA against its Issue's acceptance criteria and record the verdict |

| Rule | Detail |
|---|---|
| Allowed frontmatter | `name`, `description`, `mode` |
| Forbidden frontmatter | `model`, `tools`, permissions, `color`, skill preload fields |
| Runtime policy | Invoking skill or harness configuration |
| Before committing | Run `make validate` |
