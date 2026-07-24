# Tessl PoC (#83) results

Ran per the data boundary in `docs/tessl-poc-policy.md` (#82, approved). No optimization suggestions were auto-applied (`--optimize` / `-y` were never passed).

## Scope actually used

The skill set named in #83 (`ja-style-check`, `tdd-test-cases`, `pr-review-pe`) is not on the #82 allowlist. Rather than expand the allowlist before any result existed to justify it (which the policy itself disallows), this run was rescoped to the already-approved allowlist:

- `skills/skill-cleaner/SKILL.md`
- `skills/md-review/SKILL.md`

## Environment

- CLI: `@tessl/cli@0.92.0`, pinned via `npx @tessl/cli@0.92.0` on every invocation (never resolved via floating `latest`).
- `shareUsageData`: confirmed `false` via `tessl config get shareUsageData` before the first review.
- Auth: interactive `tessl login` (browser + device code), performed by the repo owner, not by the agent.
- Budget used: 4 of 5 allowed review invocations; 0 of 2 hours consumed beyond a few minutes; lint invocations were not counted against the review budget (see below — they never reached the server-side reviewer).

### Observation: silent ToS acceptance on first run

The very first CLI invocation (`--version`) wrote `~/.tessl/preferences.json` with `termsAcceptedAt` already populated and generated a persistent `anonymous-id` file — before any explicit prompt was shown and before `shareUsageData` was set to `false`. Continuing was a deliberate call (this is common first-run CLI behavior, not unique to this PoC's data-sharing concern), but it means ToS acceptance itself was never a reviewable, explicit step — worth knowing if this is repeated for a wider rollout.

## `tessl skill lint`

Fails unconditionally on this repo's structure:

```
✘ Not a Tessl plugin: no .tessl-plugin/plugin.json or tile.json found in the package root.
```

Tried against the `SKILL.md` file, the skill's directory, and the repo root — same error every time. `tessl skill lint` requires a Tessl plugin manifest (`.tessl-plugin/plugin.json` or `tile.json`). Creating one would mean migrating into a new source-of-truth layout, which #83 explicitly rules out. **`skill lint` is not usable against this repo's existing structure without violating that constraint.** This is the single biggest compatibility finding.

## `tessl skill review`

Runs directly against a bare `SKILL.md` path with no manifest required. Ran twice each on `skill-cleaner` and `md-review` (4 runs total, JSON output).

| Skill | reviewScore (run 1 / run 2) | warnings | descriptionJudge (run 1 / run 2) | contentJudge (run 1 / run 2) |
|---|---|---|---|---|
| skill-cleaner | 87 / 87 | `allowed_tools_field`, `frontmatter_unknown_keys` | 4.5 / 4.5 | 4.45 / 4.45 |
| md-review (Japanese-only body) | 85 / 85 | `frontmatter_unknown_keys` | 4.65 / 4.65 | 4.0 / 4.0 |

Both repeats were byte-identical to their first run — same scores, same warnings, same suggestion text verbatim. No material variance was exposed with 2 repeats each; results were fully stable. (Caveat: this could reflect genuine determinism or response caching keyed on file content — the CLI gives no way to distinguish the two, so this isn't a strong claim about the underlying model's variance, only that repeated CLI invocations on unchanged input return unchanged output.)

The Japanese-only `md-review` description/body was evaluated coherently — the judge's English-language reasoning correctly parsed and reasoned about the Japanese trigger phrases and body content. No sign of degraded evaluation from Japanese input.

## Finding-by-finding adjudication

| Finding | Classification | Notes |
|---|---|---|
| `skill lint` requires a plugin manifest | **Tessl incompatibility** | Blocks the deterministic-lint half of #83 entirely under the "no new source-of-truth layout" constraint. |
| `allowed_tools_field` warning garbles `Bash(find:*, wc:*, git status:*, git diff:*, git checkout:*)` into fragments like `"Bash(find:*,"`, `"wc:*,"` | **Incorrect finding / Tessl incompatibility** | Tessl's parser doesn't understand Claude Code's `Bash(subcommand:*)` scoping syntax and splits naively on commas. Not a real defect in the skill. |
| `frontmatter_unknown_keys` flags `argument-hint` | **Tessl incompatibility** | `argument-hint` is a documented Claude Code convention (see this repo's `CLAUDE.md`), used across the whole plugin. Not a defect. |
| `skill_md_line_count` (≤500 lines) | **Duplicate of existing capability, looser** | `skill-cleaner` already targets verbosity, but at a stricter/more semantic level (trim ceremonial content, ~60-token description heuristic) rather than a raw 500-line ceiling. Both passed trivially here — not informative for skills already under `skill-cleaner`'s discipline. |
| `reviewScore` (87 / 85) | **Non-duplicate, new capability** | `skill-cleaner` has no numeric quality score; this is new information, though its practical meaning (does a higher score improve real invocation behavior?) is unverified — a score is not proof of runtime effectiveness. |
| `descriptionJudge` / `contentJudge` rubric scores + suggestions | **Subjective suggestion** | E.g. "add English synonyms," "add a concrete before/after example." The before/after-example suggestion for `skill-cleaner` is in mild tension with `skill-cleaner`'s own stated goal of removing ceremonial content — a stylistic opinion, not a defect, and one an operator should weigh against this repo's own conventions rather than apply automatically. |
| Duplicate-`name:` detection across a directory | **Not covered by Tessl at all** | `skill-cleaner` explicitly checks for `name:` collisions across a directory of skills; `tessl skill review` only evaluates one file at a time and surfaced no equivalent check. |

## Comparison to `skill-cleaner`

No overlap in mechanism: `skill-cleaner` is a diff-producing editor (trim verbosity, preserve triggers/constraints, human-approved edits, directory-wide duplicate-name detection). Tessl's `skill review` is a read-only scorer (frontmatter schema validation + two LLM rubric judges). The only conceptual overlap is "is this skill appropriately sized/does its description trigger well," and even there the specific checks differ enough that neither tool's output substitutes for the other's. Tessl surfaces frontmatter-schema issues `skill-cleaner` doesn't check at all (valid schema, unknown keys); `skill-cleaner` surfaces a directory-wide duplicate-name check Tessl doesn't do.

## Desired-state verdict

- No source files were rewritten (only `skill review`, never with `--optimize`/`-y`).
- Reviewable evidence of compatible vs. incompatible vs. duplicate findings exists above.
- No claim is made that a `reviewScore` proves runtime effectiveness — score is a static-content heuristic, not a behavioral test result.
- **Not failed**: Claude-specific metadata (`allowed-tools`, `argument-hint`) was preserved throughout (never modified), and Japanese-only content evaluated coherently and stably — the metadata-preservation and Japanese-instability failure conditions in #83 were not triggered. The `skill lint` / plugin-manifest incompatibility is a real limitation, but it is a compatibility finding to report, not a reason to fail this issue.

## Open item carried over from scoping

`ja-style-check`, `tdd-test-cases`, and `pr-review-pe` were never tested — only `skill-cleaner` and `md-review` were, per the allowlist actually approved. If Tessl compatibility on that broader set is still wanted, `docs/tessl-poc-policy.md`'s allowlist needs its own reviewed amendment first, informed by these results.
