# Flowchart

Every rule ends with a tag: `[Standard: ISO 5807]` when ISO 5807:1985 states it, `[Convention]` when it is common practice adopted here.
A review finding names the section of the rule it breaks and quotes that rule.

## Purpose

A flowchart shows one procedure: its steps in order, the conditions it branches on, and the loops it repeats.
Choose it when the reader must follow a procedure step by step.

Choose another type when the reader must understand something else:

- The states of one thing and the events between them: state diagram
- Messages between participants over time: sequence diagram
- Structure such as data, classes, or components: ER, class, or component diagram
- Dates and durations: Gantt chart or timeline

## Correctness

- Draw a decision for every condition the source states, and for no other. `[Convention]`
- Draw one exit per outcome the source routes, labeled in the source's words. List an outcome the source does not route as not stated; never infer it from sentence order. `[Convention]`
- Draw a loop only where the source states a repetition. It leaves through a decision on the exit condition the source states. `[Convention]`
- When the source does not say where a condition is tested, place it where the layout needs and list the placement as an assumption. `[Convention]`

## Conformance

| Symbol | Meaning | Mermaid |
|---|---|---|
| Terminator | Start or end of the procedure, or entry from or exit to outside it | `([text])` |
| Process | An operation | `[text]` |
| Predefined process | A named procedure defined elsewhere | `[[text]]` |
| Decision | A test that selects one exit | `{text}` |
| Data | Input or output | `[/text/]` |
| Flowline | The order from one symbol to the next | `-->` |

- Use each symbol only for its meaning. A state is not an operation, so it is never a process. `[Standard: ISO 5807]`
- A decision takes exactly one exit, so no two of its exit conditions overlap. `[Standard: ISO 5807]`
- Every exit of a symbol with several exits is labeled with its condition. `[Standard: ISO 5807]`
- Flow runs top to bottom or left to right: declare `flowchart TB` or `flowchart LR`. `[Standard: ISO 5807]`
- A flowline against that direction has an arrowhead. `[Standard: ISO 5807]`
- Draw every flowline as `-->`, so no backward line lacks an arrowhead whatever the layout. `[Convention]`
- Crossing flowlines mean nothing, so avoid them. `[Standard: ISO 5807]`
- For another ISO 5807 symbol, such as document, use the Mermaid shape documented for it. When Mermaid has none, as for the connector, use the closest shape, name the replacement, and claim no ISO 5807 conformance. `[Convention]`

## Clarity

- Branch only at a decision. Every other symbol has one exit, because several exits from a process read as both a choice and parallel steps. `[Convention]`
- Text in a symbol is the shortest phrase that names its function. `[Standard: ISO 5807]`

## Validation

- Every node is a symbol from the table used for its meaning, or a named replacement
- Only decisions have more than one exit, and every such exit carries a condition from the source
- No two exits of a decision can both hold
- Every condition the source states is a decision, and every loop leaves through one
- Every outcome the source does not route is listed as not stated, not drawn
- The diagram declares `TB` or `LR`, and every flowline is `-->`
