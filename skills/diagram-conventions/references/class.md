# Class Diagram

Every rule ends with a tag: `[Standard: UML 2.5.1]` when OMG UML 2.5.1 states it, `[Convention]` when it is common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A class diagram shows the static structure of types: the classes and interfaces, the attributes and operations each one has, and how they relate by inheritance, implementation, association, composition, and dependency.
Choose it when the reader must understand which types exist, what each one holds and can do, and which type is a kind of, is made of, or knows another.
It does not show behavior over time, order, or individual instances.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure: flowchart
- Messages between participants over time: sequence diagram
- The states of one thing and the events between them: state diagram
- Stored data with keys and cardinality, without operations or inheritance: ER diagram
- Deployable parts and the interfaces they provide or require: component diagram

## Correctness

- Draw only the classes, interfaces, attributes, operations, and relationships the source states. Never add an ID, a getter or setter, a constructor, a base class, or an interface to make the model look complete. `[Convention]`
- Choose each relationship from what the source says, never from the class names:

  | The source says | Relationship |
  |---|---|
  | B is a kind of A, or B extends A | Generalization |
  | B implements interface A | Realization |
  | A has, holds, or refers to B | Association |
  | B is part of A and does not exist without it, or is deleted with it | Composition |
  | A uses B, or depends on B, without saying it holds one | Dependency |

  "Has" alone is an association, never a composition, and inheritance stated together with an association stays two relationships of two kinds. When a sentence fits no row, draw an association and list the choice as an assumption. `[Convention]`
- Draw aggregation only where the source names it, because UML gives shared aggregation no semantics beyond an association. `[Standard: UML 2.5.1]`
- Write a multiplicity only at an end where the source states it. "At most" and "may" state a lower bound of zero, and a verb alone, such as "places", states no bound. Leave an unstated end without one and list it as not stated; `*` and `1` are constraints, never a stand-in for "unknown". `[Convention]`
- Draw a navigability arrow `-->` only where the source says which side knows or reaches the other; otherwise draw `--`. `[Convention]`
- Write a type, a visibility, a parameter, or `abstract` only where the source states it. Leave out what it does not, and list an unstated type as not stated. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| Class | A type | `class C`, or `class C["label"]` |
| Interface | A set of operations a class promises | `<<interface>>` inside `class I { ... }` |
| Attribute | A value each instance holds | `+name : Type` inside `class C { ... }` |
| Operation | Behavior an instance offers | `+op(p : Type) Return` inside `class C { ... }` |
| Generalization | The subclass is a kind of the superclass | `Super <|-- Sub` |
| Realization | The class implements the interface | `I <|.. C` |
| Association | Instances are linked | `A -- B`, or `A --> B` when only A navigates to B |
| Composition | The part exists only within one whole | `Whole *-- Part` |
| Aggregation | Shared part, as the source names it | `Whole o-- Part` |
| Dependency | One class uses the other | `A ..> B` |
| Multiplicity | How many instances at one end | `A "1" -- "0..*" B` |
| Comment | Text with no structure | `note for C "text"` |

- Declare `classDiagram`. `[Convention]`
- Use each symbol only for its meaning: the hollow triangle points to the superclass or interface, and the filled diamond sits at the whole. `[Standard: UML 2.5.1]`
- Write a member as `visibility name : Type` and an operation as `visibility name(parameter : Type) ReturnType`, each part present only when stated. Mermaid inserts the ` : ` before a return type itself, so never write it there. `[Convention]`
- Write a multiplicity as `n`, `n..m`, or `n..*`, with `*` for many. `[Standard: UML 2.5.1]`
- Label an association with the source's verb, read from the left class to the right, or leave it unlabeled when the source names none. `[Convention]`
- Never draw `..` without an arrowhead, `<|--|>`, or a lollipop `()--`; they have no UML meaning here. `[Convention]`
- `<<abstract>>` stands in for UML's italic name or `{abstract}`, and Mermaid cannot draw an association class, a qualifier, an n-ary association, or a constraint such as `{ordered}`. Name `<<abstract>>` as a substitute when used, list anything else the source states that these symbols cannot carry as not drawn, and claim no UML 2.5.1 conformance for either. `[Convention]`

## Clarity

- All classes sit at one level of abstraction, such as all domain types. `[Convention]`
- Name each class, member, and relationship with the source's term, as briefly as possible. When a name holds spaces or non-ASCII characters, give it an ASCII identifier with `class C["name"]`. `[Convention]`
- Write every generalization and realization with the superclass or interface on the left, `Super <|-- Sub` or `I <|.. C`, because Mermaid's layout ranks the left class of an edge above the right one, which keeps supertypes above their subtypes. `[Convention]`

## Validation

- Every class, member, and relationship maps to the source, and no ID, accessor, constructor, base class, or interface was added
- Every relationship's kind follows the source's words, and inheritance and association are never drawn with one symbol
- Every multiplicity, type, visibility, navigability arrow, and aggregation is stated in the source; every unstated one is left off and listed as not stated, never guessed
- Every substitute is named with no conformance claimed
