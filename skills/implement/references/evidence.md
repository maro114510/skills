# Evidence

What counts as evidence that an acceptance criterion holds.
implement's Phase 6.9 applies it.
Other skills and agents reference this file by path instead of restating it.

## 1. Classify the Criterion

| Kind | The criterion names |
|---|---|
| Behavior | Something a user or caller can observe: outputs, side effects, accepted or rejected inputs, errors, persisted state, or the instructions an agent follows |
| Structure or content | What an artifact contains or how it is laid out: a file at a path, a rule a section states, a field order, a configuration value |

For an agent instruction file, a criterion about what the agent does is behavior, and one about what the file states or how it is laid out is structure or content.
Any other criterion that reads both ways is a behavior criterion.

## 2. Evidence Kinds

| Tag | Evidence | Settles |
|---|---|---|
| `[behavior]` | You exercised the behavior through the interface its users or callers actually use, and observed the outcome the criterion names. Run the CLI, script, endpoint, or job. For an agent instruction file, run the changed procedure on a concrete input | Any criterion |
| `[static]` | A `file:line`, or `file:start-end` when one line cannot show it, that settles the criterion by reading it | A structure or content criterion only |

- A named test is `[behavior]` evidence only when it drives that same interface and asserts that outcome. Cite the command that runs only that test, its exit code, and what it asserts.
- Record the command or input and the observed result, summarized. Evidence can be published on GitHub, so never paste a token, credential, or environment value.

## 3. Never Evidence

- A fully green CI run or check set, such as `make ci -> exit 0` or `go test ./... -> exit 0`. It shows that nothing broke, not that the behavior exists. Report it under `CHECKS`.
- For a behavior criterion: a file path, a `file:line`, or reading the code.
- A commit message, a code comment, or another agent's report. Each is a lead to check.
- A TODO, a new Issue, out of scope, future work, or a later Epic.
- A user decision. It can justify deferring a criterion, which is reported as deferred, never as met.

## 4. Classify the Outcome

| Outcome | When |
|---|---|
| Evidenced | The criterion carries evidence whose tag settles its kind |
| `No evidence` | Anything else, including evidence from section 3 or `[static]` evidence for a behavior criterion |

A `No evidence` criterion is unsatisfied.

## 5. Report Lines

Each criterion takes one line, quoted verbatim or prefixed `(derived)`.
In autonomous mode these lines are the `CRITERIA` field.

```
<criterion> -> [behavior] <command or input>; observed <result>
<criterion> -> [static] <file:line>
<criterion> -> none
```

| Criterion | Kind | Attached | Line |
|---|---|---|---|
| `greet` rejects an empty name | Behavior | `make ci -> exit 0` | `... -> none` |
| `greet` rejects an empty name | Behavior | `cmd/greet.go:42`, the empty-name check | `... -> none` |
| `greet` rejects an empty name | Behavior | Ran `greet --name ""` | `... -> [behavior] greet --name ""; observed exit 2, "name is empty"` |
| The usage section documents `--name` | Content | `README.md:18` | `... -> [static] README.md:18` |
