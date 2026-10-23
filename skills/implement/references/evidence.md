# Evidence

What counts as evidence that an acceptance criterion holds.
implement's Phase 6.9 applies it.
Other skills and agents reference this file by path instead of restating it.

## 1. Classify the Criterion

| Kind | The criterion names |
|---|---|
| Behavior | Something a user or caller can observe: outputs, side effects, accepted or rejected inputs, errors, persisted state, or the instructions an agent follows |
| Structure or content | What an artifact contains or how it is laid out: a file at a path, a rule a section states, a field order, a configuration value |

For an agent instruction file, a criterion only about what the agent does is behavior, and one only about what the file states or how it is laid out is structure or content.
A criterion that reads both ways, for any kind of file, is a behavior criterion.

## 2. Evidence Kinds

| Tag | Evidence | Settles |
|---|---|---|
| `[behavior]` | You exercised the behavior through the interface the criterion names, the way its users or callers actually use it, and observed the outcome the criterion names. Run the CLI, script, endpoint, or job. For an agent instruction file, run the changed procedure on a concrete input as section 2.3 says | Any criterion |
| `[static]` | A `file:line` or `file:start-end`, read on the final state, that settles the whole criterion. When the criterion names a section, the range includes its heading. Whoever cites or judges it reads those lines first, and an edit to the cited file after the citation voids it | A structure or content criterion only |

### 2.1 Every `[behavior]` Run

| Rule | Requirement |
|---|---|
| Final state | It comes from a fresh run on the final state of the change. An edit to anything the run depends on, made after it, voids it until it is run again. A hook or formatter that rewrites a file at commit time is such an edit |
| This change | It runs what the worktree builds, never an installed copy: `go run ./cmd/greet` or a binary built from the worktree, not `greet` found on `PATH`. The record names what ran |
| Reproducible | Its record lets someone else run it again under the same conditions. Prefer a test or script the change already needs, so its command is the record. When no deterministic check exists, as for an agent instruction file, record the exact input: the procedure's file path and the concrete input. Keep the input on the line when it is short. Otherwise keep it in the Phase 6.9 output and the PR body in normal mode, or in `SUMMARY` in autonomous mode. Never add a file only to hold it |
| Untouched worktree | No run or observation changes the worktree's source. Never stash, reset, check out, or edit it to make one. Build and cache output that running a check writes is allowed |
| No outside effects | No run pushes, publishes, or changes state outside the worktree, such as a GitHub Issue or comment, a shared database, or a deployed service. Show such an outcome against a fake, a local sandbox, or a dry run whose output names the effect it would have. A criterion that only the real effect can show is `No evidence` |
| Named check | When the criterion itself is that a named check passes, such as "`claude plugin validate .` passes", a fresh run of that check is its `[behavior]` evidence, and section 2.2 does not apply |

### 2.2 Tests

A test counts as `[behavior]` evidence only when all of these hold.
A direct run of a command or procedure needs none of them.

- It drives the interface the criterion names and asserts the outcome the criterion names. A criterion naming a command needs a test that runs the command; a test of an internal function settles only a criterion about that function.
- It was seen to fail. For new or changed behavior, it failed at its assertion against the code without the change, not with a build, import, or setup error. When the interface it calls does not exist there, it failed at its assertion against that code plus only a minimal stub of the interface. For behavior the change must preserve, it passed against the code without the change and on the final state, and a test the change adds for it also failed at its assertion with that behavior deliberately broken.
- The observation is of the test exactly as it is on the final state. An edit to the test, or to the fixtures and helpers it uses, made after the observation voids it. An edit to the code under test does not, since that is the change itself.

The observation can come from a Phase 5 run, or from a script that runs the test against the code without the change, when its recorded output shows the test failing at its assertion. A `scripts/gate-tests.sh` before-change pass never counts: it reports every failure its `build_failure` pattern does not match as failing on the parent, so a panic, timeout, missing fixture, or unrecognized setup error also passes it, and it keeps no output of that failure. Otherwise make the observation yourself, outside the worktree:

