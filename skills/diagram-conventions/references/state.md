# State Diagram

Every rule ends with a tag: `[Standard: UML 2.5.1]` when the State Machines clause of OMG UML 2.5.1 states it, `[Convention]` when it is common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. A defect that breaks rules in two sections is two findings. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A state diagram shows the lifecycle of one thing: the states it can be in, and the events and conditions that move it from one state to another.
Choose it when the reader must understand which state the thing can be in, and what takes it from one state to the next.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure: flowchart
- Messages between participants over time: sequence diagram
- Structure such as data, classes, or components: ER, class, or component diagram
- Dates and durations: Gantt chart or timeline

## Correctness

- A state is a condition of the one thing that the source says holds over a span, such as "pending", "shipped", or an activity that goes on over a span, such as "settling". A one-shot action, such as "the shop is notified", is an effect on a transition, never a state; a participant or an event is never a state either. `[Convention]`
- Draw a transition only where the source says the thing moves from one state to another, in the direction it states. Never add one the source does not state, such as a cancel from every state, a retry, a reset, or a self-transition. `[Convention]`
- Label a transition only with what the source states: its trigger event, `[guard]` for its condition, and `/ effect` for its action, each in the source's words; never infer one from the state names or the sentence order. A transition out of a state with no trigger is a completion transition, taken as soon as the state's work is done: draw one where the source says the move happens then, as with "once captured" or "when both are done". Where the source states no trigger at all, also leave the transition unlabeled, and list its trigger as not stated so it is not read as a completion transition. `[Convention]`
- In each region, the top level and every region of a composite state alike, draw the initial pseudostate only to the state the source says it starts in, and a final state only after a state the source says it ends in. A state with no outgoing transition is not final unless the source says so. Otherwise list the start or end as not stated. When the source names the event that starts the thing, such as "on signup", the initial transition still carries no trigger: list that event as not drawn. `[Convention]`
- Use a choice only where the source says one event leads to different states under conditions it states. Put the event on the transition into the choice and only the guards, in the source's words, on the transitions out of it. List an outcome the source does not route as not stated. `[Convention]`
- Nest states in a composite state only where the source divides a state into substates, and draw concurrent regions, fork, and join only where the source says the thing is in several states at once. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| State | A condition that holds over a span | `S`, or `state "label" as S` |
| Initial pseudostate | Where a region starts | `[*] --> S` |
| Final state | Where a region completes | `S --> [*]` |
| Transition | A move from one state to another | `A --> B`, or `A --> B : trigger [guard] / effect` |
| Choice | One transition splits on guards evaluated when it is reached | `state C <<choice>>` |
| Fork / join | One incoming transition splits into states in different concurrent regions / transitions from states in different regions merge into one | `state F <<fork>>` and `state J <<join>>` declared outside the composite state, with `F --> S` and `S --> J` naming the states inside its regions |
| Composite state | A state containing substates | `state S { ... }` |
| Concurrent regions | Regions of one composite state active at once | `--` between the regions inside `state S { ... }` |
| Comment | Text with no behavior | `note right of S` … `end note` |

- Declare `stateDiagram-v2`. `[Convention]`
- Use each symbol only for its meaning. `[Standard: UML 2.5.1]`
- A transition label reads `trigger [guard] / effect`, in that order, with any part omitted. `[Standard: UML 2.5.1]`
- A region has at most one initial pseudostate, and the transition out of it carries no trigger or guard. `[Standard: UML 2.5.1]`
- The transitions out of a fork, and into a join, carry no trigger or guard. `[Standard: UML 2.5.1]`
- No two transitions out of one state on the same trigger, or out of one choice, have guards that can both hold. When the source's own conditions can both hold, keep its words and list which one wins as not stated; never pick one. `[Convention]`
- Never write a transition or a state as a note. `[Convention]`
- Mermaid cannot draw a history state, an entry or exit point, a junction, a terminate pseudostate, or a state's internal transitions and entry, exit, and do behaviors. When the source states one, write it in a note on the nearest state, such as `entry / notify shop`, never as `S : text`, which Mermaid shows in place of the name of a composite or undeclared state. Name the note as a substitute in the output, and claim no UML 2.5.1 conformance for it. `[Convention]`

## Clarity

- All states sit at one level of abstraction for the one thing; finer states go inside a composite state. `[Convention]`
- Name each state with the source's term for the condition, and each trigger with the source's term for the event, as briefly as possible. When a name holds spaces or non-ASCII characters, give it an ASCII identifier with `state "name" as S`. `[Convention]`

## Validation

- Every state and transition maps to the source, in the stated direction, and no stated transition is missing
- Every trigger, guard, and effect is the source's own; an unstated one is left off and listed as not stated, never guessed
- The initial pseudostate and every final state are stated in the source, or listed as not stated
- Every choice, composite state, concurrent region, fork, and join is stated in the source
- Every substitute is named with no conformance claimed
