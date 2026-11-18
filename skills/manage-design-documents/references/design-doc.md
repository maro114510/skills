# Design Doc

Start with **Intent**: whose outcome matters, what to prioritize when goals conflict, and what is out of scope if the boundary would otherwise be unclear. Link existing requirements rather than copying them. Do not infer new requirements from intent.

Describe the decisions an implementer must preserve. Choose the representation that exposes the rules; there are no required section headings.

- **Domain model.** When the system makes decisions from domain facts, show their meanings, relationships, and constraints. For stateful behavior, show what can change, who or what may change it, and what must remain true. Keep independently changing facts separate. Use a diagram, table, or prose as appropriate; do not model storage or derive new domain rules from a diagram.
- **Use cases.** Show the actor, situation, and observable result where an example helps settle the design. Include failures or competing actions when they change the answer. An example illustrates a rule; it must not be the only source of a general guarantee.
- **Interfaces.** Say what crosses a boundary and what the receiver can rely on, including observable failure semantics. Link a maintained interface specification for exact details; include names or values here only if they are themselves part of the contract and not defined elsewhere.

Put a short reason next to a constraint if losing the reason would make the constraint easy to remove incorrectly. Link an ADR for a consequential tradeoff worth preserving separately. Do not include deliberation, delivery status, work breakdown, exhaustive test cases, or replaceable implementation details.

Check that a reader can tell what is settled, what is delegated, and whether materially different outcomes are still possible under the same facts. Resolve consequential ambiguity with the decision-maker; do not fill it in to finish the document.
