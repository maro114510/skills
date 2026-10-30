# Flowchart

Each rule has an ID and a tag. `[Standard: ISO 5807]` means ISO 5807:1985 states the rule; `[Convention]` means common practice adopted here.
A review finding names the principle of the section that holds the rule it breaks, and cites the rule's ID, such as `Conformance (CON-2)`.

## Purpose

A flowchart shows one procedure: the steps in the order they run, where the flow branches on a condition, and where it loops.

Choose it when the reader must follow a procedure step by step, including its branches and loops.

Do not choose it when the reader must understand something other than the order of steps:

| The reader must understand | Choose instead |
|---|---|
| The states of one thing and the events that move it between them | State diagram |
| Messages exchanged between participants over time | Sequence diagram |
| Structure, such as data, classes, or components | ER, class, or component diagram |
| Dates and durations | Gantt chart or timeline |

## Correctness

| ID | Rule | Tag |
|---|---|---|
| COR-1 | Draw a branch only where the source states a condition. Draw an exit only for an outcome the source routes, and label it with the source's condition. Never infer where an outcome goes from sentence order; list an outcome the source does not route as not stated | [Convention] |
| COR-2 | Draw a loop only where the source states a repetition. It leaves through a decision whose exit is the condition the source states; if the source states none, list the exit condition as not stated | [Convention] |
| COR-3 | Draw every condition the source states with an outcome, as a decision. If the source does not say where in the flow it is tested, place it where the layout needs and list the placement as an assumption | [Convention] |

## Conformance

Use these symbols only for the meaning given:

| Meaning | ISO 5807 symbol | Mermaid |
|---|---|---|
| Entry from or exit to outside the procedure, such as its start or end | Terminator | `([text])` |
| An operation | Process | `[text]` |
| A named procedure defined elsewhere | Predefined process | `[[text]]` |
| A test that selects one of its exits | Decision | `{text}` |
| Data the procedure takes in or puts out | Data | `[/text/]` |
| The flow from one symbol to the next | Flowline | `-->`, so every flowline carries an arrowhead |

| ID | Rule | Tag |
|---|---|---|
| CON-1 | Use each symbol only for its meaning in the table. A state is not an operation, so never draw one as a process | [Standard: ISO 5807] |
| CON-2 | Exactly one exit of a decision is taken, so its exit conditions never overlap | [Standard: ISO 5807] |
| CON-3 | Every exit of a symbol with more than one exit carries the condition for its path | [Standard: ISO 5807] |
| CON-4 | The flow runs top to bottom or left to right, declared as `flowchart TB` or `flowchart LR`, and a flowline against that direction carries an arrowhead | [Standard: ISO 5807] |
| CON-5 | For any other ISO 5807 symbol, such as document or parallel mode, use the Mermaid shape documented for it. If Mermaid has none, as for the connector, draw the closest shape, name the substitution, and state that the diagram claims no ISO 5807 conformance | [Convention] |

## Clarity

| ID | Rule | Tag |
|---|---|---|
| CLA-1 | Branch only at a decision. Every other symbol has at most one exit, because several exits from a process read both as a choice and as parallel steps | [Convention] |
| CLA-2 | The text in a symbol is the minimum that names its function | [Standard: ISO 5807] |

## Validation

Check the finished diagram:

- Every node is a symbol from the Conformance table used for its meaning, or a substitution the output states (CON-1, CON-5)
- Every exit of a node with more than one exit carries a condition from the source, and only decisions have more than one exit (COR-1, CON-3, CLA-1)
- No two exits of a decision can both hold (CON-2)
- Every loop leaves through a decision (COR-2)
- Every condition the source states with an outcome is drawn as a decision (COR-3)
- The diagram declares `TB` or `LR`, and every flowline is `-->` (CON-1, CON-4)
- Every outcome the source does not route is listed as not stated, not drawn as an edge (COR-1, COR-2)
