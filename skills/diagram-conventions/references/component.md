# Component Diagram

Every rule ends with a tag: `[Standard: C4 Model]` when the C4 model's published guidance at c4model.com states it, `[Convention]` when it is common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A component diagram zooms into one container, a separately run application or data store, and shows the components it is built from: each component, what it is responsible for, and which part depends on which, together with the people, applications, data stores, and external systems those parts use or are used by.
Choose it when the reader must understand which part does what and which part depends on, calls, or sends data to which.
It does not show the order of calls, behavior over time, data structure, or where anything is deployed.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure: flowchart
- Messages between participants over time: sequence diagram
- The states of one thing and the events between them: state diagram
- Stored data with keys and cardinality: ER diagram
- Types with attributes, operations, or inheritance: class diagram
- How several separately run applications, services, or data stores relate, with no parts inside one of them: C4 container diagram

## Correctness

- Draw only the components, people, applications, data stores, and systems the source names, and only the dependencies it states. Never add a gateway, database, queue, cache, or logger, or a dependency to make the architecture look complete. `[Convention]`
- Draw each dependency from the part that uses, calls, reads from, or sends to another, to that other part, as the source states it. Never reverse it, never route it through a part the source does not, and never add the opposite arrow for a response or a return value. One stated relation is one arrow, even when its label names several actions, such as "reads from and writes to"; only dependencies the source states in both directions, as when A calls B and B calls A, are two arrows. `[Convention]`
- When the source states a relation without saying which side depends on which, as in "A and B communicate", draw it without an arrowhead, list its direction as not stated, and claim no C4 conformance for that line. `[Convention]`
- Give an element a type only from what the source says about it: a person who uses the system is a person; a part the source places inside the application being drawn is a component; something the source calls an application or app, or a data store, is a container; a system the source says is outside the one being drawn is a software system. A word in the name the source gives counts, so "Mobile App" is an app and "Order DB" a data store; "service" or "module" alone decides no type, because either can be a container or a component. When the source does not say, leave the type off and list it as not stated. The boundary is exempt: it is the container in scope, so Conformance always types it. `[Convention]`
- Write an element's responsibility and technology, and a relationship's technology or protocol, only where the source states them for that element or relationship, never inherited from a container; leave out what it does not and list it as not stated. A verb the source gives for a relationship labels that arrow and is never the element's responsibility; when it reads from the head, as "X accepts requests from Y" does on the arrow from Y to X, reword it to read from the tail, such as "Sends requests to", and list the rewording as an assumption. `[Convention]`
- Draw each queue or topic the source names as its own data store, typed `[Container: <broker technology>]` when the source names the broker, and put a stated message or event in the label of the arrow into it. A message broker or bus is never its own element. `[Standard: C4 Model]`
- A publisher's or sender's arrow points to the queue or topic, and so does a subscriber's or consumer's, labeled with the source's verb; never draw an arrow from a publisher to a subscriber. `[Convention]`
- Draw a boundary only around the components the source says belong to one application or system, labeled with its name. A placement such as "inside it, X calls Y" places every component its clause names, here X and Y, but never a data store or system unless the source says that one is inside; a part named only in another sentence is not placed, even when a placed part calls it. Leave each unplaced part outside and list its placement as not stated. `[Convention]`
- Start or end an arrow at the boundary when the source states a relation with the application as a whole, as in "the app calls the Account API", and list the component on the boundary's side as not stated; never pick one. `[Convention]`

## Conformance

The C4 model is notation independent: it defines element types, not shapes. Mermaid's `C4Component` diagram is experimental and places elements only by the order they are written, so its arrows cross elements and its labels overlap; draw with a flowchart instead.

| Element | Meaning | Mermaid |
|---|---|---|
| Person | Someone who uses the system | `id["Name<br>[Person]<br>responsibility"]` |
| Software system | A system outside the one being drawn | `id["Name<br>[Software System]<br>responsibility"]` |
| Container | A separately run application | `id["Name<br>[Container: technology]<br>responsibility"]` |
| Data store | A container that stores data | `id[("Name<br>[Container: technology]<br>responsibility")]` |
| Component | A grouping of related functionality inside one container | `id["Name<br>[Component: technology]<br>responsibility"]` |
| Boundary | The one container in scope, which the components belong to | `subgraph id["Name [Container: technology]"]` … `end`, on one line because it is a title |
| Relationship | The arrow's tail depends on, uses, or sends data to its head | `a -- "label<br>[technology]" --> b`, where `a` or `b` may be a boundary's `id` |
| Undirected relation | A relation whose direction the source does not state | `a -- "label" --- b` |

- Declare `flowchart TB`. `[Convention]`
- Give the diagram a frontmatter `title:` that names the diagram type and the application or system it shows, such as `Component diagram for API Application`, as the first lines inside the diagram's fenced block and nowhere else. When the source names none, write `Component diagram` and list the name as not stated. `[Standard: C4 Model]`
- Write every element's type in brackets after its name, with its technology after a colon, or `[Type]` alone when no technology is stated. The boundary is the one container in scope, so its type is always `Container`. `[Standard: C4 Model]`
- When Correctness leaves a type off, write `[Technology: <technology>]` if only the technology is stated and the name alone in the same rectangle if neither is, and claim no C4 conformance for that element. `[Convention]`
- Every line is one unidirectional arrow, labeled with the intent of the relationship read from tail to head, such as "Reads orders from". An undirected relation is the only exception, and claims no conformance. `[Standard: C4 Model]`
- Explain every shape and line style the diagram uses in the output's organization line, which serves as the key, because SKILL.md allows no legend diagram. `[Standard: C4 Model]`
- Never draw `<-->`, `-.->`, `==>`, `--o`, or `--x`; they carry no meaning in this notation. `[Convention]`

## Clarity

- All components sit at one level of abstraction inside one container. A code element the source names, such as a class, stands for the component that holds it: draw it as that component inside its container and list the choice as an assumption; never draw it beside a service. `[Convention]`
- Name each element and label each relationship with the source's term, as briefly as possible. Give every element an ASCII identifier, and put the name in its quoted label. `[Convention]`

## Validation

- Every element and arrow maps to the source, and no gateway, data store, queue, or other unstated part or dependency was added
- Every arrow points from the dependent part to the part it depends on, as the source states, with no reversed or response arrow
- Every type, responsibility, and technology is stated in the source, except the boundary's `Container` type, and every unstated one is left off and listed as not stated
- Every named queue or topic is its own data store with both publishers' and subscribers' arrows pointing to it, and no broker is its own element
- Every component inside the boundary is one its placement clause names, every other part sits outside with its placement listed as not stated, and every relation with the whole application starts or ends at the boundary
- Every undirected line is a relation whose direction the source does not state, listed as not stated with no C4 conformance claimed
- The diagram has a `title:`, every line is labeled, and the explanation describes every shape and line style
