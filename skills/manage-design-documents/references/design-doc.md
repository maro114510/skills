# Design Doc

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
- State each fact once, in the section that owns it: Domain Model names concepts and their possible states; a flow or a transition between states lives in its diagram; a guarantee, including what a quantity counts, lives in Invariants. Overview and Domain Model never restate a transition or a guarantee.
- A scenario's diagram shows the actors, their interactions, the conditions that change the flow, the changes to data or domain state, and the outcome. Participants are conceptual responsibilities, not necessarily services or classes. Prose never restates the diagram.
- When interaction order adds nothing, as in some system-level documents, draw the one diagram type that fits instead of inventing scenarios.
- Draw and check each diagram with the `diagram-conventions` skill, and put only its Mermaid block into the document. Never add a step, order, branch, or concurrency the design does not state.
- Invariants hold only domain-wide guarantees whose omission could mislead an implementation, including critical consistency, concurrency, security, and irreversible-state guarantees. State what must hold, not the mechanism. A condition local to one scenario stays in that scenario. A diagram that reads a balance and then updates it does not establish that concurrent grants respect a balance cap; that cap is an invariant.
- In every normative sentence and diagram message, make the acting subject, the action, its object, each condition and what it applies to, and the result unambiguous whenever the distinction matters. Use one term per concept. Never leave "appropriately", "as needed", or "etc." without the condition it stands for.
