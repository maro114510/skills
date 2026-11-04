---
name: manage-design-documents
description: >
  Decide whether a change needs a Design Doc, an ADR, both, or neither, then create, revise, delete, or review them in a Git repository.
  A Design Doc states the intended design of a system or domain; an ADR records one consequential decision and why.
  Use for "write a design doc", "add an ADR", "update the design doc", "does this need an ADR", "設計ドキュメントを書いて", "ADR を書いて", "Design Doc を更新して", "ADR が必要か判断して".
  Not for hunting fatal design defects (pr-doc-review-pe).
allowed-tools: Read, Glob, Grep, Edit, Write, AskUserQuestion, Bash(git grep:*, git rm:*)
argument-hint: "[change or decision to document | document path to review]"
---

# manage-design-documents

Work in the repository the user names, otherwise the current one. Never commit, push, or open a pull request.

| Document | States | Never states |
|---|---|---|
| Design Doc | What a system or domain is meant to be: its concepts, responsibilities, boundaries, behavior, and guarantees | Decision history, alternatives, implementation status, implementation mechanisms or code-level design, full API or schema detail, exhaustive lists of scenarios, edge cases, or failure modes, coding conventions, design slogans |
| ADR | One consequential decision, its decisive reasons, and its consequences | The investigation's history |

Never add status, authors, dates, a changelog, an owner, or an approval state to either document.

## 1. Inspect

1. Read the repository instructions, the existing Design Docs and ADRs related to the request, and the code it concerns.
2. Place documents where the repository already keeps them, named as it already names them. With no precedent, use `docs/design/<subject>.md` and `docs/adr/<decision-slug>.md`, unnumbered.

## 2. Decide

| The request | Action |
|---|---|
| Changes the concepts, responsibilities, boundaries, significant behavior, data or state changes, or invariants of a system or domain | Update the Design Doc that covers it. Create one only when none does, and never one per feature, Issue, or code change |
| Makes a consequential choice: material alternatives exist and the choice is costly to reverse or constrains later design | Write an ADR |
| Replaces or retracts the decision of an existing ADR | Update the Design Doc, write a new ADR for a replacing decision that meets the row above, listing the replaced one among its alternatives, and delete the obsolete ADR as section 4 says |
| Does none of these, as a routine feature or implementation edit does | Write nothing, and say why |

When several rows apply, take every action they name.

The Design Doc is normative. Code that does not implement part of it yet does not contradict it; code that behaves otherwise does. When the user says the design changes, change it. Otherwise, when code, an Issue, or another document contradicts the part of it the request concerns, ask whether the design changes or the other side is wrong, and never rewrite the design to match code or let an Issue override it. Report any other contradiction you find without editing.

Beyond such a contradiction, ask with AskUserQuestion, giving concrete options, only when the design the request needs cannot be determined uniquely from the request and the sources section 1 reads, or when an unresolved premise or missing guarantee could cause data corruption, a security exposure, a broken contract, or an irreversible change. Never invent a domain rule: leave out a rule those sources do not state and that meets neither condition, and do not count its absence as ambiguity.

## 3. Write

Write a new document in the language that `bash <skills-root>/create-pr/scripts/lang.sh` prints, where `<skills-root>` is the parent of this skill's directory; on a non-zero exit, show its output and stop. Write an edit in the language of the document it edits.

### Design Doc

````markdown
# <Subject>

## Overview
<Purpose, responsibilities, and boundaries>

## Domain Model
<Essential concepts, their definitions, data, and relationships; conceptual, not a physical schema>

## Scenarios

### <Scenario>
<One sentence: who wants what, and why>

```mermaid
sequenceDiagram
    <participants and messages>
```

## Invariants
- <A guarantee that holds in every scenario>

## References
- <Related current Design Docs, ADRs, or specifications>
````

- Use only these sections, each only when it has content; never write a placeholder.
- State each fact once, in the section that owns it: a guarantee in Invariants, a flow or state change in its diagram. Overview and Domain Model never restate either.
- A scenario's diagram shows the actors, their interactions, the conditions that change the flow, the changes to data or domain state, and the outcome. Participants are conceptual responsibilities, not necessarily services or classes. Prose never restates the diagram.
- When interaction order adds nothing, as in some system-level documents, draw the one diagram type that fits instead of inventing scenarios.
- Draw and check each diagram with the `diagram-conventions` skill, and put only its Mermaid block into the document. Never add a step, order, branch, or concurrency the design does not state.
- Invariants hold only domain-wide guarantees whose omission could mislead an implementation, including critical consistency, concurrency, security, and irreversible-state guarantees. State what must hold, not the mechanism. A condition local to one scenario stays in that scenario. A diagram that reads a balance and then updates it does not establish that concurrent grants respect a balance cap; that cap is an invariant.
- In every normative sentence and diagram message, make the acting subject, the action, its object, each condition and what it applies to, and the result unambiguous whenever the distinction matters. Use one term per concept. Never leave "appropriately", "as needed", or "etc." without the condition it stands for.

### ADR

```markdown
# <The decision, as a short statement>

## Context
<The problem and the forces that require a decision>

## Decision
<The chosen approach>

## Rationale
<The decisive reasons, and each material alternative with why it lost>

## Consequences
<Benefits, costs, limitations, and accepted risks>
```

Use exactly these four sections. Put the resulting design in the Design Doc and list the ADR in its References; keep the rationale only in the ADR.

Before finishing, remove every section, sentence, and diagram you wrote that has no purpose, repeats another, or states something the table at the top forbids.

## 4. Revise and Delete

- Change only what the request changes.
- Content you write follows this skill's format. Leave existing parts outside it, such as a Status field, as they are, and report them.
- Delete an ADR without asking only when the request or a new decision explicitly replaces or retracts it. When obsolescence is only inferred, as from code or age, ask first.
- If part of the ADR's decision still applies, keep it: move it into the replacing ADR, or, with no replacing ADR, cut the ADR down to that part instead of deleting it.
- Fix every in-repository reference to a deleted ADR that `git grep` finds by its file name.
- Delete with `git rm <path>`. If it refuses, as for an untracked file or uncommitted changes, Git does not hold the current content, so ask before removing the file.

## 5. Review

When asked to review a document, list each violation of this skill's rules as `<file:line>: <rule> -> <fix>`, most material first, and edit nothing unless asked.

## Output

Reply in the user's language:

- The decision: Design Doc, ADR, both, or neither, with a one-sentence reason
- The files created, edited, or deleted, and the references fixed
- Contradictions and pre-existing format deviations left unresolved
