---
name: diagram-conventions
description: >
  Create or review a diagram: pick the diagram type that fits what the reader must understand,
  follow that type's established notation, and keep the source's meaning exact. Outputs Mermaid.
  Use for "draw this as a diagram", "make a flowchart", "review this diagram",
  "図にして", "フローチャートを書いて", "シーケンス図にして", "この図をレビューして".
allowed-tools: Read, Glob, Grep, Bash(command -v mmdc:*), Bash(mmdc:*)
argument-hint: "[source text | file path | diagram to review] [type <diagram-type>]"
---

# diagram-conventions

Create or review exactly one diagram whose meaning matches its source, and show the reader how it is organized.
Mermaid is the output format only; the notation and semantics come from the diagram type.

## Principles

Every diagram, created or reviewed, must satisfy all three:

| Principle | Rule |
|---|---|
| Correctness | Never add an element or relation absent from the source, and never drop an important one present in it, including conditions, branches, and exceptions |
| Conformance | Follow the symbols and semantics of the chosen diagram type |
| Clarity | Keep granularity and layout such that the meaning cannot be misread |

When a principle conflicts with looking complete or tidy, the principle wins.

## Rulebooks

`<skill-dir>` is the directory containing this SKILL.md, the base directory the harness gives for this skill; use its absolute path.
A rulebook is a Markdown file in `<skill-dir>/references/`, one per diagram type.
Its `## Purpose` section says what that diagram type expresses and when to choose it; the rest holds the type's rules.
This file never lists diagram types: the set of rulebooks present is the set of types with rules.
If `<skill-dir>/references/` is missing or empty, no rulebook exists.

## Procedure

### 1. Determine the Mode and the Source

Read `$ARGUMENTS` and the conversation. A file path is read with Read.

| Mode | When |
|---|---|
| Create | The user gives content and asks for a diagram of it |
| Review | The user gives an existing diagram and asks to review, check, or fix it |

The source is the content the diagram must depict: the input text in create mode, and in review mode the text the diagram was drawn from.
If a review has no source, ask for it. If the user has none, review Conformance and Clarity only, and state in the output that Correctness was not checked against a source.

### 2. Inventory the Source

List from the source every element (actor, step, state, entity, component, event) and every relation (flow, message, transition, association, dependency, ordering), with its conditions, and where each appears.
This inventory is the only material the diagram may use. Keep it as working notes; it is not part of the output.

### 3. Choose the Diagram Type

1. Glob `<skill-dir>/references/*.md`, never a path relative to the working directory, and read only the `## Purpose` section of each.
2. Decide what the reader must understand from the inventory: ordering of steps and branches, messages between actors over time, states and transitions, data structure, dependencies, schedule, and so on.
3. Choose the type:

   | Situation | Choice |
   |---|---|
   | The user named a type that fits | Use it |
   | The user named a type that is clearly unfit, because its notation cannot express what the reader must understand | Propose the fitting type with a one-sentence reason, and ask which to draw before drawing |
   | The user named no type | Choose the rulebook whose Purpose matches; if none matches, choose the type whose established notation best expresses it |

   Judge fit by the type's notation, not by Mermaid's support for it. Never override a fitting named type for preference.
4. If the chosen type has a rulebook, read that whole rulebook and apply every rule. If it has none, draw under the three principles alone.

Draw the chosen type with the closest Mermaid diagram. If Mermaid has no dedicated diagram for it, as for BPMN, use the Mermaid diagram that loses the least meaning and say which one it is. Whenever a Mermaid element stands in for a notation element, such as a subgraph for a swimlane, say so in one sentence.

### 4. Organize the Diagram

Decide the organization before drawing. A rulebook's rule overrides any choice below.

| Decision | Rule |
|---|---|
| Question | The one question the diagram answers, taken from what the reader must understand |
| Unit | What one node stands for, at one level of abstraction for the whole diagram. Merge or split inventory items only to reach that level, never to drop a condition |
| Grouping | Group nodes, as lanes, subgraphs, or boundaries, only by a grouping the source states, such as the actor that performs each step. A node the source assigns to no group stays outside every group, and the explanation says that this placement means "not stated", not "outside" |
| Reading order | One direction, following the order the source gives: time, process flow, or dependency |
| Labels | The source's own terms, short, one meaning each |

### 5. Draw or Review

- Create: draw exactly one diagram from the inventory, organized as step 4 decided. Do not add a summary diagram, a legend diagram, or a second view. If one diagram cannot hold the source without breaking Clarity, say so and ask how to split instead of splitting on your own.
- Review: list each defect with the principle it breaks and the evidence, most severe first: wrong or invented relations, dropped relations, notation violations, then Clarity. A valid symbol that states something the source does not, such as concurrency, a loop, or optionality, breaks Correctness; Conformance covers only a symbol misused for its diagram type. Then give the fixed diagram. Never report a style preference as a defect.

### 6. Check Against the Principles

Check the diagram, not your intent:

- Correctness: map every node and edge to an inventory item; remove anything unmapped. Map every important inventory relation to the diagram; add anything missing. When the notation seems to need an element the source does not state, such as an end event or a return message, leave it out and list it as not drawn; never draw it. When a stated element lacks a value the notation needs, such as a duration, a date, a condition, or a multiplicity, never invent the value: use a form of the element that needs none and list the value as not stated, or, if no such form exists, ask for it before drawing. A value the Mermaid syntax alone forces, such as the year in a date, is listed as an assumption.
- Conformance: if a rulebook was used, recheck each of its rules. Check that each symbol carries the meaning the diagram type gives it.
- Clarity: check that the diagram follows step 4, and that no edge or branch can be read two ways.

Repeat until every check passes.

### 7. Validate the Mermaid

Run `command -v mmdc`.

- Found: render the diagram from standard input and discard the SVG:

  ```bash
  mmdc --quiet --input - --output - --outputFormat svg > /dev/null <<'MERMAID'
  <the Mermaid source>
  MERMAID
  ```

  A non-zero exit whose error names a position in the Mermaid source, such as `Parse error on line 2` or `Lexical error`, or `UnknownDiagramError`, is a diagram error: fix the diagram, recheck step 6, and render again.
  Any other failure, such as a missing browser or a crash, is a tool failure: do not change the diagram, and mark it unvalidated with that reason.
- Not found: do not install anything. Mark the diagram unvalidated.

The diagram is validated only when a render of the exact diagram in the output exited 0. Any edit after that render needs another render.

## Output

Reply in the user's language. Lead with the diagram, preceded only by the defect list in review mode, then explain how it is organized so the reader can follow it.
Keep the two status lines at the end in English, verbatim apart from the placeholders, and write `<type>` there in English.

````
<review mode only: the defects, one per line, `<principle>: <defect> -> <evidence>`>

```mermaid
<the one diagram>
```

<diagram type, the Mermaid diagram used, the question from step 4 stated explicitly, and why this type answers it>
<the organization from step 4: what one node stands for, the grouping and its basis, the reading order>
<only when step 6 found any: one line each for an element not drawn, a value not stated, or an assumption, saying which; list nothing else>

Rulebook: <references/<file>.md | No rulebook exists for <type>; no conformance is claimed>
Validation: <validated with mmdc | unvalidated: <reason>>
````

When asking the user to choose a type in step 3, output only the proposal, its reason, and the question; draw nothing yet.
