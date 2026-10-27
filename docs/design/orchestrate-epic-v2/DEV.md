# Running the v2 candidate

This is the development entry point of the orchestrate-epic v2 candidate in `candidate/`. The candidate is not a skill, so no harness discovers it: you tell a harness to read its router. It is for development and for the trials of #293 only. The live skill stays on v1 until the cutover.

## Before you start

1. Build `oe` from source. No `oe-v*` release exists yet, so the wrapper in `skills/orchestrate-epic/scripts/oe` pins nothing and refuses to run. From this repository:

   ```text
   make -C oe build
   ```

   The binary is `oe/oe`. Use its absolute path. A path with a space is fine, as long as the harness quotes it.
2. Pick the skills root, the `skills/` directory of this repository. The implement skill is `<skills root>/implement/SKILL.md` and the create-pr scripts are `<skills root>/create-pr/scripts`.
3. Open the harness in the checkout of the repository the Epic belongs to, so that the current directory is the shared checkout. The origin of that checkout is the repository `oe` works on.

## The prompt

The same prompt works on every harness. Fill in the absolute paths:

```text
Read <this repository>/docs/design/orchestrate-epic-v2/candidate/router.md and follow it. epic <N>. oe is <OE>. The implement skill is <SKILLS_ROOT>/implement/SKILL.md. The create-pr scripts are <SKILLS_ROOT>/create-pr/scripts. The shared checkout is the current directory.
```

The router spawns its agents from the files in `candidate/agents/`, because nothing deploys them.

## Per harness

| Harness | Run | Notes |
|---|---|---|
| Claude Code | `claude` interactively, or `claude -p "<prompt>"` | Allowlist commands as the next section says |
| Codex | `codex exec --sandbox workspace-write -c 'sandbox_workspace_write.network_access=true' -c 'sandbox_workspace_write.writable_roots=["<HOME>/.local/state/oe","<HOME>/.cache/oe","<MAIN CHECKOUT>-wt"]' "<prompt>"` | Needs the three settings below, and the cache root once a release exists |
| OpenCode | `opencode run "<prompt>"` | None |

Every harness runs each command in a shell of its own, so a variable set in one call is gone in the next. Write literal values, and quote any path that holds a space or a quote character.

Codex runs every command as `/bin/zsh -lc '<command>'`. Its `workspace-write` sandbox blocks three things `oe` needs, and each setting above lifts one:

- The network, which `gh` needs: `network_access=true`.
- `<HOME>/.local/state/oe`, where `oe` keeps its lock and its session file. Without it every coordination command fails to take the Epic lock.
- `<MAIN CHECKOUT>-wt`, the directory beside the shared checkout where `oe worker worktree` creates every worktree.

`<HOME>/.cache/oe` is where the pinned wrapper caches its download. A source-built `oe` never uses it, so it is needed only once a release exists.

## The pid of the lease

`oe lease acquire --pid "$PPID"` records the process that holds the lease, so that a second Publisher on the same host can tell whether it is still alive. `$PPID` must stay alive for the whole session. Checked on 2026-10-27, from two separate tool calls of one session each:

| Harness | `$PPID` | Alive between the calls |
|---|---|---|
| Claude Code 2.1.311 | The `claude` process | Yes |
| OpenCode 1.19.4 | The `opencode` process | Yes |
| Codex 0.164.0 | One stable pid; its sandbox hides what it is, and blocks `ps` and `kill` | The same pid in both calls. `oe` counts a pid it may not signal as alive |

## Smoke check

On 2026-10-27, from the checkout of this repository, with `oe` copied to `/tmp/oe dev/oe`, each harness ran this one command, quoted as written, and printed `oe`'s payload:

```text
"/tmp/oe dev/oe" --epic 277 --repo maro114510/skills resolve
```

| Harness | Result |
|---|---|
| Claude Code 2.1.311, `claude -p` with `--allowedTools Bash` | The payload, with the quoting kept |
| Codex 0.164.0, with the three settings above | The payload, with the quoting kept. Under `read-only`, `network_access` off, or without the two writable roots, `oe` cannot work |
| OpenCode 1.19.4, `opencode run` | The payload, with the quoting kept |

The payload on each was `{"repo":"maro114510/skills","epic":277,"me":"maro114510","default_branch":"main","max_parallel":3,"max_parallel_reason":"","gh_version":"2.102.0"}`. Only read-only commands were run. Nothing here ran the loop, and a loop on Codex or OpenCode is not checked.

## Claude Code permissions

Every `oe` subcommand is one of three kinds:

| Kind | Subcommands | Allowlist |
|---|---|---|
| Read-only | `version`, `resolve`, `board`, `health`, `readiness`, `checks derive`, `scan outgoing`, `scan text` | Yes, as `Bash(<OE> board:*)` and so on |
| Writes for the loop: Epic and Issue comments, the lease, a local session file, a worktree, and the integration merge commit | `lease`, `gate`, `note post`, `ledger`, `state`, `worker`, `review`, `round`, `land repair`, and `checks run`, which also runs the repository's CI commands | Only for a run you leave unattended on a repository you trust |
| Irreversible: a push, a pull request, a merge | `ship publish`, `land merge` | Never |

Never allowlist the irreversible kind. `.claude/hooks/require-user-approval.sh` blocks both, direct or through the wrapper, unless the same line ends with `# user-approved`, and the router never adds that marker itself. The hook belongs to this repository's `.claude/settings.json`. A target repository has no hook, and neither Codex nor OpenCode has an equivalent here. Without it, a push and a merge are guarded only by `oe`'s own gates, the `epic-approve` and `epic-auto-merge` comments, and by the approval setting of the harness.

Workers run the repository's own test and build commands. Allowlist those, or run the loop in a permission mode that covers them, so that a worker does not stall on an approval prompt in the middle of a parallel batch.
