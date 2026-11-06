---
name: diagram-conventions
description: >
  Create or review a diagram: pick the diagram type that fits what the reader must understand,
  follow that type's established notation, and keep the source's meaning exact. Outputs Mermaid.
  Use for "draw this as a diagram", "make a flowchart", "review this diagram",
  "図にして", "フローチャートを書いて", "シーケンス図にして", "この図をレビューして".
allowed-tools: Read, Glob, Grep, Bash(command -v mmdc:*), Bash(mmdc:*), Bash(npx -y -p @mermaid-js/mermaid-cli@12 mmdc:*)
argument-hint: "[source text | file path | diagram to review] [type <diagram-type>]"
---

# diagram-conventions

Create or review exactly one diagram whose meaning matches its source, and show the reader how it is organized.

## Principles

Every diagram satisfies all three:

| Principle | Rule |
|---|---|
| Correctness | Never add an element or relation absent from the source, and never drop an important one present in it, including conditions, branches, and exceptions |
| Conformance | Follow the symbols and semantics of the chosen diagram type |
| Clarity | Granularity and layout leave no way to misread the meaning |

When a principle conflicts with looking complete or tidy, the principle wins.

## Rulebooks

`<skill-dir>` is the absolute path of this SKILL.md's directory, the base directory the harness gives this skill.
Each Markdown file in `<skill-dir>/references/` is one diagram type's rulebook: its `## Purpose` says what the type expresses and when to choose it; the rest holds its rules.
Only types with a rulebook have rules; a missing or empty `references/` means none.

## Procedure

### 1. Determine the Mode and the Source

Read `$ARGUMENTS`, the conversation, and any file path given.
The mode is Create when the user gives content and asks for its diagram, and Review when the user gives a diagram and asks to review, check, or fix it.
The source is what the diagram must depict: the input text when creating, or the text a reviewed diagram was drawn from.
If a review has no source, ask for it; if the user has none, review Conformance and Clarity only, and say in the output that Correctness was not checked.

### 2. Inventory the Source

List every element (actor, step, state, entity, component, event) and relation (flow, message, transition, association, dependency, ordering) in the source, with its conditions and where it appears.
This inventory, working notes and not output, is the only material the diagram may use.

### 3. Choose the Diagram Type

1. Glob `<skill-dir>/references/*.md`, never a working-directory-relative path, and read only each `## Purpose` section.
2. From the inventory, decide what the reader must understand: step order and branches, messages between actors over time, state transitions, data structure, dependencies, schedule, and so on.
3. Choose the type:

   | Situation | Choice |
   |---|---|
   | The user named a type that fits | Use it |
   | The user named a type whose notation cannot express what the reader must understand | Output only the fitting type, a one-sentence reason, and a question asking which to draw |
   | The user named no type | The rulebook whose Purpose matches, else the type whose established notation best expresses it |

   Judge fit by the type's notation, not by Mermaid's support for it. Never override a fitting named type for preference.
4. If the chosen type has a rulebook, read all of it and apply every rule. Otherwise draw under the three principles alone.

Draw with the closest Mermaid diagram. If Mermaid has none for the type, as for BPMN, use the one that loses the least meaning and name it. Say in one sentence when a Mermaid element stands in for a notation element, such as a subgraph for a swimlane.

### 4. Organize the Diagram

Decide before drawing; a rulebook's rule overrides these.

| Decision | Rule |
|---|---|
| Question | The one question the diagram answers, from what the reader must understand |
| Unit | What one node stands for, at one abstraction level throughout. Merge or split inventory items only to reach it, never to drop a condition |
| Grouping | Lanes, subgraphs, or boundaries only by a grouping the source states, such as each step's actor. A node the source puts in no group stays ungrouped, and the explanation says this means "not stated", not "outside" |
| Reading order | One direction, in the source's order: time, process flow, or dependency |
| Labels | The source's own terms, short, one meaning each |

### 5. Draw or Review

- Create: draw exactly one diagram from the inventory, organized per step 4, with no summary, legend, or second view. If one diagram cannot hold the source without breaking Clarity, say so and ask how to split; never split on your own.
- Review: list each defect with its broken principle and evidence, most severe first: wrong or invented relations, dropped relations, conditions, or branches, notation violations, then Clarity. A valid symbol stating what the source does not, such as concurrency, a loop, or optionality, breaks Correctness; Conformance covers only a symbol misused for its type. Then give the fixed diagram. Never report a style preference as a defect.

### 6. Check Against the Principles

Check the diagram, not your intent:

- Correctness: map every node and edge to an inventory item, removing any unmapped, and every important inventory relation to the diagram, adding any missing. Never draw an unstated element the notation seems to need, such as a start or end symbol or a return message; list it as not drawn if the drawn form needs it: a flowchart lists a missing start symbol, not a stated expiry's length. Never invent a value the notation needs, such as a Gantt task's duration or an association's multiplicity: use a form that needs none and list the value as not stated, or, if none exists, ask for it before drawing. List as an assumption any value or order Mermaid's syntax or layout forces, such as a date's year, unordered steps' order, or an unnamed message's sender.
- Conformance: recheck each rule of the rulebook used, if any, and that each symbol carries the meaning its type gives it.
- Clarity: the diagram follows step 4, and no edge or branch reads two ways.

Repeat until every check passes.

### 7. Validate the Mermaid

Run `command -v mmdc npx`, which prints each one found; if neither, mark it unvalidated.
Otherwise render from standard input with `mmdc`, or, when only npx is found, with `npx -y -p @mermaid-js/mermaid-cli@12 mmdc`, which may fetch into the npx cache; install nothing globally or into the target repository.

```bash
mmdc -q -i - -o - -e svg >/dev/null <<'MERMAID'
<Mermaid source>
MERMAID
```

A non-zero exit naming a source position, such as `Parse error on line 2` or `Lexical error`, or `UnknownDiagramError`, is a diagram error: fix it, recheck step 6, and rerender.
Any other failure, such as a missing browser, a crash, or a failed fetch, is a tool failure: keep the diagram and mark it unvalidated with the reason.
Validated means a render of the exact output diagram exited 0; a later edit needs another render.

## Output

Reply in the user's language. Lead with the diagram, preceded only by review mode's defect list, then explain how it is organized.
Keep the two closing status lines in English, verbatim apart from the placeholders, `<type>` included.

````
<review mode only: the defects, one per line, `<principle>: <defect> -> <evidence>`>

```mermaid
<the one diagram>
```

<diagram type, the Mermaid diagram used, the explicit step 4 question, and why this type answers it>
<the step 4 organization: what one node stands for, the grouping and its basis, the reading order>
<only when step 6 found any: one line per element not drawn, value not stated, or assumption, saying which; list nothing else>

Rulebook: <references/<file>.md | No rulebook exists for <type>; no conformance is claimed>
Validation: <validated with mmdc | unvalidated: <reason>>
````
