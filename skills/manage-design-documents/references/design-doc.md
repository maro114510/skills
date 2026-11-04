# Design Doc

````markdown
# <Subject>

## Overview
<Purpose, responsibilities, and boundaries>

## Domain Model
<Concepts, their definitions, and relationships; not a physical schema>

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
- <Related Design Docs, ADRs, or specifications>
````

- Use only these sections, and leave out any without real content; never write "None".
- Write only what the request and the repository state.
- State each fact once: Domain Model names concepts and their states, diagrams show flows and state changes, and Invariants hold guarantees, including what a quantity counts. Never restate a fact in another section.
- A scenario's diagram shows the actors, the conditions that change the flow, the state changes, and the outcome. Participants are roles, not services. When interaction order adds nothing, draw the one diagram that fits instead. Draw no step, branch, or concurrency the design does not state.
- Invariants hold only guarantees whose omission would materially mislead an implementation, such as consistency under concurrency, security, or irreversible state.
- Write so that who does what to what, under which condition, with which result, is unambiguous. Use one term per concept, and never "appropriately" or "as needed" without the condition.
