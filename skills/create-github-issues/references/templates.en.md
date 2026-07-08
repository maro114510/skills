# Templates (en)

## Step 1.5: Clarification Question Format

Enumerate each unclear item and ask for a response using the following format. The three labeled subsections below (`[Granularity]` / `[Acceptance criteria]` / `[Specification]`) are illustrative, not a fixed checklist — include only the subsection(s) for the axis/axes actually unclear this run.

```
The following points are unclear. Please answer before I continue.

**[Granularity] About <task name>**
<Specific two-choice or multiple-choice question>

**[Acceptance criteria] About <task name>**
<A specific question, e.g. "Can you state the done condition in one sentence?">

**[Specification] About <item name>**
<A two-choice or question that makes the ambiguity explicit>

I'll continue creating Issues once all questions are answered.
If you want to proceed with the specification still undecided, reply "proceed anyway" (I'll add a [NEEDS CONFIRMATION] tag and continue).
```

## Step 1.5: Warning Format

Output this when the user instructs to proceed with unresolved items:

```
[!] The following specifications are still undecided; Issues will be created anyway. The relevant sections in the Issue bodies will be tagged [NEEDS CONFIRMATION].

- <Undecided item 1>
- <Undecided item 2>
```

## Step 3: Summary Format

Output this block and ask for approval. Show every task's requirement/spec bullets and its dependency here — this is the main checkpoint for catching invented or misplaced content before it's written into a real Issue.

Use the same 12-task threshold as the Epic body template below: Mermaid for 12 or fewer tasks, the wave table for more. This preview must render in the same form the Epic will actually use — never show a Mermaid graph here if Step 4 is going to render a table, or vice versa.

```
## Issue structure to be created

### Epic (parent Issue)
**Title**: <Epic title>
**Summary**: <purpose in one line>

(Only if the number of tasks discussed differs from the number of child Issues: **Restructured from the conversation**: <which tasks were split/merged and why, in 1-2 sentences>)

(Only if applicable: **Epic split suggestion**: The dependency graph splits into independent groups and the count is large, so <proposed split> as separate Epics could also work instead of one Epic. Proceed with a single Epic anyway?)

### Dependency preview (temporary IDs; real Issue numbers are assigned after creation)

​```mermaid
flowchart LR
  subgraph Wave1[Wave 1: can start in parallel]
    T1["T1: <title>"]
  end
  subgraph Wave2[Wave 2: can start in parallel]
    T2["T2: <title>"]
  end
  T1 --> T2
​```

(For 13 or more tasks, use the table below instead of the graph above)

| Wave | Temp ID | Title | Depends on |
|------|---------|-------|------------|
| 1 | T1 | <title> | none |
| 2 | T2 | <title> | T1 |

### Child Issues (N total)

#### T1: <title> (Wave 1 / Depends on: none)
- Requirements: <bullet> / <bullet>
- Specs: <bullet> (write "none" if nothing was decided)
- Acceptance criteria draft: <one line in Given X / When Y / Then Z form>

#### T2: <title> (Wave 2 / Depends on: T1)
- Requirements: <bullet>
- Specs: none
- Acceptance criteria draft: <one line in Given X / When Y / Then Z form>

OK to proceed to writing the Issue bodies with this structure, dependencies, and requirement/spec drafts?
Let me know if anything needs to be added, removed, retitled, or corrected (dependencies, requirements, specs).
```

## Epic body (Step 4)

Use the Mermaid variant when there are 12 or fewer child Issues; otherwise use the table variant.

### Mermaid variant (≤12 child Issues)

```markdown
## Background

{The context that created this Epic — specific details from the conversation}

## Purpose

{What will be achieved when this Epic is complete}

## Scope

**Included:**
- {List child Issue titles}

**Not included:**
- {Intentionally excluded items — only ones actually discussed. Omit this subsection entirely if the conversation never named an exclusion; don't invent one just to fill the template.}

## Dependencies & Parallel Execution Plan

​```mermaid
flowchart LR
  subgraph Wave1[Wave 1: can start in parallel]
    T1["{{T1}} <title>"]
  end
  subgraph Wave2[Wave 2: can start in parallel]
    T2["{{T2}} <title>"]
  end
  T1 --> T2
​```

## Acceptance Criteria

### Target State
{What must be true when all child Issues are done}

### Verification
{How to confirm completion — E2E or integration checks}
```

### Table variant (>12 child Issues)

Replace the `## Dependencies & Parallel Execution Plan` section with:

```markdown
## Dependencies & Parallel Execution Plan

There are many child Issues, so this is shown as a table instead of a graph. Issues in the same Wave can be worked on in parallel.

| Wave | Issue | Title | Depends on |
|------|-------|-------|------------|
| 1 | {{T1}} | <title> | none |
| 1 | {{T4}} | <title> | none |
| 2 | {{T2}} | <title> | {{T1}} |
```

## Child Issue body (Step 4)

```markdown
## Background

{Why this task is needed, how it connects to the Epic — 1-3 sentences}

## Requirements

- {Observable/functional requirement grounded in the conversation. No implementation detail.}
- {Up to 5 bullets total}

## Specs

- {Concrete technical decision already settled in the conversation}
- {Up to 5 bullets. Omit this entire section if nothing was actually settled — never invent one.}

## Dependencies

{"Can start after Tn is done. See the Epic for the full dependency picture." or "None (can start in parallel)". Don't write step-by-step reasoning or detail here.}

## Acceptance Criteria

### Target State
{What must be true when done — concrete and verifiable}

### Verification
{Up to 5 items. Manual: numbered steps. Automated: assert what, run which command. If it takes more than 5 to cover the real scenarios, that's a signal this Issue should be split — see Step 2.}
```

**Banned in every section above:** lettered step sequences (`a→b→c→d`), pseudocode, function signatures, multi-level nested bullets. If a task genuinely needs that much detail to specify, split it into more child Issues, or add a single line linking to an existing design doc — never restate the doc inline.

## Step 4.5: Body Review Format

Show all Issue bodies in the following format and ask for approval:

```markdown
## Issue Body Review

`{{Tn}}` are temporary placeholders. Once the child Issues are created, they'll be replaced with the real Issue numbers (e.g. #123) in the Epic.

### Epic: <title>

<Full Epic body ({{Tn}} placeholders left as-is)>

---

### Child Issue T1: <title>

<Full child Issue T1 body>

---

### Child Issue T2: <title>

<Full child Issue T2 body>

---

I'll create the Issues above (the Epic is created first, then each child Issue is created with the Epic's number as its parent).
Let me know which part needs changes. If everything looks good, reply "create them".
```

## Step 6: Completion Report

```
## Created

### Epic
- #<number> <title>  (<URL>)
  (The Epic's number is lower than the child Issues' since it was created first.)

### Child Issues
- #<number> <title>
- #<number> <title>
...

The Epic and each child Issue are linked via native `gh issue create --parent` sub-issue relationships.
Dependencies are set as native Blocked-by/Blocking relationships via `--blocked-by`.
You can check both in the Issue sidebar on GitHub (Sub-issues / Relationships).
The Epic body's dependency diagram (or table) now uses the real Issue numbers.
```
