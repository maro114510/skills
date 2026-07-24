# Tessl PoC data boundary and stop conditions

Status: draft, pending explicit approval (see "Approval" below). Scope: this document only. No Tessl command has been run, and none should be run, until this policy is approved.

## Background

Tessl is not a local-only linter — cloud-backed reviews and evaluations can send skill content, prompts, generated scenarios, code snippets, file contents, and related metadata to Tessl and its model providers. Telemetry (`shareUsageData`) defaults to `true`. Without a written boundary, a first experiment could silently expand into private repositories or CI before its legal, privacy, and operational implications are understood. This document is that boundary.

## Allowed inputs (initial allowlist)

Only the following may be given to Tessl for review/evaluation during the PoC:

- `skills/skill-cleaner/SKILL.md`
- `skills/md-review/SKILL.md`
- Synthetic evaluation fixtures authored specifically for this PoC (to be written fresh, containing no real user data, no real credentials, and no content copied from any private source)

Both `SKILL.md` files above are public (this repository is public), small, and self-contained — neither references company-internal systems, personal data, or credentials. No other file, directory, or repository is in scope.

## Prohibited inputs

- Any private or employer-owned repository or file (e.g. `kauche-app` or any other work repository)
- Any content containing personal data
- Any content containing credentials, tokens, or secrets
- Any third-party-confidential content
- Git history of this or any repository — only working-tree snapshots of the allowlisted files above
- Any file not explicitly listed in "Allowed inputs"

If a Tessl prompt, CLI flow, or MCP integration would touch anything outside this list, that is a stop condition (see below), not a judgment call to make in the moment.

## Tessl configuration requirements

- **Telemetry**: `shareUsageData` must be set to `false` and verified before the first review or evaluation:
  ```bash
  tessl config set shareUsageData false
  tessl config get shareUsageData   # must print false
  ```
- **Do not run `tessl init`** — it writes a `tessl.json` manifest into the repo and auto-configures MCP integration for detected coding agents. Out of scope for this PoC.
- **Do not enable Tessl MCP** (e.g. `tessl mcp start` or agent auto-config).
- **Do not publish to the Tessl Registry.**
- **Do not process git history** — Tessl must only see the allowlisted files as given, not repository history.

## CLI version

- Before the first run, capture the exact installed CLI version (`tessl --version`, or `npm view @tessl/cli version` if installed via npm) and record it here. At policy-drafting time (2026-07-24) public sources disagreed on the latest published version (an npm search snippet showed `0.90.0`; the official changelog page showed `0.92.0`), so this must be re-verified directly rather than assumed:

  > CLI version used for this PoC: `<fill in before first run>`

- Disable silent automatic updates for the duration of the experiment:
  ```bash
  export TESSL_AUTO_UPDATE_INTERVAL_MINUTES=0
  ```
  (Tessl's CLI checks for updates every ~3 hours by default and applies them transparently on the next command invocation.)
- If the version drifts from the recorded value at any point during the experiment, treat it as a stop condition.

## Plan and budget

- **Plan**: Free tier (no paid subscription; no card required)
- **Credit budget**: 50 credits total for this PoC
- **Time budget**: 2 hours wall-clock, starting from the first Tessl invocation
- **Max runs**: 5 review/evaluation invocations

Any one of these limits being reached ends the PoC immediately, regardless of whether the other limits still have headroom.

## Success conditions

- At least one review/evaluation run completes successfully against an allowlisted file within the budget above.
- `shareUsageData` is confirmed `false` before and throughout the PoC.
- No input outside the allowlist is processed.
- No git history is processed.
- The recorded CLI version does not change during the PoC.

## Failure conditions

Any of the following means the PoC did not succeed (not "try again harder" — treat as a normal, expected outcome to report, then stop):

- Tessl output is unusable/incomprehensible within the budget.
- Achieving useful output would require inputs beyond the allowlist.
- Terms of service or plan limitations cannot be accepted as written.

## Stop conditions (immediate)

Stop immediately, without attempting a workaround, if any of the following occurs:

1. `shareUsageData` cannot be verified as `false` before or during a run.
2. The CLI version cannot be verified or pinned.
3. Any step would process a file or path not on the allowlist.
4. Any step would process git history.
5. Terms of service or plan limitations cannot be accepted.
6. The credit budget, time budget, or max-run count is reached.
7. There is any sign that data is leaving the declared telemetry-off + allowlist boundary (unexpected network destinations, unexpected file access prompts, unexpected write access to the repository, etc.).
8. Tessl's actual behavior for `tessl init` / MCP / Registry cannot be confirmed to match the descriptions in this document at the pinned CLI version.

## Decision owner and scope expansion

Only the repository owner (`maro114510`) may authorize expanding this PoC — widening the allowlist, raising the budget, moving to a paid plan, running `tessl init`, enabling Tessl MCP, publishing to the Registry, or processing git history — and only after reviewing this PoC's actual results.

## Approval

This policy must be explicitly approved before any compatibility or scenario evaluation work begins. Approval happens via review of the pull request that introduces this document.

## Cleanup / deletion procedure

After the PoC concludes, regardless of outcome:

1. Revoke or rotate any Tessl auth token created for this experiment.
2. Delete local Tessl config/cache created for this experiment, if feasible.
3. Confirm no `tessl.json`, MCP configuration, or other Tessl-managed file was left in the repository.
4. Record actual credits, time, and run count consumed (in this document or the closing issue comment) for future reference.

## References

- https://docs.tessl.io/reference/configuration
- https://docs.tessl.io/legal/sharing-usage-data
- https://docs.tessl.io/introduction-to-tessl/set-up-tessl/installation
- https://docs.tessl.io/reference/cli-commands
- https://docs.tessl.io/distribute/distributing-via-registry
- https://docs.tessl.io/changelog
- https://tessl.io/pricing/
