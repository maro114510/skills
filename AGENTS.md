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
| `.github/workflows/test-plugin-install.yml` | CI: `validate` then `test-install`, on push to `main` and every PR |
| `.github/workflows/release.yml` | Creates a GitHub Release on a `v*` tag push after checking the tag matches both manifests |
| `cliff.toml` | `git-cliff` config used by `make release` |

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
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[ready] [base <branch>]"
---
```

| Key | Rule |
|---|---|
| `description` | Matched against user requests; include phrasings users naturally say |
| `disable-model-invocation` | Optional; `true` runs the skill as a single-shot prompt without an agentic loop, and the body directs every tool call, as in `create-pr` |
| `allowed-tools` | Comma-separated allowlist; `Bash(gh pr view:*)` allows only `gh pr view ...` |
| `argument-hint` | Shown on `/help` |

- The body is the full prompt; user arguments arrive as `$ARGUMENTS`
- Body language is English or the target repository's language
- Japanese stays only in `description` trigger phrases and user-facing output templates
- Convert an older Japanese body only when already editing it for another reason
- Declare only the tools a skill needs; prefer scoped `Bash(cmd:*)` when the command set is small and predictable

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

# Pre-commit hooks for shell scripts and workflows: https://github.com/j178/prek
brew install j178/tap/prek   # macOS, once
prek install                 # from the repo root
```
