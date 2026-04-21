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

Both must be kept in sync when releasing a new version.

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
2. Write the prompt body in Japanese (this repo's convention) or match the target repo's language.
3. **Bump the version in `plugin.json`** — `claude plugin update` uses the version number to detect changes, so subscribers will not receive updates without a bump. Use semver:
   - Patch (`0.3.0` → `0.3.1`): fixing ambiguity or bugs in an existing skill body
   - Minor (`0.3.0` → `0.4.0`): adding a new skill or adding meaningful new capability to an existing one
   - Major (`0.3.0` → `1.0.0`): breaking changes to skill interfaces or removing skills
4. Run `claude plugin validate .` to confirm the manifest is still valid.
5. Open a PR — CI will validate and test installation automatically.

## Conventions

- **Language**: Skill bodies are written in Japanese. Skill descriptions may include Japanese trigger phrases to improve natural-language matching.
- **`description` field**: This is pattern-matched against user requests to suggest the skill. Include common phrasings users would naturally say.
- **`disable-model-invocation: true`**: Use this when the skill should execute as a single-shot prompt without starting an agentic loop. `create-pr` uses this; the skill instructions themselves direct all tool calls.
- **Tool minimalism**: Declare only the tools a skill actually needs. Prefer scoped `Bash(cmd:*)` over bare `Bash` when the command set is small and predictable.
