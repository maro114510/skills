---
name: diagram-conventions
description: >
  Create a new diagram, or review and fix an existing one, so that it keeps the exact meaning of its
  source, follows the established notation of the right diagram type, and cannot be misread.
  Picks the diagram type for what the reader needs to understand, checks every diagram against
  Correctness, Conformance, and Clarity, and outputs Mermaid. Use for requests like "draw a diagram
  of this", "make a flowchart", "turn this into a sequence diagram", "review this diagram",
  "fix this Mermaid diagram", "図にして", "フローチャートを書いて", "シーケンス図にして",
  "この図をレビューして", "この図を直して".
allowed-tools: Read, Glob, Grep, Write, Edit, Bash(command -v mmdc:*), Bash(mmdc:*)
argument-hint: "[source text | file path | diagram to review] [type <diagram-type>]"
---

# diagram-conventions

Create or review exactly one diagram whose meaning matches its source.
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

A rulebook is a Markdown file in `references/`, relative to this skill's directory, one per diagram type.
Its `## Purpose` section says what a reader understands from that diagram type; the rest holds the type's rules.
This file never lists diagram types: the set of rulebooks present is the set of types with rules.
If `references/` is missing or empty, no rulebook exists.

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

Before drawing, list from the source every element (actor, step, state, entity, component, event) and every relation (flow, message, transition, association, dependency, ordering), with its conditions.
Quote or point to where each appears. This inventory is the only material the diagram may use.

### 3. Choose the Diagram Type

1. Glob `references/*.md` in this skill's directory and read only the `## Purpose` section of each.
2. Decide what the reader must understand from the inventory: ordering of steps and branches, messages between actors over time, states and transitions, data structure, and so on.
3. Choose the type:

   | Situation | Choice |
   |---|---|
   | The user named a type that fits | Use it |
   | The user named a type that is clearly unfit, because its notation cannot express what the reader must understand | Propose the fitting type with a one-sentence reason, and ask which to draw before drawing |
   | The user named no type | Choose the rulebook whose Purpose matches; if none matches, choose the type whose established notation best expresses it |

   Never override a fitting named type for preference.
4. If the chosen type has a rulebook, read that whole rulebook and apply every rule. If it has none, draw under the three principles alone and record that no rulebook exists.

Draw the chosen type with the closest Mermaid diagram. If Mermaid has no dedicated diagram for it, as for BPMN, use the Mermaid diagram that loses the least meaning and say which one it is.

### 4. Draw or Review

- Create: draw exactly one diagram from the inventory. Do not add a summary diagram, a legend diagram, or a second view. If one diagram cannot hold the source without breaking Clarity, say so and ask how to split instead of splitting on your own.
- Review: list each defect with the principle it breaks and the evidence, most severe first: wrong or invented relations, dropped relations, notation violations, then Clarity. Then give the fixed diagram. Never report a style preference as a defect.

### 5. Check Against the Principles

Check the diagram, not your intent:

- Correctness: map every node and edge to an inventory item; remove anything unmapped. Map every important inventory relation to the diagram; add anything missing.
- Conformance: if a rulebook was used, recheck each of its rules. Check that each symbol carries the meaning the diagram type gives it.
- Clarity: check that labels name what the source names, granularity is uniform, and no edge or branch can be read two ways.

Repeat until every check passes.

### 6. Validate the Mermaid

Run `command -v mmdc`.

- Found: render the diagram with `mmdc --input - --output - --outputFormat svg`, passing the Mermaid source on standard input, and discard the SVG. Fix every syntax or rendering error and render again until it succeeds.
- Not found, or rendering cannot run: do not install anything. Mark the diagram unvalidated.

## Output

Reply in the user's language, but keep the fixed phrases below verbatim.

````
<review mode only: Defects, one per line, `<principle>: <defect> -> <evidence>`>

```mermaid
<the one diagram>
```

Type: <diagram type> (Mermaid: <Mermaid diagram used>) — <one-sentence reason>
Rulebook: <references/<file>.md | No rulebook exists for <type>; no conformance is claimed>
Trace:
- <node or edge> <- <where it appears in the source>
Validation: <validated with mmdc | unvalidated: <reason>>
````

When asking the user to choose a type in step 3, output only the proposal, its reason, and the question; draw nothing yet.
