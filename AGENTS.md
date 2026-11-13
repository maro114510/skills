# AGENTS.md

Repository instructions for coding agents.

## Overview

| Item | Value |
|---|---|
| Purpose | Claude Code plugin that packages personal skills |
| Install | `claude plugin install` |
| Invocation | `/skill-name [arguments]` |
| Plugin identifier | `skills@maro114510-agent-skills` |
| Install scope | `--scope user` |

## Layout

| Path | Role |
|---|---|
| `.claude-plugin/plugin.json` | Name, version, description, author |
| `.claude-plugin/marketplace.json` | Source location used by `claude plugin install` |
| `skills/<skill-name>/SKILL.md` | Frontmatter and prompt body of one skill |
| `skills/<skill-name>/references/` | Optional large static documents the prompt pulls in |
| `agents/<agent-name>.md` | Portable subagent that APM deploys; only `name`, `description`, and `mode: subagent` frontmatter, and listed in `tests/validate-apm.sh` |
| `skills/orchestrate-epic/scripts/oe` | Shell helpers that read and write orchestrate-epic's state on GitHub and in host-local records, laid out in `oe-store.sh`; each `oe-<subcommand>.sh` header documents one subcommand |
| `skills/**/*.bats` | Script tests that `.github/workflows/lint-shell.yml` runs |
| `docs/design/orchestrate-epic.md` | The orchestrate-epic Design Doc that oe and the agents implement |
| `.github/workflows/test-plugin-install.yml` | CI: `validate` then `test-install`, on push to `main` and every PR |
| `.github/workflows/secret-scan.yml` | CI: gitleaks on push to `main` and every PR |
| `.github/workflows/release.yml` | Creates a GitHub Release on a `v*` tag push after checking the tag matches both manifests and its commit is reachable from main |
| `cliff.toml` | `git-cliff` config used by `make release` |

`docs/design` holds only Design Docs that describe the current target, as `manage-design-documents` defines them; work the owner decided to build is an Issue.
Ideas, experiments, and open questions go to [Discussions](https://github.com/maro114510/skills/discussions) as [Discussion #638](https://github.com/maro114510/skills/discussions/638) describes, never to Issues. The repository is public, so a post never carries work context.

## Versions and Releases

- Update both manifests together; updating only one breaks `claude plugin install`
- Bump versions with the Makefile release targets, never by hand
- `make release` infers the next SemVer from Conventional Commits via `git-cliff`
- Tags carry the `v` prefix, e.g. `v0.28.0`; manifest versions omit it, e.g. `0.28.0`
- Workflow actions are commit-pinned; update them with Dependabot only

| Bump | Commit type | Skill change |
|---|---|---|
| Major | `!` or `BREAKING CHANGE` | Breaking interface change or skill removal |
| Minor | `feat:` | New skill or meaningful new capability |
| Patch | `fix:` `perf:` `refactor:` `docs:` | Fix for ambiguity or a bug in a skill body |
| None | `ci:` `test:` `chore:` | - |

Baseline tag, required once before the first automated release:

```bash
git tag -a v0.27.0 -m v0.27.0
git push origin v0.27.0
```

## Skill Format

```yaml
---
name: <skill-name>
description: >
  <Natural language description, also used for trigger-phrase matching>
disable-model-invocation: true
argument-hint: "[ready] [base <branch>]"
---
```

| Key | Rule |
|---|---|
| `description` | Matched against user requests; include phrasings users naturally say |
| `disable-model-invocation` | Optional; `true` only stops Claude from loading the skill automatically. It does not disable the agentic loop: the skill still runs through `/name` and calls its tools normally, as in `orchestrate-epic` |
| `argument-hint` | Shown on `/help` |

- The body is the full prompt; user arguments arrive as `$ARGUMENTS`
- Body language is English or the target repository's language
- Japanese stays only in `description` trigger phrases and user-facing output templates
- Convert an older Japanese body only when already editing it for another reason
- Do not declare `allowed-tools`: it only pre-approves tools in Claude Code and has no effect in OpenCode or Pi, so it cannot restrict a skill's tools on every supported harness

## Target Repository Config

Per-user or per-clone settings live in git config and are never committed.
Skills read them with `git config --get <key>`, so git decides between local and global.

| git config key | Values | Resolved by |
|---|---|---|
| `skills.lang` | `ja`, `en` | `skills/create-pr/scripts/lang.sh` only; its header holds the precedence, and skills call it instead of restating it |
| `skills.herdr` | `true`, `false`; unset means `false` | `skills/orchestrate-epic/scripts/oe-board.sh` only, and only inside Herdr; `true` opens the Epic's board pane |
| `skills.babysit.agent` | An agent command, such as `claude -p`; unset makes `drive.sh` exit 2 | `skills/babysit/scripts/drive.sh` only; split on whitespace, with the prompt appended as the last argument |
| `skills.notify` | A shell command, such as `herdr notification show "$1" --body "$2"`; unset or empty means no notification | `skills/orchestrate-epic/scripts/oe-wait.sh` only; run through `sh -c` with a one-line message as `$1` and a link as `$2` for each item that needs the person |
| `skills.bot` | The login of the GitHub App bot the agents act as, with or without the `[bot]` suffix; unset means none | `bot_def` in `skills/orchestrate-epic/scripts/oe-config.sh` and `babysit_bot` in `skills/babysit/scripts/common.sh`; its records count for oe, and its comments never count as a person's |

## Workflow

1. Create or edit `skills/<skill-name>/SKILL.md`
2. Commit with Conventional Commits
3. Run `claude plugin validate .`
4. Open a PR; CI validates and test-installs

## Commands

```bash
# Validate manifests; requires the claude CLI
claude plugin validate .

# Test the full installation flow
claude plugin marketplace add ./
claude plugin install skills@maro114510-agent-skills --scope user
claude plugin list | grep skills

# Pre-commit hooks for shell scripts, workflows, and secrets: https://github.com/j178/prek
brew install j178/tap/prek   # macOS, once
brew install gitleaks        # the secret hook's scanner, once
prek install                 # from the repo root
```
