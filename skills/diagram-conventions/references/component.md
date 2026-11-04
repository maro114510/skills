# Component Diagram

Every rule ends with a tag: `[Standard: C4 Model]` when the C4 model's notation guidance states it, `[Convention]` when it is common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A component diagram shows the parts one system or application is built from: each component, what it is responsible for, and which part depends on which, together with the people, applications, data stores, and external systems those parts use or are used by.
Choose it when the reader must understand which part does what and which part depends on, calls, or sends data to which.
It does not show the order of calls, behavior over time, data structure, or where anything is deployed.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure: flowchart
- Messages between participants over time: sequence diagram
- The states of one thing and the events between them: state diagram
- Stored data with keys and cardinality: ER diagram
- Types with attributes, operations, or inheritance: class diagram

## Correctness

- Draw only the components, people, applications, data stores, and systems the source names, and only the dependencies it states. Never add a gateway, database, queue, cache, or logger, or a dependency to make the architecture look complete. `[Convention]`
- Draw each dependency from the part that uses, calls, reads from, or sends to another, to that other part, as the source states it. Never reverse it, never route it through a part the source does not, and never add the opposite arrow for a response or a return value. One stated relation is one arrow, even when its label names several actions, such as "reads from and writes to"; only dependencies the source states in both directions, as when A calls B and B calls A, are two arrows. `[Convention]`
- When the source states a relation without saying which side depends on which, as in "A and B communicate", draw it without an arrowhead, list its direction as not stated, and claim no C4 conformance for that line. `[Convention]`
- Give an element a type only from what the source says about it: a person who uses the system is a person; a part of the application being drawn is a component; a separately run application or a data store is a container; a system the source says is outside the one being drawn is a software system. When the source does not say, leave the type off and list it as not stated. `[Convention]`
- Write an element's responsibility and technology, and a relationship's technology or protocol, only where the source states them; leave out what it does not and list it as not stated. `[Convention]`
- Draw a boundary only around the components the source says belong to one application or system, labeled with its name. `[Convention]`

## Conformance

The C4 model is notation independent: it defines element types, not shapes. Mermaid's `C4Component` diagram is experimental and places elements only by the order they are written, so its arrows cross elements and its labels overlap; draw with a flowchart instead.

| Element | Meaning | Mermaid |
|---|---|---|
| Person | Someone who uses the system | `id["Name<br>[Person]<br>responsibility"]` |
| Software system | A system outside the one being drawn | `id["Name<br>[Software System]<br>responsibility"]` |
| Container | A separately run application | `id["Name<br>[Container: technology]<br>responsibility"]` |
| Data store | A container that stores data | `id[("Name<br>[Container: technology]<br>responsibility")]` |
| Component | A grouping of related functionality inside one container | `id["Name<br>[Component: technology]<br>responsibility"]` |
| Boundary | The application or system the components belong to | `subgraph id["Name [Container]"]` … `end` |
| Relationship | The arrow's tail depends on, uses, or sends data to its head | `a -- "label<br>[technology]" --> b` |
| Undirected relation | A relation whose direction the source does not state | `a -- "label" --- b` |

- Declare `flowchart TB`. `[Convention]`
- Give the diagram a frontmatter `title:` that names the diagram type and the application or system it shows, such as `Component diagram for API Application`. `[Standard: C4 Model]`
- Write every element's type in brackets after its name. `[Standard: C4 Model]`
- Every line is one unidirectional arrow, labeled with the intent of the relationship read from tail to head, such as "Reads orders from". An undirected relation is the only exception, and claims no conformance. `[Standard: C4 Model]`
- Explain every shape and line style the diagram uses in the output's explanation, which serves as the key, because SKILL.md allows no legend diagram. `[Standard: C4 Model]`
- Never draw `<-->`, `-.->`, `==>`, `--o`, or `--x`; they carry no meaning in this notation. `[Convention]`

## Clarity

- All components sit at one level of abstraction inside one container; a class or function is never drawn beside a service. `[Convention]`
- Name each element and label each relationship with the source's term, as briefly as possible. Give every element an ASCII identifier, and put the name in its quoted label. `[Convention]`

## Validation

- Every element and arrow maps to the source, and no gateway, data store, queue, or other unstated part or dependency was added
- Every arrow points from the dependent part to the part it depends on, as the source states, with no reversed or response arrow
- Every type, responsibility, and technology is stated in the source, and every unstated one is left off and listed as not stated
- Every undirected line is a relation whose direction the source does not state, listed as not stated with no C4 conformance claimed
- The diagram has a `title:`, every line is labeled, and the explanation describes every shape and line style
