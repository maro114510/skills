# Sequence Diagram

Every rule ends with a tag: `[Standard: UML 2.5.1]` when OMG UML 2.5.1 states it, `[Convention]` when it is common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding's evidence quotes that rule as well as the source. A defect that breaks rules in two sections is two findings; one that breaks several rules in one section is one finding quoting each. Judge Correctness against the source and Conformance against the diagram as drawn, so a message drawn the wrong way round is a Correctness finding even when its symbol fits the drawn diagram. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A sequence diagram shows one interaction: the messages its participants send each other, who sends each one to whom, and in what order.
Choose it when the reader must understand who asks whom for what, and when.

It does not show a procedure's full branching logic, how one thing's state changes, structure, or a schedule. Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure, with no exchange between participants to follow: flowchart
- The states of one thing and the events between them: state diagram
- Structure such as data, classes, or components: ER, class, or component diagram
- Dates and durations: Gantt chart or timeline

## Correctness

- Draw a lifeline only for a participant the source names as sending or receiving a message. A phase, a document, or a data item is never a lifeline. `[Convention]`
- Draw each message from the participant the source says sends it to the one the source says receives it. Never reverse it because the reply or the data flows the other way, and never route it through a participant the source does not put between them. `[Convention]`
- Never add a message the source does not state, including a reply, an acknowledgment, a self-call, or a retry. An action the source says one participant performs on or against another named participant, such as "checks them against the user store", is a message to that participant. `[Convention]`
- Put every message the source makes conditional inside an `opt` or an `alt` operand guarded by that condition, in the source's words; never invent a guard. A step the source makes optional, with words such as "may" or "only when", is an `opt`; when the source states no condition, the guard is the source's own optional wording, such as `client may cancel`. `[Convention]`
- Use `alt` only for alternatives the source states as excluding each other, one operand per alternative. Mermaid opens every later operand with `else`, so follow it with that alternative's own condition, and write `else otherwise` only for a case the source states as "otherwise". `[Convention]`
- Use `par` only where the source states that the operands happen concurrently or in any order. When the source gives no order for two messages, draw them in sequence in either order and list the order as an assumption. `[Convention]`
- Use `loop` only where the source states a repetition, labeled with the bound or condition the source states. Use `break` only where the source states that the rest of the enclosing fragment, such as a loop, is skipped. `[Convention]`
- Draw `->>` where the source says the sender waits and `-)` where it says the sender does not. When the source says neither, draw `->>` and list it as an assumption. `[Convention]`
- Draw a message as a reply only where the source itself says the caller waits for it; a wait you assumed never makes a reply. Draw any other message back to an earlier sender as a new message. `[Convention]`
- Create or destroy a participant only where the source states that it starts or ends within the interaction. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| Lifeline | A participant in the interaction | `participant X` |
| Actor lifeline | A person or external system acting on the system from outside | `actor X` |
| Synchronous message | A call whose sender waits for the receiver to finish | `->>` |
| Asynchronous message | A call or signal whose sender continues without waiting | `-)` |
| Reply | The return of a synchronous call, to its caller | `-->>` |
| Create message | A message that creates the receiving participant | `create participant X`, then `--)` to it |
| Destruction | The end of a participant within the interaction | `destroy X`, before its last message |
| Execution | The span in which a participant performs a behavior | `activate X` and `deactivate X`, or `+` and `-` on the messages |
| `alt` | At most one operand runs: the one whose guard holds | `alt <guard>` … `else <guard>` … `end` |
| `opt` | The only operand runs when its guard holds, and otherwise nothing runs | `opt <guard>` … `end` |
| `par` | The operands' messages may interleave in any way that keeps each operand's own order | `par <label>` … `and <label>` … `end` |
| `loop` | The operand repeats while its guard holds, within its bounds | `loop <guard>` … `end` |
| `break` | When its guard holds, the operand runs instead of the rest of the enclosing fragment | `break <guard>` … `end` |
| `critical` | The operand runs without interleaving with other messages | `critical <label>` … `end` |
| Comment | Text that adds no behavior | `Note over X: text` |

- Use each symbol only for its meaning. A reply goes only to the caller of a synchronous message it returns from. `[Standard: UML 2.5.1]`
- Time runs top to bottom on every lifeline, so a message is drawn below each message the source says comes before it. `[Standard: UML 2.5.1]`
- No two `alt` guards can both hold, so the operand that runs is never in doubt. `[Convention]`
- A comment carries no behavior, so never write a message as a note; a note stands in for an action only as the substitute below. `[Convention]`
- `create` and `destroy` need Mermaid 10.3 or later; say so in the output when the diagram uses one. `[Convention]`
- Never draw a message with `->`, `-->`, `-x`, `--x`, a bidirectional arrow, a half arrow, or a central connection: UML gives none of them a message meaning. `[Convention]`
- `rect` and `box` are not UML symbols. Use `box` only for a grouping the source states and `rect` only to shade a span the source names, and say in the output that each stands in for no UML element. `[Convention]`
- `critical` takes no `option` operands, because a UML critical region has one operand. `[Standard: UML 2.5.1]`
- For a UML element Mermaid cannot draw, such as a lost or found message or an action a participant performs without sending a message, use the closest form, such as a `Note over` the participant for the action, name the replacement, and claim no UML 2.5.1 conformance. `[Convention]`

## Clarity

- Every lifeline stands for a participant at one level of abstraction, such as all services or all classes in one service, never a mix. `[Convention]`
- Declare the lifelines in the order they first take part, the initiator leftmost, so most messages run left to right. `[Convention]`
- A message label names the request, signal, or returned value in the source's terms, in the shortest phrase that does. `[Convention]`
- Nest combined fragments only as deep as the source's conditions nest. A step that can happen only in one `alt` operand, such as one that needs what that operand sends, goes inside that operand. `[Convention]`

## Validation

- Every lifeline is a participant the source names, and all lifelines share one level of abstraction
- Every message's sender, receiver, and direction match the source, every message the source states is drawn, and no other message is
- Every conditional message is inside an `opt` or `alt` operand whose guard is the source's condition
- `par` appears only where the source states concurrency or any order, and every order the source does not state is listed as an assumption
- Every arrow is one of `->>`, `-)`, `-->>`, or a `--)` create message, used for its meaning
- Every unstated wait drawn as `->>` is listed as an assumption, and any `create` or `destroy` carries the Mermaid 10.3 note
- No `critical` has an `option`, and every substitute form is named with no conformance claimed
