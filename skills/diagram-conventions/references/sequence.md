# Sequence Diagram

Every rule ends with a tag: `[Standard: UML 2.5.1]` when OMG UML 2.5.1 states it, `[Convention]` when it is common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A sequence diagram shows one interaction: who sends which message to whom, and in what order.
Choose it when the reader must understand who asks whom for what, and when.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure, with no exchange between participants: flowchart
- The states of one thing and the events between them: state diagram
- Structure such as data, classes, or components: ER, class, or component diagram
- Dates and durations: Gantt chart or timeline

## Correctness

- A lifeline is a participant the source names as sending or receiving; a phase, document, or data item never is. `[Convention]`
- Start with the message from what the source says starts the flow; if it does not say, list the trigger as not stated. `[Convention]`
- Draw each message from the sender the source names to the receiver it names, never reversed and never routed through another participant. `[Convention]`
- Never add a message the source does not state, such as an acknowledgment, a retry, or a reply the reply rule does not require. An action one participant performs against another, such as "checks them against the user store", is a message to it; an action it performs on its own is a self-message `X->>X`. `[Convention]`
- Use a fragment only for what the source states: `alt` for alternatives that exclude each other, `opt` for a conditional or optional ("may") step, `par` for concurrency or "any order", `loop` for repetition, `break` for skipping the rest of the enclosing fragment. Guard each with the source's own words, after `else` too; never invent one. When the source gives no order, draw one order and list it as an assumption. `[Convention]`
- Draw `->>` where the source says the sender waits, `-)` where it says it does not, and `->>` listed as an assumption where it says neither. `[Convention]`
- Draw a reply `-->>` for each call the source says the caller waits on, labeled with what comes back, or empty with the content listed as not stated. An assumed wait never makes a reply. `[Convention]`
- Draw `--)` only for a response the source states to an asynchronous message. When the source says a sender does not wait and states no response, add a note that none comes back. `[Convention]`
- Create, destroy, or activate a participant only where the source states that it starts, ends, or is busy over a span. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| Lifeline | A participant | `participant X` |
| Actor | A person; a scheduler or webhook sender is a plain lifeline | `actor X` |
| Synchronous message | The sender waits | `->>` |
| Asynchronous message | The sender does not wait | `-)` |
| Reply | The return of a synchronous call, to its caller | `-->>` |
| Asynchronous response | A response to an asynchronous message | `--)` |
| Creation | A participant starts here | `create participant X` directly before the message that creates it |
| Destruction | A participant ends here | `destroy X` before its last message |
| Execution | A span in which a participant is busy | `activate X` … `deactivate X` |
| `alt` / `opt` | At most one guarded operand runs / the operand runs only if its guard holds | `alt <guard>` … `else <guard>` … `end` / `opt <guard>` … `end` |
| `par` | Operands interleave in any order | `par` … `and` … `end` |
| `loop` / `break` | The operand repeats / runs instead of the rest of the enclosing fragment | `loop <guard>` … `end` / `break <guard>` … `end` |
| `critical` | The operand runs without interleaving | `critical` … `end`, with no `option` |
| Comment | Text with no behavior | `Note over X: text` |

- Use each symbol only for its meaning; a reply goes only to its caller. `[Standard: UML 2.5.1]`
- Time runs top to bottom, so each message is drawn below every message the source puts before it. `[Standard: UML 2.5.1]`
- No two `alt` guards can both hold. `[Convention]`
- Never write a message as a note. `[Convention]`
- Never draw `->`, `-->`, `-x`, `--x`, bidirectional, half, or central arrows; they have no UML message meaning. `[Convention]`
- These have no UML equivalent, so name each in the output and claim no UML 2.5.1 conformance for it: `--)`, the creating arrow, `box`, `rect`, and a note standing in for an element Mermaid cannot draw, such as a lost message. Use `box` and `rect` only for a grouping or span the source names. `create` and `destroy` need Mermaid 10.3 or later; say so when used. `[Convention]`

## Clarity

- All lifelines sit at one level of abstraction, such as all services. `[Convention]`
- Place starters, such as a person or a scheduler, leftmost and pure responders, such as a database or an external API, rightmost, so most messages run left to right. Declare every lifeline at the top with the source's name, never implicitly through a message; a created lifeline is declared only by its `create participant`. `[Convention]`
- Label each message with the source's term for the request or the returned value, as briefly as possible. `[Convention]`
- Declare `autonumber`. `[Convention]`
- Above 8 lifelines or 25 messages a diagram is too large: propose a split by phase or story before drawing, or report it in a review, and mark each part's continuation with a note. `[Convention]`
- Nest fragments only as the source's conditions nest; a step that only one `alt` operand can reach goes inside it. `[Convention]`

## Validation

- Every lifeline and message maps to the source, in the stated direction, and no stated message is missing
- Every conditional, optional, concurrent, or repeated message is in the fragment the source states, with its guard
- Every arrow matches the stated wait, every stated wait has a reply, and every unstated choice is listed as an assumption
- Every substitute is named with no conformance claimed, and the diagram has `autonumber`, at most 8 lifelines, and at most 25 messages
