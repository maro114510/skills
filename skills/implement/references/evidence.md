# Evidence

What counts as evidence that an acceptance criterion holds.
implement's Phase 6.9 applies it.
Other skills and agents reference this file by path instead of restating it.

## 1. Classify the Criterion

| Kind | The criterion names |
|---|---|
| Behavior | Something a user or caller can observe: outputs, side effects, accepted or rejected inputs, errors, persisted state, or the instructions an agent follows |
| Structure or content | What an artifact contains or how it is laid out: a file at a path, a rule a section states, a field order, a configuration value |

For an agent instruction file, a criterion about what the agent does is behavior, and one about what the file states or how it is laid out is structure or content. This rule decides before the next one.
Any other criterion that reads both ways is a behavior criterion.

## 2. Evidence Kinds

| Tag | Evidence | Settles |
|---|---|---|
| `[behavior]` | You exercised the behavior through the interface the criterion names, the way its users or callers actually use it, and observed the outcome the criterion names. Run the CLI, script, endpoint, or job. For an agent instruction file, run the changed procedure on a concrete input in a fresh context that knows only the file and the input, such as a subagent or, where subagents cannot nest, a new harness session started from the shell as Phase 6.5's script does, because the context that wrote it already knows the intended answer | Any criterion |
| `[static]` | A `file:line` or `file:start-end` that settles the criterion when read. Whoever cites or judges it reads those lines first | A structure or content criterion only |

`[behavior]` evidence must also meet all of these:

| Rule | Requirement |
|---|---|
| Final state | It comes from a run on the final state of the change. An edit to anything the run depends on, made after it, voids it until it is run again |
| Reproducible | Its record lets someone else run it again under the same conditions. Prefer a test or script the change commits, so its command is the record. When no deterministic check exists, as for an agent instruction file, record the exact input instead: the procedure's file path and the concrete input given to it, while the Final state rule pins the file's content to this change. Keep the input on the line when it is short, otherwise in a file the change commits |
| Seen to fail | A test counts only when it drives the interface the criterion names, asserts the outcome the criterion names, and was observed against the code without the change. A criterion naming a command needs a test that runs the command; a test of an internal function settles only a criterion about that function. For new or changed behavior, it failed there at its assertion, not with a build, import, or setup error. When the interface it calls does not exist without the change, it failed at its assertion against the code without the change plus only a minimal stub of that interface. For behavior the change must preserve, it passed there and on the final state, and a test the change adds for it also failed at its assertion with that behavior deliberately broken. Restore the code before the run on the final state |

- The "Seen to fail" observation can come from a Phase 5 run, such as a TDD Red run or a bug fix's reproduce or mutate step, or from a script that runs the test against the code without the change. When neither exists, make the observation yourself: export the base commit into a temporary directory with `git archive`, copy in only the test, and run it there. Never stash, reset, or check out over uncommitted work to make it. Record the command and result of every observation this rule uses, including a deliberate break. These recorded observations are the only earlier runs that count; the run on the final state must still be a fresh run.
- Record the command or input and the observed result, summarized. Evidence can be published on GitHub, so never paste a token, credential, or environment value.
- When an observation surprises you, by failing or by passing where it should fail, suspect the observation first: a stale build, a cached result, the wrong directory, commit, binary, or target. Conclude about the system only after the method checks out.

## 3. Never Evidence

- A fully green CI run or check set, such as `make ci -> exit 0` or `go test ./... -> exit 0`. It shows that nothing broke, not that the behavior exists. Report it as a check, under `CHECKS` in autonomous mode.
- For a behavior criterion: a file path, a `file:line`, or reading the code.
- A replayed result instead of a run on the final state: a cached test result such as Go's `(cached)`, a remote cache hit, or an earlier run's output.
- A run that broke a rule in section 2: on a superseded state, without a record that lets it be rerun, or a test never seen to fail.
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
| `greet` rejects an empty name | Behavior | `go test -run TestGreetEmptyName ./cmd`, which runs the `greet` command, passes, never run without the change | `... -> none` |
| `greet` rejects an empty name | Behavior | Same test, failed at its assertion without the change, passes on the final state | `... -> [behavior] go test -count=1 -run TestGreetEmptyName ./cmd; observed fail at the exit-code assertion without the change, exit 0 on the final state` |
| `greet` rejects an empty name | Behavior | Ran `greet --name ""` on the final state | `... -> [behavior] greet --name ""; observed exit 2, "name is empty"` |
| `/greet-skill` asks for a name when none is given | Behavior | Ran the changed skill on the input `/greet-skill` | `... -> [behavior] skills/greet/SKILL.md, input "/greet-skill"; observed it asked for a name` |
| The usage section documents `--name` | Content | `README.md:18` | `... -> [static] README.md:18` |
