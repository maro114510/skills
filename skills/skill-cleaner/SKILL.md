---
name: skill-cleaner
description: >
  Audit and slim Claude Code skills: detect duplicates, bloated descriptions, oversized bodies.
  「スキルを軽くして」「説明を短くして」でも起動。
allowed-tools: Bash(find:*, wc:*, awk:*, sort:*, git:*), Read, Glob, Edit, Agent
argument-hint: "<skills-dir>"
---

# skill-cleaner

Audit a Claude Code skills directory and reduce context budget without breaking trigger accuracy.

**Purpose**: Detect oversized descriptions, bloated bodies, and duplicate skill names. Auto-compress descriptions; surface body slimming hints for human review.

## Step 0 — Argument guard

If `$ARGUMENTS` is empty, skip all processing and display:

```text
Usage: /skill-cleaner <skills-dir>

Examples:
  /skill-cleaner ./skills
  /skill-cleaner ~/.claude/plugins/cache/my-plugin/unknown/skills
  /skill-cleaner ~/.claude/plugins/cache
```

## Step 1 — Scan

```bash
find "$ARGUMENTS" -name "SKILL.md" | sort
```

If no files are found, display "No SKILL.md files found." and exit.

Read each SKILL.md and extract from the frontmatter (first `---` pair only):
- `name` — skill name (fall back to parent directory name if absent)
- `description` — description text (join multi-line folded-block `>` into one string)
- `allowed-tools` — record for reference only

**Frontmatter extraction rules**:
- Scope: only inside the first `---` pair at the top of the file; ignore any `---` in the body
- folded-block (`>`) / literal-block (`|`): replace newlines with a single space, then trim leading/trailing whitespace
- Example: `"line1\n  line2"` → `"line1 line2"`

Measure byte counts:
```bash
wc -c < "path/to/SKILL.md"              # whole file
echo -n "description string" | wc -c    # description only (pass trimmed string)
```

Token estimate (conservative, handles Japanese/English mix):
```text
desc_tokens = ceil(desc_bytes / 3)
body_tokens = ceil((file_bytes - desc_bytes) / 3)
```

## Step 2 — Budget report

Output the following Markdown table:

```text
## Skill Budget Report — <skills-dir>

| Skill | Path (relative) | desc tokens | body tokens | Flags |
|-------|----------------|-------------|-------------|-------|
| pr-review-pe | pr-review-pe | 87 | 1,240 | [!] desc >60 |
| create-pr    | create-pr    | 45 |   380 | —            |

**Always-on context cost**: NNN tokens (sum of all descriptions)
**Largest body**: skill-name (NNN tokens, loaded only on trigger)
```

Path column: relative to `$ARGUMENTS` (strip the `$ARGUMENTS/` prefix from `find` output).

Flag criteria:
- `[!] desc >60` — description exceeds 60 tokens (always loaded into context)
- `[!] body >800` — body exceeds 800 tokens (loaded only on trigger; for reference)
- `[dup] <other-path>` — same `name:` value exists in another file

Duplicate detection: compare all collected `name:` values; flag every instance when two or more share the same name.

## Step 3 — Proposals

### 3a — Description compression

For each skill flagged `[!] desc >60`, draft a compressed description.

**Compression rules** (skip compression if these cannot be satisfied):
1. Keep trigger nouns and verbs — words the user would naturally say to invoke this skill
2. Drop anything already implied by `argument-hint`, the body, or the skill name
3. Target ≤ 60 tokens (≈ 180 bytes Japanese / 240 bytes English)

**Examples**:
- Skill named `create-pr` → no need to say "creates a PR" in the description
- `argument-hint: "<pr-number>"` present → drop "pass a PR number as argument"
- Keep trigger phrases like "code review" that users would naturally say

Show each proposal in before/after format. Estimate token count with the same `ceil(bytes/3)` formula and include it in the header:

