---
name: create-github-issues
description: >
  Create GitHub Issues from a conversation, plan, or TODO list.
  Produces one Epic parent Issue and child Issues per task, each with background, requirements, specs, dependency, and acceptance criteria, linked to the Epic as GitHub sub-issues with dependencies recorded as blocked-by/blocking relations.
  Requirements (what) and specs (how) are kept separate and length-capped so bodies stay concise, and the Epic also renders a Mermaid diagram (a compact table for large epics) showing which child Issues block each other and which can run in parallel.
  Issue titles, bodies, and every interactive prompt are written in the language that `lang <ja|en>` or git config `skills.lang` selects.
  Use this skill when the user asks to track tasks with an Epic, turn TODOs or a plan into GitHub Issues, or extract action items from a review or investigation.
allowed-tools: Bash(gh:*)
argument-hint: "[repo <owner/repo>] [lang <ja|en>] [project <n>]"
---

# create-github-issues

Create a GitHub Epic and child Issues from conversation context, with length-capped bodies, explicit dependencies, native `gh` hierarchy and dependency links, and a dependency graph in the Epic.

**Core rule for every step: an Issue body contains only source items and the additions the owner named in Step 3. Step 4 is formatting, not authoring — never introduce a new requirement, spec detail, or dependency while writing a body.** If a body needs something new, go back to Step 3 and get it approved there first.
Source is only the documents the owner named, the owner's own words, and Step 1.5 answers; your own analysis is not source unless the owner approved that item by name. Anything else, safety or correctness items included, is an addition, and an approval that names no addition includes none. An item the source defers or excludes appears only on the Epic's out-of-scope line, never in a Tn, not even as an exclusion.

Paths below are relative to this skill's directory. Read each reference file when its step says so.

## Step 0: Determine Output Language

Before anything else, run `bash <skills-root>/create-pr/scripts/lang.sh [<value after lang in $ARGUMENTS>]`, where `<skills-root>` is the parent of this skill's directory, and on a non-zero exit show its output and stop.
Otherwise show `Language: ` and its whole output line, such as `Language: en (git config)`, then write everything in this run in its first word, `LANG`, reading only `references/templates.<LANG>.md`.

## Step 1: Identify Repository

Use `repo <owner/repo>` from `$ARGUMENTS`, or else `gh repo view --json nameWithOwner -q .nameWithOwner`, and store it as `REPO`.
Store `project <number>` from `$ARGUMENTS`, if given, as `PROJECT_NUM`; Step 5 links to it after creation.

## Step 1.5: Specification Clarification

Judge whether the context is clear on each axis:

| Axis | Criterion |
|------|-----------|
| Granularity | Can each task be implemented and merged as an independent PR? |
| Acceptance criteria | Can completion be confirmed with numbered verification steps? |
| Specification | Are there implementation choices that could be interpreted more than one way, where the reading changes a requirement, a dependency, or a verification outcome? |
| Premise | Was every claim the plan rests on checked? A claim about how a tool, file, or system behaves, or about a count or usage, is unclear when the context gives no measurement, reproduction, source reference, or observed data for it |

Judge each axis on its own: a checked premise does not make any other axis clear.

- All clear: go to Step 2 without asking.
- Any unclear: read `references/question.md` in full, then ask with **AskUserQuestion** in the "Step 1.5: Clarification Question Format" of `references/templates.<LANG>.md`, one question per unclear item on the unclear axes only, in one call of up to 4 questions, in the order the template sets. **Stop after calling AskUserQuestion; do not proceed to Step 2 until the user responds.**
- The user says to proceed with items unresolved: output the "Step 1.5: Warning Format" and mark those sections with its confirmation tag.

Anything still unresolved is never decided later: it gets the confirmation tag or stays out of the Issue.

## Step 2: Structure Tasks and Dependencies

Read `references/structure.md` in full first, and follow it.
From the context, extract the Epic (title, purpose, scope) and child tasks `T1`, `T2`, ... with title, role, at most 5 requirement bullets and 5 spec bullets, and `depends_on` taken only from what the conversation stated or clearly implied. Compute waves by topological order. On a dependency cycle, ask with **AskUserQuestion** instead of breaking it.

## Step 3: Show Summary and Get Approval

Use the "Step 3: Summary Format" in `references/templates.<LANG>.md`. Per task, or once for tasks that differ only in one value as the template allows, show its `Tn` id, title, wave/dependency, one-line background, requirement bullets, spec bullets, one-line target state, the full verification list, and any point-option pointer; for the Epic, its background, scope, target state, and verification; and a dependency preview keyed by `Tn` — Mermaid for 12 or fewer tasks, the wave table for more, the same form Step 4 renders. When a doc-update `Tn` exists, state that the document is out of sync with the answers. Step 4.5 is skipped by default, so approving this summary must be equivalent to approving the final bodies.

**End your response here and wait for the user's reply. Do not proceed to Step 4 until approval is received.**
On requested changes, update the summary, including the graph and waves, and show it again.

## Step 4: Generate Issue Bodies

Read `references/bodies.md` in full first. Write the Epic and child bodies from the templates in `references/templates.<LANG>.md`, using only the content approved in Step 3, without adding, softening, or elaborating it.

## Step 4.5: Full Draft Review (only if requested)

Skip by default. Run only when the user explicitly asked to see the full draft (e.g. "ドラフト見せて", "本文を確認したい", "show me the draft"), in their Step 3 reply or earlier.
Then display the Epic and every child in the "Step 4.5: Body Review Format", noting that `{{Tn}}` tokens become real numbers (`#123`) after creation. **Stop after presenting; do not proceed to Step 4.6 until the user explicitly approves.** Apply requested changes and display again.

## Step 4.6: Automated Pre-Creation Validation

Always run every check in `references/bodies.md` § Pre-Creation Checks. If any check fails, stop, report the problem and its location to the user, and fix it before proceeding. Never silently patch it and never create Issues with a body known to be broken.

## Step 5: Create Issues

Follow `references/commands.md`, including its failure rules. Every command starts with `gh` to match `allowed-tools`; read its "Tool permission contract" before adding or changing one.

- Create the Epic first, then every `Tn` in wave order with `--parent <Epic>` and `--blocked-by` for created dependencies, then each container's `Tn.m` with `--parent <that Tn>` and `--blocked-by` limited to its siblings. Never pass a number that does not exist.
- Substitute bottom-up: each container's `{{Tn.m}}` first, then the Epic's `{{Tn}}`; a failed create becomes "creation failed", and a failed `Tn` gets no grandchildren.
- Verify the sub-issue and blocked-by relations against GitHub before Step 6, and stop on a mismatch.
- Only when `PROJECT_NUM` is set, run 5.7. Never map Wave numbers onto a `Stage` or `Wave` project field.

## Step 6: Report Completion

Use the "Step 6: Completion Report" template in `references/templates.<LANG>.md`, including failed creates, dropped edges, and the numbering order. When the doc-update `Tn`'s dependency was wired transitively rather than directly, say so explicitly — a later reader may otherwise "fix" the ordering by adding or removing edges.
