---
name: create-github-issues
description: >
  Create GitHub Issues from a conversation, plan, or TODO list.
  Produces one Epic parent Issue and child Issues per task, each with background, requirements, specs, dependency, and acceptance criteria, linked to the Epic as native GitHub sub-issues (`gh issue create --parent`) with dependencies recorded as native blocked-by/blocking relations.
  Requirements (what) and specs (how) are kept separate and length-capped so bodies stay concise, and the Epic also renders a Mermaid diagram (a compact table for large epics) showing which child Issues block each other and which can run in parallel.
  Issue titles, bodies, and every interactive prompt are written in Japanese by default; pass `lang en` to generate the whole run in English instead.
  Requires GitHub CLI v2.94.0 or later.
  Use this skill when the user asks to track tasks with an Epic, turn TODOs or a plan into GitHub Issues, or extract action items from a review or investigation.
allowed-tools: Bash(gh:*), Bash(git remote get-url:*)
argument-hint: "[repo <owner/repo>] [lang <ja|en>]"
---

# create-github-issues

Create a GitHub Epic and child Issues from conversation context.
Write concise, length-capped bodies (requirements separated from specs), model dependencies explicitly, then link hierarchy and dependencies via native `gh` CLI flags and render the dependency graph in the Epic.

**Core rule that governs every step below: an Issue body may only contain facts already surfaced and approved earlier in this flow (Step 1.5 / Step 2 / Step 3). Step 4 is formatting, not authoring — never introduce a new requirement, spec detail, or dependency for the first time while writing the final Markdown body.** If you notice you need to state something new while writing a body, stop, go back to Step 3, and get it approved there first.

---

## Step 1: Preflight and Identify Repository

### Preflight: gh CLI version

This skill relies on the `--parent`, `--blocked-by`, and `--blocking` flags added to `gh issue create`/`gh issue edit` in GitHub CLI v2.94.0. Run `gh --version` and check the reported version.

**If it is lower than 2.94.0**, stop immediately and tell the user:

> This skill requires GitHub CLI v2.94.0 or later (native sub-issue and dependency flags). Your installed version is `<version>`. Please upgrade `gh` (e.g. `brew upgrade gh`, or `mise upgrade gh` if `gh` is mise-managed) and re-run this skill.

Do not proceed to repository identification or any later step until the version requirement is met.

### Identify Repository

Check `$ARGUMENTS`:

- If `repo <owner/repo>` is provided, use that repository.
- Otherwise, auto-detect from the remote URL:

```bash
git remote get-url origin
```

Extract `owner/repo` from `https://github.com/owner/repo.git` or `git@github.com:owner/repo.git` and store it as `REPO`.

---

## Step 1a: Determine Output Language

Check `$ARGUMENTS` for `lang <ja|en>` and store it as `LANG`; default to `ja` if omitted (preserves existing behavior).

`LANG` is fixed for the rest of this run and governs everything produced from here on — AskUserQuestion prompts, summaries, reviews, warnings, Issue/Epic titles, and Issue/Epic bodies. From Step 1.5 through Step 6, read only `references/templates.<LANG>.md` — never the other language's file, and never switch languages mid-run.

---

## Step 1.5: Specification Clarification

Scan the conversation context across three axes and determine whether enough information is available to write high-quality Issues.

### Evaluation Axes

| Axis | Criterion |
|------|-----------|
| Granularity | Can each task be implemented and merged as an independent PR? |
| Acceptance criteria | Can completion be confirmed with numbered verification steps? |
| Specification | Are there implementation choices that could be interpreted more than one way? |

### Decision Branches

**All axes are clear:**
Skip to Step 2. Do not ask any questions.

**One or more axes are unclear:**
Use **AskUserQuestion** to surface the ambiguities, following the "Step 1.5: Clarification Question Format" template in `references/templates.<LANG>.md` — use only the labeled subsection(s) for the axis/axes actually unclear, not all three unconditionally. For each unclear item, present specific answer choices (e.g., "(A) include JWT refresh in the same Issue / (B) split into a separate Issue"). Batch all unclear items into a single AskUserQuestion call (up to 4 questions); if more than 4 items are unclear, prioritize the ones with the highest impact on Issue scope.

**Stop after calling AskUserQuestion. Do not proceed to Step 2 until the user has responded.**

**User instructs to proceed with unresolved items:**
Output the warning using the "Step 1.5: Warning Format" template in `references/templates.<LANG>.md`, then proceed to Step 2.
Mark unresolved sections in Issue bodies with the confirmation tag defined in that template.