```text
### pr-review-pe — description (87 → 42 tokens)

**Before (87 tokens):**
Code diff PR (Layer-1) dedicated Principal Engineer perspective review skill. ...

**Proposal (42 tokens):**
PE-perspective review for code diff PRs. Checks 7 dimensions including correctness,
architecture, and security + AI-specific risks. Use /pr-doc-review-pe for Markdown-only PRs.
```

If no 3a proposals exist, display that in one line and continue to 3b.

### 3b — Body slimming hints

For each skill flagged `[!] body >800`, Read the body and list removable sections (**display only — no auto-edit**):

1. **Duplicate rules**: same constraint or warning repeated across multiple steps?
2. **Obvious steps**: re-explaining default CLI behavior that needs no instruction?
3. **Excessive examples**: more than 2–3 samples where one would suffice?
4. **Mergeable steps**: adjacent short steps that could be combined?

Display hints in this format:

```text
### pr-review-pe — body slimming hints (1,240 tokens)

- L45–L52: Same error-handling block duplicated in Step 2 and Step 4. Remove Step 2 copy.
- L80–L95: 16-line explanation of default gh behavior. Can be summarized in 1–2 lines.
```

If no 3b hints exist, display that in one line.

If neither 3a nor 3b has any proposals, display "Nothing to do — all descriptions ≤ 60 tokens and all bodies ≤ 800 tokens." and exit.

### 3c — Trigger accuracy eval

For each description proposal from 3a, dispatch a **fresh subagent** via Agent to verify the compression does not degrade trigger accuracy. Run all proposals in parallel (one Agent call per proposal in a single message).

Subagent prompt template:

```text
You are a blank-slate evaluator. Do NOT invoke any tools or skills.

Skill name: <name>

Original description:
<original>

Proposed description:
<proposal>

Requirements checklist:
1. [critical] All trigger nouns/verbs from the original are present or clearly inferable in the proposal
2. [critical] The proposal does not attract unrelated user requests (no false-positive risk)
3. The proposal is more concise than the original without losing meaning

For each requirement: ○ (fully satisfied) / partial / × (not satisfied), with a one-line reason.
Then list any trigger concepts from the original that are absent from the proposal (if any).
```

**Labeling**: based on the subagent's return:
- Both [critical] ○ → `[eval: PASS]`
- Any [critical] partial or × → `[eval: RISKY: <one-line reason>]`

If the Agent tool is unavailable, label all proposals `[eval: skipped]` and continue.

## Step 4 — Apply

### Pre-check

Before editing, confirm the working tree is clean:

```bash
git status --short
```

If not clean, report to the user and stop.

### Confirm and edit

Ask individually for each proposed skill:

```text
Update description for <skill-name>? [eval: PASS] (y/n/skip-all):
Update description for <skill-name>? [eval: RISKY: "code review" trigger absent] (y/n/skip-all):
Update description for <skill-name>? [eval: skipped] (y/n/skip-all):
```

- `y`: update the `description:` field with the Edit tool
- `n`: skip this skill
- `skip-all`: skip all remaining skills and exit

For approved skills only, update `description:` in the SKILL.md frontmatter with the Edit tool.
- Do not touch body, `allowed-tools`, or any other frontmatter fields
- Preserve the original YAML style (keep `description: >` if that was the original)
- One Edit call per skill

### Recovery on failure

If an Edit call fails (YAML corruption, write error), stop immediately and display:

```text
Updated: <list of completed files>
Failed:  <failed file>
Recover: git checkout HEAD -- <list of modified files>
```

### Completion summary

After applying:

```text
Done: N skill(s) updated. Description budget: XXX → YYY tokens (−ZZZ)
```

## Editing policy

**What this skill auto-edits** (Step 4, with user approval):
- `description:` field in SKILL.md frontmatter

**What this skill displays but does not edit**:
- Body content (Step 3b hints; apply manually)
- Duplicate skills (Step 2 flags; remove manually)

**What this skill never touches**:
- `allowed-tools`, `name`, or any other frontmatter field
- Skill file/directory deletion or rename
