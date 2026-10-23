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
| `oe/` | Go source of the `oe` CLI used by orchestrate-epic |
| `.github/workflows/oe-release.yml` | Builds and publishes the `oe` binaries on an `oe-v*` tag push |
| `skills/orchestrate-epic/scripts/oe` | Wrapper that downloads, verifies, caches, and runs the pinned `oe` binary |
| `skills/orchestrate-epic/scripts/oe-manifest.tsv` | Pins the `oe` release by tag, source revision, and the sha256 of each asset |
| `bin/oe-manifest.sh` | Rewrites the manifest from a published `oe` release for `make oe-manifest` |

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

## oe Releases

`oe` ships as a prebuilt binary and no binary is committed.
`oe-v*` tags are separate from `v*` tags and never affect plugin releases or `make next-version`.

| Step | Actor | Action |
|---|---|---|
| 1 | Maintainer | Push an annotated `oe-vX.Y.Z` tag on `main` |
| 2 | `oe-release.yml` | Test, build the four binaries and `SHA256SUMS`, check `oe --version` equals the tag, publish the release |
| 3 | Maintainer | Run `make oe-manifest TAG=oe-vX.Y.Z` to rewrite the manifest locally. It never commits or pushes |
| 4 | Maintainer | Commit the manifest on a branch and open a PR |
| 5 | Reviewer | Merge the PR. Until then users keep the previous pin |

The wrapper `skills/orchestrate-epic/scripts/oe` checks the sha256 of the binary before every run.

| Case | Result |
|---|---|
| Cached binary matches the manifest | Runs, with no network |
| Cached binary does not match | Replaced from the release, or exit 1 when the download fails |
| Downloaded binary does not match | Refused with exit 8, never cached |
| Nothing pinned, or the manifest is unreadable | Refused with exit 8 |
| `gh` missing or the download fails | Exit 1 |

- The first run needs `gh` signed in, network access, and a writable `${XDG_CACHE_HOME:-$HOME/.cache}/oe`
- A sandboxed harness may need that first run approved
- A byte-identical rebuild check and build attestations are not done yet
- `cliff.toml` anchors `tag_pattern` as `^v[0-9]`, because the unanchored pattern also matched `oe-v1.0.0`

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
| `disable-model-invocation` | Optional; `true` only stops Claude from loading the skill automatically. It does not disable the agentic loop: the skill still runs through `/name` and calls its tools normally, as in `create-pr` |
| `allowed-tools` | Comma-separated; pre-approves the listed tools for the turn that invokes the skill. It does not restrict which tools are available, so unlisted tools stay governed by normal permissions and `Bash(gh pr view:*)` does not block other Bash commands; use `disallowed-tools` or deny rules to block |
| `argument-hint` | Shown on `/help` |

- The body is the full prompt; user arguments arrive as `$ARGUMENTS`
- Body language is English or the target repository's language
- Japanese stays only in `description` trigger phrases and user-facing output templates
- Convert an older Japanese body only when already editing it for another reason
- Declare only the tools a skill needs; prefer scoped `Bash(cmd:*)` when the command set is small and predictable
- This repository relies on the `PreToolUse` hook in `.claude/settings.json` to stop an unapproved `git push`; that stop is intended behavior

## Target Repository Config

Skill scripts read the target repository's `.agents/skills.toml`.
The `[paths]` section is neutral: no single skill owns it, and every key holds Git glob pathspecs as a string or an array.
Every other section is named after the skill that reads it.

| Key | Holds | Read by |
|---|---|---|
| `[paths] tests` | Test files | `skills/implement/scripts/gate-tests.sh`, `skills/commit/scripts/classify-approval.sh` |
| `[paths] generated` | Generated files | - |
| `[paths] design_docs` | Design docs and ADRs | - |
| `[implement.testing]` | gate-tests's commands and patterns, listed in its header | `skills/implement/scripts/gate-tests.sh` |
| `[commit.approval] paths` | Paths whose change needs approval, added to the built-in conditions, which no key can remove | `skills/commit/scripts/classify-approval.sh` |

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
