# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A Claude Code **plugin** that packages personal skills (slash commands) for installation via `claude plugin install`. Skills are invoked by users as `/skill-name [arguments]` inside Claude Code sessions.

- Plugin identifier: `skills@maro114510-agent-skills`
- Installation scope: user-level (`--scope user`)

## Plugin Manifest Files

Two files define the plugin:

- `.claude-plugin/plugin.json` — name, version, description, author metadata
- `.claude-plugin/marketplace.json` — source location used during `claude plugin install`

**Both files must be updated together — updating only one will cause `claude plugin install` to fail.** Use the Makefile release targets instead of editing versions manually.

`make release` uses `git-cliff` and `cliff.toml` to infer the next SemVer from Conventional Commits. Git tags include the `v` prefix, for example `v0.28.0`; manifest versions omit it, for example `0.28.0`.

This repository needs a one-time baseline tag before the first automated release:

```bash
git tag -a v0.27.0 -m v0.27.0
git push origin v0.27.0
```

Version bump rules:
- Major: breaking changes (`!` or `BREAKING CHANGE`)
- Minor: `feat:`
- Patch: `fix:`, `perf:`, `refactor:`, `docs:`
- No release bump: `ci:`, `test:`, `chore:`

## Validation and CI

```bash
# Validate plugin manifests locally (requires claude CLI)
claude plugin validate .

# Test full installation flow
claude plugin marketplace add ./
claude plugin install skills@maro114510-agent-skills --scope user
claude plugin list | grep skills
```

CI runs two sequential jobs (`validate` → `test-install`) via `.github/workflows/test-plugin-install.yml` on push to `main` and all PRs. The workflow uses commit-pinned action versions — update these with Dependabot, not manually.

`.github/workflows/release.yml` creates a GitHub Release when a `v*` tag is pushed. It verifies that the tag version matches both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` before creating the release.

## Skill File Structure

Each skill lives at `skills/<skill-name>/SKILL.md` with YAML frontmatter:

```yaml
---
name: <skill-name>
description: >
  <Natural language description — also used for trigger-phrase matching>
disable-model-invocation: true   # Optional. Runs as a direct prompt without re-invoking the model
allowed-tools: Bash, Read, Glob, Grep   # Comma-separated. Restricts tool access.
argument-hint: "[draft] [base <branch>]"  # Shown to user on /help
---
```

**`allowed-tools` fine-grained restriction:** Bash can be scoped to specific subcommands, e.g., `Bash(gh pr view:*)` allows only `gh pr view ...` and blocks all other Bash commands.

The body of SKILL.md is the full prompt given to the model when the skill is invoked. Arguments passed by the user are available as `$ARGUMENTS`.

A skill may include additional reference files (e.g., `skills/<name>/references/`) for large static documents the prompt pulls in.

## Adding or Modifying a Skill

1. Create `skills/<skill-name>/SKILL.md` with the frontmatter above (new skill), or edit the existing `SKILL.md` (modification).
2. Write the prompt body in English, or match the target repo's language. See the Language convention below for what stays Japanese.
3. Use Conventional Commits so `make release` can infer the next SemVer:
   - Patch (`0.3.0` → `0.3.1`): fixing ambiguity or bugs in an existing skill body
   - Minor (`0.3.0` → `0.4.0`): adding a new skill or adding meaningful new capability to an existing one
   - Major (`0.3.0` → `1.0.0`): breaking changes to skill interfaces or removing skills
4. Run `claude plugin validate .` to confirm the manifest is still valid.
5. Open a PR — CI will validate and test installation automatically.

## Conventions

- **Language**: Skill bodies are written in English. Two things stay Japanese: trigger phrases in `description`, which are what users actually type, and user-facing output templates, which users actually read. Older skills still carry Japanese bodies; convert one only when you are already editing it for another reason.
- **`description` field**: This is pattern-matched against user requests to suggest the skill. Include common phrasings users would naturally say.
- **`disable-model-invocation: true`**: Use this when the skill should execute as a single-shot prompt without starting an agentic loop. `create-pr` uses this; the skill instructions themselves direct all tool calls.
- **Tool minimalism**: Declare only the tools a skill actually needs. Prefer scoped `Bash(cmd:*)` over bare `Bash` when the command set is small and predictable.

## Local Development Setup

Static analysis for shell scripts and GitHub Actions workflows runs automatically via pre-commit hooks.

```bash
# Install prek (once)
# https://github.com/j178/prek
brew install j178/tap/prek   # macOS

# Enable hooks (run from repo root)
prek install
```
