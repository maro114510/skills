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
- Start with the message from what the source says starts the flow, such as a person's action, a scheduler, or a webhook. When the source does not say what starts it, start at the first message it states and list the trigger as not stated. `[Convention]`
- Draw each message from the participant the source says sends it to the one the source says receives it. Never reverse it because the reply or the data flows the other way, and never route it through a participant the source does not put between them. `[Convention]`
- Never add a message the source does not state, including an acknowledgment, a self-call, a retry, or a reply other than the ones the reply rule below requires. An action the source says one participant performs on or against another named participant, such as "checks them against the user store", is a message to that participant. `[Convention]`
- Put every message the source makes conditional inside an `opt` or an `alt` operand guarded by that condition, in the source's words; never invent a guard. A step the source makes optional, with words such as "may" or "only when", is an `opt`; when the source states no condition, the guard is the source's own optional wording, such as `client may cancel`. `[Convention]`
- Use `alt` only for alternatives the source states as excluding each other, one operand per alternative. Mermaid opens every later operand with `else`, so follow it with that alternative's own condition, and write `else otherwise` only for a case the source states as "otherwise". `[Convention]`
- Use `par` only where the source states that the operands happen concurrently or in any order. When the source gives no order for two messages, draw them in sequence in either order and list the order as an assumption. `[Convention]`
- Use `loop` only where the source states a repetition, labeled with the bound or condition the source states. Use `break` only where the source states that the rest of the enclosing fragment, such as a loop, is skipped. `[Convention]`
- Draw `->>` where the source says the sender waits and `-)` where it says the sender does not. When the source says neither, draw `->>` and list it as an assumption. `[Convention]`
- Draw a reply for every synchronous message whose caller the source says waits for a result, even when the source does not state the reply separately, because the wait states that something comes back. Label it with what the source says comes back; when the source names nothing, leave the label empty and list what comes back as not stated. A wait you assumed never makes a reply, and a message back to an earlier sender that answers nothing it waited for is a new message. `[Convention]`
- Draw `--)` only for a response or later notice the source states in answer to an earlier asynchronous message. When the source says a sender does not wait and states no response, put a note over the sender and receiver saying that no response comes back. `[Convention]`
- Create or destroy a participant only where the source states that it starts or ends within the interaction. `[Convention]`
- Draw an action the source says a participant performs on its own, such as validating input or detecting a difference, as a self-message `X->>X: <action>`, with no reply. `[Convention]`
- Draw an activation only where the source states a span in which a participant is busy, such as "while it processes the batch"; never only to show that a call is in progress. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| Lifeline | A participant in the interaction | `participant X` |
| Actor lifeline | A person who starts or takes part in the interaction; a scheduler, webhook sender, or queue is a plain lifeline | `actor X` |
| Synchronous message | A call whose sender waits for the receiver to finish | `->>` |
| Asynchronous message | A call or signal whose sender continues without waiting | `-)` |
| Reply | The return of a synchronous call, to its caller | `-->>` |
| Asynchronous response | A response or later notice to an earlier asynchronous message | `--)` |
| Create message | A message that creates the receiving participant | `create participant X` on the line directly before the `->>` or `-)` that creates it, never among the declarations at the top |
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
- A comment carries no behavior, so never write a message as a note; a note only states that no response comes back, or stands in for an element as the substitute below. `[Convention]`
- `create` and `destroy` need Mermaid 10.3 or later; say so in the output when the diagram uses one. `[Convention]`
- `--)` as an asynchronous response is a convention, not UML, which gives an asynchronous message no reply. Because UML's own create arrow looks the same, draw a create message as `->>` or `-)`, and claim no UML 2.5.1 conformance for either arrow. `[Convention]`
- Never draw a message with `->`, `-->`, `-x`, `--x`, a bidirectional arrow, a half arrow, or a central connection: UML gives none of them a message meaning. `[Convention]`
- `rect` and `box` are not UML symbols. Use `box` only for a grouping the source states and `rect` only to shade a span the source names, and say in the output that each stands in for no UML element. `[Convention]`
- `critical` takes no `option` operands, because a UML critical region has one operand. `[Standard: UML 2.5.1]`
- For a UML element Mermaid cannot draw, such as a lost or found message, or a duration constraint, use the closest form, such as a `Note over` the participants involved, name the replacement, and claim no UML 2.5.1 conformance. `[Convention]`

## Clarity

- Every lifeline stands for a participant at one level of abstraction, such as all services or all classes in one service, never a mix. `[Convention]`
- Place people and systems that start interactions on their own, such as a scheduler, leftmost; systems that only respond, such as a database or an external API, rightmost; and the rest between them in the order calls pass through them, so most messages run left to right. Declare each with `participant` or `actor` and the source's name for it, never implicitly through a message. `[Convention]`
- A message label names the request, signal, or returned value in the source's terms, in the shortest phrase that does. `[Convention]`
- Declare `autonumber`, so a review can cite each message by its number. Numbers in different `par` operands imply no order between them. `[Convention]`
- A diagram with more than 8 lifelines or more than 25 messages is too large to read. When creating, say so and propose a split by phase or story before drawing; when reviewing, report it as a Clarity defect. In each part of a split, mark where the flow continues with a note, because Mermaid cannot draw a UML interaction use (`ref`). `[Convention]`
- Nest combined fragments only as deep as the source's conditions nest. A step that can happen only in one `alt` operand, such as one that needs what that operand sends, goes inside that operand. `[Convention]`

## Validation

- Every lifeline is a participant the source names, and all lifelines share one level of abstraction
- Every message's sender, receiver, and direction match the source, every message the source states is drawn, and no other message is
- Every conditional message is inside an `opt` or `alt` operand whose guard is the source's condition
- `par` appears only where the source states concurrency or any order, and every order the source does not state is listed as an assumption
- The first message comes from the trigger the source states, or the trigger is listed as not stated, and every person is an `actor`
- Every arrow is one of `->>`, `-)`, `-->>`, or `--)`, used for its meaning
- Every message whose caller the source says waits has a reply, and every stated no-wait message without a stated response has a note saying none comes back
- The diagram declares `autonumber`
- Starters stand leftmost and responders rightmost, every activation spans a busy period the source states, and the diagram has at most 8 lifelines and 25 messages
- Every unstated wait drawn as `->>` is listed as an assumption, and any `create` or `destroy` carries the Mermaid 10.3 note
- No `critical` has an `option`, and every substitute form is named with no conformance claimed