Anything that stays unresolved after this step must **not** be silently decided later. Either it gets the confirmation tag, or it gets left out of the Issue entirely — never invented.

---

## Step 2: Structure Tasks and Dependencies

Analyze the current conversation context (recent plans, investigations, TODO lists) and extract:

**Epic (parent Issue)**
- Title: one phrase that captures the entire work stream
- Purpose: why this work is needed (background, motivation)
- Scope: what is included in this Epic

**Child Issue list**
- **Hierarchy is exactly two levels, always: Epic → `Tn`. A `Tn` is never itself a parent of another `Tn`.** If a task needs more decomposition than the cap below allows, split it into additional sibling `Tn` under the same Epic — never nest one `Tn` under another. This is a hard rule, not a default: do not create a third level under any circumstances, even if a task feels like a natural "sub-epic".
- Split each task into independently implementable and verifiable units
- Assign each a short temporary ID: `T1`, `T2`, `T3`, ... (used only during this conversation; never shown to the end reader)
- Title and a one-line summary of each task's role in the Epic
- For each task, capture its **requirement bullets** (what must be true — observable/functional, no implementation detail) and its **spec bullets** (only if the conversation already settled concrete technical decisions). Cap each list at 5, one line each.
- **The cap is a split signal, not a compression target.** If a task genuinely needs more than 5 bullets to describe — or, as shown at Step 4, more than 5 distinct verification scenarios (one happy path plus several failure/retry/rollback cases is a common trigger) — that is evidence the task is doing too much for one child Issue. Split it into more `Tn` (e.g. "happy path" vs "error handling / compensating recovery") rather than cramming everything into one Issue or silently dropping items to fit the cap.
- Never write step-by-step procedures (`a→b→c→d`), pseudocode, or function-level implementation detail into these bullets. That level of detail belongs in a design doc, not an Issue body — reference it by path instead.