| Observation | How |
|---|---|
| The code without the change | Export the merge-base with the default branch into a temporary directory with `git archive`. Copy in only the test and the fixtures and helpers it uses, plus a minimal stub when needed, and run it there |
| A deliberate break | Copy the files that `git ls-files -co --exclude-standard` lists and that still exist into a temporary directory, never `.git`. Break the behavior there by editing files, never with a git command, and run the test there |

In either directory, install dependencies or run the repository's setup first when the test needs them, so that a missing dependency is never mistaken for the failure.

Record the command and result of each observation. These recorded observations are the only earlier runs that count; the run on the final state must still be fresh.

### 2.3 Agent Instruction Files

The context that wrote a procedure already knows the intended answer, so run it in a fresh context.

- Give the fresh context the absolute path of the changed file in the worktree, tell it to read and follow that file, and give it the concrete input. Never give it the criterion or the expected outcome. Never invoke the procedure by its installed name, and never start the prompt with the input when the input is a slash command, because either runs the installed copy, not the change. Quote such an input inside the prompt as data.
- Tell it never to edit the worktree, commit, push, or publish anything, such as a pull request, an Issue, or a comment, and to stop before any such step and report the exact step it would take. This guard is not knowledge of the answer.
- When the procedure can take such a step, start the fresh context as a new harness session in its harness's read-only mode, such as `claude -p --permission-mode plan "<prompt>"` or `codex exec --sandbox read-only "<prompt>"`, never as a subagent that inherits write permissions. Without a read-only mode, such a criterion is `No evidence`. Otherwise a subagent will do.
- Fingerprint the worktree before and after the run: `git rev-parse HEAD`, `git status --porcelain --untracked-files=all`, `git diff HEAD`, and the hash of each untracked file, as `scripts/self-review.sh` does. If the fingerprint changed, the run is not evidence. Leave the worktree as it is and undo nothing: in autonomous mode return FAILED naming the changed paths, and in normal mode stop and ask the user.

The reported step is the observed outcome.
It settles a criterion about what the procedure does, such as the command it runs.
A criterion about the state the step leaves, such as a pull request that exists on GitHub, is `No evidence`.

### 2.4 Every Observation

- Record the command or input and the observed result, summarized. Evidence can be published on GitHub, so never paste a token, credential, or environment value.
- When an observation surprises you, by failing or by passing where it should fail, suspect the observation first: a stale build, a cached result, the wrong directory, commit, binary, file, or target. Conclude about the system only after the method checks out.

## 3. Never Evidence

- A check run cited for a criterion that does not name that check, such as `make ci -> exit 0` or `go test ./... -> exit 0` for a criterion about a feature. It shows that nothing broke, not that the behavior exists. Report it as a check, under `CHECKS` in autonomous mode.
- For a behavior criterion: a file path, a `file:line`, or reading the code.
- A replayed result instead of a run on the final state: a cached test result such as Go's `(cached)`, a remote cache hit, or an earlier run's output.
- A run or observation that broke any rule in section 2.
- A commit message, a code comment, or another agent's account of its own work, such as a worker's `CRITERIA`. Each is a lead to check. A fresh-context run under section 2.3 is an observation, not such an account.
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
Any line this file puts into a report field, including a criterion in `SKIPPED` and an input in `SUMMARY`, that would start with capital letters or underscores followed by a colon, such as `ERROR:` or `HEAD_SHA:`, starts with `> ` instead, because the report parser reads such a line as a new field.

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
| `greet` rejects an empty name | Behavior | Ran the installed `greet --name ""` | `... -> none` |
| `greet` rejects an empty name | Behavior | Ran `go run ./cmd/greet --name ""` on the final state | `... -> [behavior] go run ./cmd/greet --name ""; observed exit 2, "name is empty"` |
| `/greet-skill` asks for a name when none is given | Behavior | A fresh context followed the worktree's `skills/greet/SKILL.md` on the input `/greet-skill` | `... -> [behavior] skills/greet/SKILL.md, input "/greet-skill"; observed it asked for a name` |
| `claude plugin validate .` passes | Behavior | Ran it on the final state | `... -> [behavior] claude plugin validate .; observed exit 0` |
| The usage section documents `--name` | Content | `README.md:18` | `... -> [static] README.md:18` |
