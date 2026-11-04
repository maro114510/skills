# State Diagram

Every rule ends with a tag: `[Standard: UML 2.5.1]` when the State Machines clause of OMG UML 2.5.1 states it, `[Convention]` when it is common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A state diagram shows the lifecycle of one thing: the states it can be in, and the events and conditions that move it from one state to another.
Choose it when the reader must understand which state the thing can be in, and what takes it from one state to the next.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure: flowchart
- Messages between participants over time: sequence diagram
- Structure such as data, classes, or components: ER, class, or component diagram
- Dates and durations: Gantt chart or timeline

## Correctness

- A state is a condition of the one thing that the source says holds over a span, such as "pending" or "shipped". An operation, a step, a participant, or an event is never a state. `[Convention]`
- Draw a transition only where the source says the thing moves from one state to another, in the direction it states. Never add one the source does not state, such as a cancel from every state, a retry, a reset, or a self-transition. `[Convention]`
- Label a transition only with what the source states: its trigger event, `[guard]` for its condition, and `/ effect` for its action, each in the source's words. When the source states none of them, leave the transition unlabeled and list its event as not stated; never infer one from the state names or the sentence order. `[Convention]`
- Draw the initial pseudostate only to the state the source says the thing starts in, and a final state only after a state the source says it ends in. A state with no outgoing transition is not final unless the source says so. Otherwise list the start or end as not stated. `[Convention]`
- Use a choice only where the source says one event leads to different states under conditions it states, and guard each branch with its condition. List an outcome the source does not route as not stated. `[Convention]`
- Nest states in a composite state only where the source divides a state into substates, and draw concurrent regions, fork, and join only where the source says the thing is in several states at once. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| State | A condition that holds over a span | `S`, or `state "label" as S` |
| Initial pseudostate | Where a region starts | `[*] --> S` |
| Final state | Where a region completes | `S --> [*]` |
| Transition | A move from one state to another | `A --> B`, or `A --> B : trigger [guard] / effect` |
| Choice | One transition splits on guards evaluated when it is reached | `state C <<choice>>` |
| Fork / join | One transition splits into / merges from concurrent regions | `state F <<fork>>` / `state J <<join>>` |
| Composite state | A state containing substates | `state S { ... }` |
| Concurrent regions | Regions of one composite state active at once | `--` between the regions inside `state S { ... }` |
| Comment | Text with no behavior | `note right of S` … `end note` |

- Declare `stateDiagram-v2`. `[Convention]`
- Use each symbol only for its meaning. A step that does something is not a state, so it is never drawn as one. `[Standard: UML 2.5.1]`
- A transition label reads `trigger [guard] / effect`, in that order, with any part omitted. `[Standard: UML 2.5.1]`
- A region has at most one initial pseudostate, and the transition out of it carries no trigger or guard. `[Standard: UML 2.5.1]`
- The transitions out of a fork, and into a join, carry no trigger or guard. `[Standard: UML 2.5.1]`
- No two transitions out of one state on the same trigger, or out of one choice, have guards that can both hold. `[Convention]`
- Never write a transition or a state as a note. `[Convention]`
- Mermaid cannot draw a history state, an entry or exit point, a junction, a terminate pseudostate, or a state's internal transitions and entry, exit, and do behaviors. When the source states one, use the closest form, such as a note for a history state or a `S : entry / effect` description for a behavior, name it in the output, and claim no UML 2.5.1 conformance for it. `[Convention]`

## Clarity

- All states sit at one level of abstraction for the one thing; finer states go inside a composite state. `[Convention]`
- Name each state with the source's term for the condition, and each trigger with the source's term for the event, as briefly as possible. When a name holds spaces or non-ASCII characters, give it an ASCII identifier with `state "name" as S`. `[Convention]`

## Validation

- Every state and transition maps to the source, in the stated direction, and no stated transition is missing
- Every trigger, guard, and effect is the source's own; an unstated one is left off and listed as not stated, never guessed
- The initial pseudostate and every final state are stated in the source, or listed as not stated
- Every choice, composite state, concurrent region, fork, and join is stated in the source
- Every substitute is named with no conformance claimed
