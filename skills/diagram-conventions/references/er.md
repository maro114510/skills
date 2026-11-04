# ER Diagram

Crow's Foot is a family of notations, from Everest's 1976 "inverted arrow" through Information Engineering and Barker's CASE*Method, and no standard defines it. Every rule therefore ends with `[Convention]`: common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. A defect that breaks rules in two sections is two findings. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

An ER diagram shows the structure of data: the entities, the attributes each one holds, and the relationships between them with how many instances take part at each end.
Choose it when the reader must understand what data exists and how many of one thing relate to one of another.
It does not show behavior, order, time, or inheritance.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure: flowchart
- Messages between participants over time: sequence diagram
- The states of one thing and the events between them: state diagram
- Classes with operations or inheritance: class diagram
- Runtime parts of a system and their interfaces: component diagram

## Correctness

- An entity is a kind of thing the source says data is kept about; an attribute is a value the source says one entity holds. Never turn a verb into an entity unless the source keeps data about the act itself, such as "each booking records its date", and never turn an attribute into an entity or the reverse. `[Convention]`
- Draw only the entities, attributes, relationships, and keys the source states. Never add an ID, a foreign key, a timestamp, a junction entity, or a relationship that another path already implies, to make the model look complete or database-ready. `[Convention]`
- Keep the source's level: a source that names business things gets no keys or types it does not state, and a many-to-many relationship it states stays one relationship, never resolved into a junction entity. `[Convention]`
- Take both ends of every relationship from the source: at each end, the minimum (zero or one) and the maximum (one or many). A plural noun alone gives no minimum, and "has orders" gives no bound for the other end. When the source leaves any of the four values unstated, ask for it before drawing; Mermaid has no relationship without them, and zero-or-more is a constraint, never a stand-in for "unknown". `[Convention]`
- When the source states a bound the four markers cannot carry, such as "at most 3" or "2 to 5", draw the narrowest marker that allows every count the source allows, and list the exact bound as not drawn. `[Convention]`
- Draw `--` only where the source says the child is identified through the parent, such as "a line is numbered within its order". When the source does not say, draw `..` and list the choice as an assumption. A mandatory parent alone does not make a relationship identifying. `[Convention]`
- Mark an attribute `PK`, `FK`, or `UK` only where the source names it as a key or unique, and optional with `type?` only where the source says it may be absent. When the source states an attribute without its type, write the type as `unknown` and list the type as not stated; never infer one from the name. `[Convention]`
- Keep each relationship the source states as its own line, including two between the same entities and one from an entity to itself; never merge them. A fact the source states among three or more entities at once has no symbol here: ask how to draw it before drawing, never split it into pairs. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| Entity | A kind of thing data is kept about | `E`, or `E["label"]` |
| Attribute | A value one entity holds | `type name` inside `E { ... }`; `type?` when it may be absent |
| Key | Primary, foreign, or unique key membership | `PK`, `FK`, `UK` after the name, combined as `PK, FK` |
| Cardinality marker | The minimum and maximum at one end | The block below |
| Identifying relationship | The child is identified through the parent | `--` |
| Non-identifying relationship | The child has its own identity | `..` |

The markers, left-end form then right-end form; the inner character is the minimum, the outer one the maximum:

```
|o  o|   zero or one: minimum 0, maximum 1
||  ||   exactly one: minimum 1, maximum 1
}o  o{   zero or more: minimum 0, no maximum
}|  |{   one or more: minimum 1, no maximum
```

- Declare `erDiagram`. `[Convention]`
- Use each symbol only for its meaning. The marker next to an entity counts that entity's instances for one instance at the other end, so `A ||..o{ B` reads "one A has zero or more B, and each B belongs to exactly one A". Read every relationship in both directions against the source. `[Convention]`
- The line style means identification only, never optional or mandatory participation; Barker's notation, where a dashed half means optional, does not apply. `[Convention]`
- Write every relationship as `A <marker><line><marker> B : label`; Mermaid requires the label. Use the source's verb, read from `A` to `B`, or `""` when the source names none. `[Convention]`
- Mark every attribute of a composite primary key `PK`. `UK` cannot group a composite unique key and `FK` cannot name what it references, so state either in the output when the source does. `[Convention]`
- `type?` and a backquoted attribute name need Mermaid 11.16 or later; say so when the diagram uses either. `[Convention]`
- Mermaid has no symbol for a subtype, an exclusive relationship, or an attribute of a relationship. When the source states one, never draw it as an ordinary relationship or as an attribute of one entity: state it in the output as a substitute and claim no conformance for it. An entity identified through its parent needs no symbol of its own: draw it as an entity with an identifying relationship. `[Convention]`

## Clarity

- Name each entity with the source's term in the singular, and each attribute and relationship with the source's term, as briefly as possible. When an entity name holds spaces, give it an ASCII identifier with `E["name"]`; write such an attribute name in backquotes, and such a relationship label in double quotes. `[Convention]`
- When two relationships join the same entities, or one joins an entity to itself, label each with the role the source gives, so the two ends cannot be confused. `[Convention]`

## Validation

- Every entity, attribute, key, `type?`, and relationship maps to the source, and no ID, foreign key, timestamp, junction entity, or derivable relationship was added
- Every relationship reads correctly in both directions, and every one of its four bounds is stated in the source or was asked for, never guessed
- Every `--` is an identification the source states, and every unstated one is `..` listed as an assumption
- Every unstated attribute type is `unknown` and listed as not stated
- Every bound, subtype, exclusion, or n-ary fact the markers cannot carry is named in the output, with no conformance claimed
