# ER Diagram

Crow's Foot is a family of notations, from Everest's 1976 "inverted arrow" through Information Engineering and Barker's CASE*Method, and no standard defines it. Every rule therefore ends with `[Convention]`: common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

An ER diagram shows the structure of data: the entities, the attributes each one holds, and the relationships between them with how many instances take part at each end.
Choose it when the reader must understand what data exists and how many of one thing relate to one of another.
It does not show behavior, order, time, or inheritance.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure: flowchart
- Messages between participants over time: sequence diagram
- The states of one thing and the events between them: state diagram
- Classes with operations or inheritance: class diagram

## Correctness

- Draw only the entities, attributes, keys, and relationships the source states. Never add an ID, a foreign key, a timestamp, or a junction entity to make the model look complete; a many-to-many relationship the source states stays one relationship. `[Convention]`
- Take both ends of every relationship from the source: at each end, the minimum (zero or one) and the maximum (one or many). When the source leaves any of the four values unstated, ask for it before drawing; zero-or-more is a constraint, never a stand-in for "unknown". `[Convention]`
- Draw `--` only where the source says the child is identified through the parent, such as "a line is numbered within its order". When the source does not say, draw `..` and list the choice as an assumption. `[Convention]`
- When the source states an attribute without its type, write the type as `unknown` and list the type as not stated; never infer one from the name. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| Entity | A kind of thing data is kept about | `E`, or `E["label"]` |
| Attribute | A value one entity holds | `type name` inside `E { ... }` |
| Key | Primary, foreign, or unique key | `PK`, `FK`, `UK` after the name |
| Cardinality marker | The minimum and maximum at one end | The block below |
| Identifying relationship | The child is identified through the parent | `--` |
| Non-identifying relationship | The child has its own identity | `..` |

The markers, left-end form then right-end form:

```
|o  o|   zero or one
||  ||   exactly one
}o  o{   zero or more
}|  |{   one or more
```

- Declare `erDiagram`. `[Convention]`
- The marker next to an entity counts that entity's instances for one instance at the other end, so `A ||..o{ B` reads "one A has zero or more B, and each B belongs to exactly one A". Read every relationship in both directions against the source. `[Convention]`
- The line style means identification only, never optional or mandatory participation. `[Convention]`
- Write every relationship as `A <marker><line><marker> B : label`; Mermaid requires the label. Use the source's verb, read from `A` to `B`, or `""` when the source names none. `[Convention]`
- When the source states something these symbols cannot carry, such as a subtype, state it in the output as a substitute and claim no conformance for it. `[Convention]`

## Clarity

- Name each entity, attribute, and relationship with the source's term, as briefly as possible. When an entity name holds spaces, give it an ASCII identifier with `E["name"]`. `[Convention]`

## Validation

- Every entity, attribute, key, and relationship maps to the source, and no ID, foreign key, timestamp, or junction entity was added
- Every relationship reads correctly in both directions, and every one of its four bounds is stated in the source or was asked for, never guessed
- Every `--` is an identification the source states, and every unstated one is `..` listed as an assumption
- Every unstated attribute type is `unknown` and listed as not stated