**Dependency extraction**
- For each `Tn`, list `depends_on: [Tm, ...]` based only on dependencies explicitly stated or clearly implied in the conversation (e.g., "merge A before starting B"). Do not infer a dependency that wasn't actually discussed. A statement that a task is merely independent of unrelated *existing* code (not another `Tn`) is not a `depends_on` entry — leave it out of the dependency list entirely; it's background/requirement framing at most.
- Compute **waves** by topological order: Wave 1 = tasks with no dependencies; Wave *k* = tasks whose dependencies all fall in Wave 1..*k-1*. Tasks in the same wave can be implemented in parallel.
- If a cycle is detected, treat it as an unresolved ambiguity and raise it via **AskUserQuestion** before continuing — do not silently break the cycle.
- **If splitting a task per the cap rule above, and another `Tn` already depends on the task being split, re-wire that dependency**: point it at whichever new piece represents the completion of the original scope (usually the last piece in the split's natural sequence). If it's genuinely ambiguous which piece satisfies the original dependency, depend on all of the resulting pieces rather than guessing one.
- A dependency **between the new pieces created by a split** (e.g., "error handling" depends on the "happy path" it wraps) may be inferred from the decomposition itself — this is not the kind of invented dependency the "do not infer" rule above is guarding against, since the pieces didn't exist as separate units in the conversation to begin with.
- **The 12-task threshold above governs rendering only (Mermaid vs. table) — it says nothing about whether one Epic is still the right unit of work.** Separately: if the dependency graph splits into two or more fully independent connected components (no `depends_on` edge between them in either direction) and the total child count is large (rule of thumb: 15+), that's a sign the work may belong in separate Epics — one per component — rather than one Epic covering several unrelated parallel tracks. Don't decide this yourself: note it as a suggestion in the Step 3 summary (see template) and let the user choose.

---

## Step 3: Show Summary and Get Approval

Use the "Step 3: Summary Format" in `references/templates.<LANG>.md`. This preview must show, per task: its `Tn` id, title, wave/dependency, requirement bullets, spec bullets, and one-line acceptance criterion — plus a dependency preview keyed by `Tn` (real Issue numbers don't exist yet). **Apply the same 12-task threshold as the Epic body here**: a Mermaid flowchart for 12 or fewer tasks, the compact wave table for more — the user is approving the same structure that Step 4 will render, so the two must never diverge in form.

This preview is allowed to be more detailed than the final Issue bodies — its job is to surface every piece of content that will end up in an Issue, so nothing new gets invented in Step 4.

**End your response here and wait for the user's reply.**
**Do not proceed to Step 4 until approval is received.**
If the user requests changes, update the summary (including the dependency graph and wave assignment if affected) and show it again before proceeding.

---

## Step 4: Generate Issue Bodies

After approval, write the Markdown body for the Epic and each child Issue using the templates in `references/templates.<LANG>.md`. Use only content already approved in Step 3 — do not add, soften, or elaborate on requirements/specs while formatting.

**Child Issues:**
- Requirements section: the approved requirement bullets, verbatim in substance (may be copy-edited for clarity, not expanded).
- Specs section: the approved spec bullets. Omit this section entirely if no technical decision was actually settled in the conversation — do not fill it with invented detail.
- Dependencies section: one line referencing the `Tn` it depends on, or the template's "none" phrasing — don't say "diagram" or "table" specifically, since which one the Epic uses depends on the 12-issue threshold. Do not restate the full dependency chain here — that lives only in the Epic.
- Acceptance Criteria section: concrete, verifiable statements equivalent to "Given X, When Y, Then Z" — not vague phrases like "works correctly". Cap the Verification subsection at 5 items. If the real scenarios don't fit in 5, do not compress them — stop, go back to Step 2 to split this task into more `Tn`, and re-run Step 3 approval before writing bodies again.

**Epic:**
- Dependencies & Parallel Execution Plan section: a Mermaid `flowchart` grouping child Issues into `subgraph` blocks per wave, using `{{Tn}}` tokens (double curly braces) everywhere a real Issue number will later be substituted — both in node labels and in any prose. **If there are more than 12 child Issues, replace the flowchart with the compact wave table** in `references/templates.<LANG>.md` instead — a graph that large stops being readable.
  - **Escaping in node labels:** if a title contains a double quote, write it as the entity code `#quot;` inside the `["..."]` label — never a raw `"` (it terminates the label) and never a backslash-escaped `\"` (Mermaid does not support backslash escaping and the diagram fails to render). Same rule applies to the Step 3 dependency preview.
- This diagram is a rendering of the same `depends_on`/wave data that Step 5 also uses to set native GitHub blocked-by/blocking relations on each child Issue. Both are generated once, from the same approved data, in the same run — the diagram is a human-readable view, not a hand-maintained duplicate that can drift from the real relations after creation.

Do not use `{{Tn}}` tokens in child Issue bodies — child Issues stay abstract (`T1`, not `{{T1}}`) and are never rewritten after creation; only the Epic body gets the substitution pass in Step 5.

---

## Step 4.5: Issue Body Review

After generating all Issue bodies, present the full text to the user before creating anything.

Use the "Step 4.5: Body Review Format" template in `references/templates.<LANG>.md` to display the Epic and all child Issues in order. Note explicitly that `{{Tn}}` tokens in the Epic body are placeholders that will be replaced with real Issue numbers (`#123`) once the child Issues exist.

**Stop after presenting. Do not proceed to Step 5 until the user explicitly approves.**

If the user requests changes, apply them and re-display the updated bodies before proceeding.

---

## Step 5: Create Issues

See `references/commands.md` for the exact shell commands.

**The Epic is created first.** Native sub-issue linking (`gh issue create --parent`) requires the parent to already exist, and creating children in wave order lets each one declare its `--blocked-by` relations inline using real numbers that already exist from earlier waves — no separate linking pass needed.

1. Create the Epic using the Step 4-approved body verbatim, `{{Tn}}` placeholders included. Capture its Issue number as `EPIC_NUM`.
2. Create child Issues **in wave order** (Wave 1 first, ascending, same order as Step 2's topological sort). For each `Tn`:
   - Pass `--parent $EPIC_NUM` — this attaches it as a sub-issue of the Epic. **Never** pass `--parent` pointing at another child Issue; every `Tn`'s parent is the Epic, and only the Epic (see the hierarchy rule in Step 2).
   - If `Tn` has `depends_on` entries, pass `--blocked-by <numbers>` (comma-separated) using the already-captured real numbers of those `Tm` — they are guaranteed to already exist because a dependency always falls in an earlier wave than the task that depends on it.
   - If creation fails for a `Tn`, print the error and continue with the remaining child Issues — don't abort the whole run, but do flag the failure in the Step 6 completion report so the user knows which relation is missing.
   - Capture the resulting Issue number against its `Tn` id.
3. Build the final Epic body by replacing every `{{Tn}}` token in the Step 4-approved Epic body with the real `#<number>` now on hand, then update the Epic with `gh issue edit $EPIC_NUM --body ...`. This is a pure mechanical substitution — the structure was already approved in Step 4.5, so do not alter wording beyond the token swap.

Note for the user in the completion report (Step 6) that the Epic's Issue number will be **lower** than its children's, since it's created first.

---

## Step 6: Report Completion

Use the "Step 6: Completion Report" template in `references/templates.<LANG>.md`.
