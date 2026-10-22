# orchestrate-epic v2 Contract

The normative contract that `oe` and the candidate prose implement. Epic #277 decisions D1 to D7 apply throughout.

## 1. Authority

- A behavior change lands in the same PR as the edit to this file that allows it.
- There is no JSON Schema. Go types and fixtures in `oe/` are the schema; this file fixes names, meanings, and invariants.
- Each recovery case in §8 becomes a named test in the Issue beside it. There is no separate crash-matrix document.
- `rule-inventory.tsv` traces every current rule to its v2 disposition. CI runs `tests/check-rule-inventory.sh`. An Issue that takes over a row fills its owner. The inventory becomes `complete` in #292.
- The current skill stays on v1 until the cutover in #293.

## 2. Terms

| Term | Meaning |
|---|---|
| `ME` | The login `gh api user` returns; it authors every loop comment |
| Loop comment | A comment by `ME` that starts with a v2 marker |
| Trusted comment | Author association `OWNER`, `MEMBER`, or `COLLABORATOR`, and a body that starts with neither `<!--` nor `orchestrate-epic` |
| Strict command | A trusted comment whose every non-blank trimmed line is the same one of the seven `epic-*` commands, in lowercase. Anything else is context |
| Comment ID | GitHub's numeric `databaseId`. Every window and ordering compares IDs, never timestamps |
| Full read | Every page read, no GraphQL errors beside data, no connection at its node limit. Anything less is partial |

Trust guards against model mistakes, not forgery: a human and the loop share one identity.

## 3. Comment Format

Every loop comment starts with `<!-- oe:v2 <kind> <key> -->`.

| Kind | Body | Written |
|---|---|---|
| `state` | One fenced `json` object | Edited in place by its single writer |
| `note` | Japanese prose from the templates | Posted once per key, never edited |

Every state object carries `protocol_version: 2`, `entity`, `key`, `revision`, and `updated_by`, the writer's lease token. `revision` grows with every write.

`oe` exits 6 and writes nothing when it finds any of these:

- a loop comment with a v1 marker: a body starting `<!-- orchestrate-epic` or `orchestrate-epic:`, or `orchestrate-epic ` followed by `state:`, `ledger:`, `post-merge:`, or `Q&A:`
- a protocol version other than the integer 2
- JSON that fails to parse, has an unknown or missing field, or has a key that differs from its marker
- two state comments by `ME` with one key

A marker on anyone else's comment is ignored. `oe` never deletes a comment; a human resolves duplicates and v1 leftovers.

## 4. Entities

| Entity | Key | Lives on | Single writer | Issue |
|---|---|---|---|---|
| Lease | `lease` | Epic comment | coordination | #285 |
| Ledger | `ledger` | Epic comment | coordination | #285 |
| Post-merge record | `post-merge` | Epic comment | landing | #290 |
| Issue state | `issue:<n>` | Child Issue comment | coordination, through §5 only | #285 |
| Notes | §7 | Epic or child Issue | the comment writer | #285 |
| Push and PR | branch, PR | GitHub | `oe ship publish` only | #289 |
| Merge | PR | GitHub | `oe land merge` only | #290 |
| Labels | none | never | never read or written | #282 |

Branches, PRs, and Issue state are read, never inferred. The worktree is never a source of truth.

### 4.1 Lease

Fields: `token`, `host`, `pid`, `started_at`, `renewed_at`.

| Situation | Result |
|---|---|
| Host-wide lock `${XDG_STATE_HOME:-$HOME/.local/state}/oe/locks/<owner>-<repo>-<epic>.lock` held by another process | Exit 7 |
| No lease, or `pid` 0 | Write a lease with a fresh token |
| Held by another token | Exit 7 |
| Held from this host by a `pid` that is not running | Reclaim; the holder is provably dead |
| Held from another host, however old | Exit 7; a human deletes it |
| Own token gone before a mutating command | Exit 7; never re-acquire mid-session |
| Clean session end | Set `pid` to 0 |

Renew `renewed_at` at most once a minute. This detects a second Publisher; it is not a distributed lock.

### 4.2 Ledger

Fields: `n`, `counters`, `freeze`, `freeze_seq`, `release_watermark`.

- `counters` holds `used` and `bound` for `worker_dispatches`, `reviewer_passes`, and `fix_cycles`, bounded 5n, 4n, and 2n.
- `n` counts dispatchable Issues not done at creation or release, at least 1. Bounds change only on release.
- `freeze` is null or `{seq, reason, merge_sha, health, released}`, and `released` is required. A freeze holds the Epic while `released` is false. `epic-release` sets it true and keeps the record: health reads the retained `merge_sha` and `health` as history, so the same result reads `HANDLED`, whereas clearing `freeze` would freeze the Epic again on the result it was released from. A later freeze replaces the record with a new `seq` and `released` false. Nothing is inferred from `release_watermark` or the notes, which only decide which `epic-release` comment is consumed.
- The freeze write comes first, then the note `freeze:<seq>`. Any read of a frozen ledger posts a missing note before reading a release.

### 4.3 Post-merge Record

Fields: `pr`, `issue`, `reviewed_sha`, `verified_base`, `phase`, `merge_sha`, `requested_at`.

`phase` is one of `intent`, `merged`, `merged-unverified-base`, `head-moved`, `rejected`, `unknown`, `not-merged`.

### 4.4 Issue State

| Field | Meaning |
|---|---|
| `branch` | `feat/issue-<n>`, or the branch an applied redo chose |
| `cycle` | 0 to 2; fix cycles since the last retry or redo |
| `consecutive_failures` | 0 or 1; a second FAILED parks |
| `head_sha` | The last recorded head, or null |
| `approval` | Null, or `reviewed_sha`, `verified_base`, and `review_evidence` as one value |
| `review_evidence` | `behavior_change`, `basis`, and criteria with text, result, kind, and evidence |
| `pending_findings` | Findings handed to the fix cycle in flight |
| `unresolved_blockers` | What parked the Issue |
| `decision` | Null, or the latest applied command, its comment ID, and a redo branch |
| `signal_watermark` | Comment ID; everything at or below it is consumed |
| `context` | Retained human comments: ID, author, time, digest, kind |
| `publish` | Null, or `sha`, `prev_sha`, `base`, `branch`, `pr`, `phase`; `prev_sha` is the remote head when the intent was recorded |
| `repair` | Null, or `pr`, `head`, `since` of the last repair |

## 5. Transitions

Each transition writes the whole object after a full read. The writer exits 7 if `revision` moved since that read.

| Transition | Requires | Effect |
|---|---|---|
| `start` | No state | Creates it: `cycle` 0, no head, no approval, watermark at the highest comment ID read |
| `record_worker_result` | A report whose Issue, branch, and worktree match | DONE sets `head_sha`, resets failures, clears approval. BLOCKED needs its question note first. FAILED adds a failure; a second parks |
| `record_head` | `oe`'s own integration merge, or a sync to the PR head | Sets `head_sha`, clears approval |
| `begin_fix` | `cycle` below 2, a confirmed ledger reservation, findings | Sets pending findings, `cycle` plus 1, clears approval; a repair also sets `repair` |
| `bind_approval` | Pins unchanged, evidence validated and scanned, no open finding | Sets approval; `head_sha` equals `reviewed_sha`; empties both lists |
| `invalidate_approval` | Approval set | Clears approval |
| `park` | Blockers | Sets blockers, empties pending findings, clears approval |
| `apply_signals` | A full read of the window, §6 | Advances the watermark, appends context, applies the decision |
| `record_publish_intent` | Approval bound; `sha` and `base` equal the pair; any earlier publish is `linked` or null | New intent with `prev_sha`, keeping an earlier `pr`. A repaired head re-publishes this way |
| `record_published` | Publish `intent` or `pushed` | Moves to `pushed`, then `linked` with `pr` |

| Decision | Applies to | Effect |
|---|---|---|
| `epic-retry` | Parked | `cycle` 0, both lists emptied, approval cleared |
| `epic-redo` | Parked or rejected | As retry, plus the next free `feat/issue-<n>-<k>`, and head, publish, and repair cleared |
| `epic-drop` | Parked or rejected | Recorded; blockers kept |
| Anything else | — | Consumed as context or ignored, never applied later |

The ledger has `create`, `reserve`, `freeze`, and `release`. The post-merge record has `record_intent` and `record_result`.

### 5.1 Forbidden Combinations

The Go types make these unrepresentable, or the writer rejects them before any request:

1. Part of the approval triple without the rest
2. Approval with pending findings or blockers
3. `reviewed_sha` different from `head_sha`
4. Evidence with no criterion, an unverified criterion, or a behavior change without behavior evidence
5. Pending findings and blockers at once
6. `cycle` above 2, or `begin_fix` at 2
7. A redo branch that already has a merged or closed PR
8. Publish in `intent` or `pushed` without approval, or with `sha` other than `reviewed_sha`. A `linked` publish is history, not permission
9. A watermark lower than the one it replaces
10. Ledger `used` above `bound`, a reservation while frozen, or a second freeze
11. A post-merge `record_intent` while the record is `intent` or `unknown`; §8 reconciles those first
12. Any label read or written

## 6. Signal Watermark

| Signal | Kind | Window | Winner |
|---|---|---|---|
| retry, redo, drop, answers, context on a child Issue | Consumed once | IDs above `signal_watermark` | Highest ID |
| `epic-release` | Consumed once | IDs above `release_watermark` and the freeze note | Lowest ID |
| approve, auto-merge, revoke on the Epic | Never consumed; read fresh at each gate | IDs above the Run Plan note | Highest ID of grant or revoke |

- Only a full read is applied. A partial read writes nothing and exits 1.
- The watermark moves to the highest ID read, trusted or not, in the same write that applies the window. A comment posted after the read stays in the next window, and a failed write consumes nothing. This closes `SignalWindowRace`.
- A comment counts with the body it has when its window is read. Later edits change nothing and never re-enter a window.
- A comment deleted before its window is read never existed. A later deletion undoes nothing.
- Every trusted non-command comment joins `context` with a sha256 digest. It is an `answer` when a BLOCKED question is open, else `context`.
- `context` is never pruned, even across retry and redo, so a brief carries it after the watermark passes. This closes `HumanAnswerDelivery`.
- A brief re-fetches each body by ID. A changed digest is passed as edited after reading; a deleted body is listed as deleted.
- An append that would exceed GitHub's comment size limit exits 8 and consumes nothing.
- Untrusted comments never reach `context` or a brief.

## 7. Notes and Dedup Keys

The comment writer, for every loop comment:

1. Scan the text; on a finding exit 8 and post nothing
2. Check the lease
3. Look the key up among `ME`'s comments with a full read; if found, do nothing
4. Post

A digest is the first 12 hex characters of a sha256.

| Note | On | Key |
|---|---|---|
| Run Plan | Epic | `run-plan` |
| Dependency cycle | Epic | `dep-cycle:<sorted issues>` |
| Leftover token | Epic or container | `leftover-token:<issue>:<digest>` |
| Freeze | Epic | `freeze:<seq>` |
| Completion | Epic | `completion` |
| Dispatch started | Issue | `start:<n>:<branch>` |
| Stale start | Issue | `stale-start:<n>:<branch>` |
| Blocked question | Issue | `blocked:<n>:<head>:<digest>` |
| Answered Q&A | Issue | `qa:<n>:<digest>` |
| Report record of skips and decisions | Issue | `report:<n>:<head>:<digest>` |
| Ship-class question | Issue | `ship-class:<n>:<kind>:<digest>` |
| Parked | Issue | `parked:<n>:<cause>:<digest>` |
| Rejected escalation | Issue | `rejected:<n>:<highest closed PR>` |
| Merged PR, Issue open | Issue | `merged-open:<n>:<pr>` |
| Stale verdict | Issue | `stale:<n>:<pr head>:<base>` |
| External push | Issue | `external-push:<n>:<remote sha>` |
| PR link failed | Issue | `link-failed:<n>:<pr>` |
| Repair handed over | Issue | `repair:<pr>:<head>:<since>` |
| Merge hold | Issue | `merge-hold:<pr>:<head>:<digest>` |
| Merge result | Issue | `merge-result:<pr>:<reviewed_sha>:<result>` |

Duplicate notes are harmless and never deleted. Duplicate states exit 6.

## 8. Irreversible Operations

| Operation | Before | Recovery | Never | Test in |
|---|---|---|---|---|
| Note post | §7 | Re-read by key: present is done, absent posts again | Post without the lookup | #285 |
| State create | Full read, no state | Re-read by key: one is done, two exit 6 | A second state for a key | #285 |
| State edit | Full read, same `revision` | Re-read: intended object stored is done, else redo from fresh state | A partial object | #285 |
| Reserve, then spawn | Freeze `CLEAR`, reservation fits | A write that may have landed counts as landed; a failed write spawns nothing | Spawn before the write is confirmed | #285 |
| Push | Final freeze, base, and HEAD gates, then the intent | Remote equals `sha`: pushed. Equals `prev_sha`, or absent with none recorded: re-gate and push. Anything else: stop. A remote branch with no intent ever: external push note | Force-push, or any SHA but `sha` | #289 `PushToPRResume` |
| PR create | Publish `pushed`, then fresh freeze, base, and HEAD gates, also on resume | List PRs by head in any state: link an open one, route a closed unmerged one to rejected, else create | A second PR for a branch | #289 `PushToPRResume` |
| PR link | Open PR exists | Idempotent; a failure posts `link-failed` and the round goes on | Stop the round for it | #289 |
| Merge request | Health proceeds, grant read fresh, `READY` on `reviewed_sha`, freeze `CLEAR`, base re-read equals `verified_base`, then `record_intent` | A record at `intent` or `unknown` is reconciled from the PR first, now or next invocation. Merged with first parent `verified_base` is `merged`. Merged with any other or an unreadable first parent is `merged-unverified-base`, and the ledger freeze is written before the result note or any further merge. Not merged is `not-merged`. An unreadable PR stays `unknown` and stops landing | Blind retry, `gh pr merge`, `--admin`, rebase, revert | #290 |
| Merge result | Request answered or reconciled | Result note, then `record_result`; either failing stops every further merge | Merge again before both | #290 |
| Freeze | Ledger `CLEAR` | Ledger write, then note `freeze:<seq>`; a missing note is posted on the next read | Notify twice | #285 |

Local steps follow the same rule. The integration merge runs without hooks, signing, or editor, and a leftover `MERGE_HEAD` is aborted and redone, in #288. Worktrees come from a pinned ref without touching the shared checkout, in #287.

## 9. Exit Codes

Every `oe` subcommand prints one JSON payload or one verdict line.

| Code | Meaning | Writes |
|---|---|---|
| 0 | Done or proceed | As defined |
| 1 | Unreadable: failed, partial, or rate-limited read | None |
| 2 | Usage error | None |
| 3 | Stale: head or base moved since the verdict | None |
| 4 | Stop: frozen, health failed or unreadable, unrecordable merge result, unknown merge outcome | Only the freeze or record that caused it |
| 5 | Wait: checks or health pending | None |
| 6 | Protocol: v1 marker, unknown version, bad JSON, key mismatch, duplicate state | None |
| 7 | Coordination: lock held, foreign or lost lease, moved revision | None |
| 8 | Refused: no approval or grant, scan finding, incomplete brief, failed precondition, oversized write, old gh, host without sub-issues or blocked-by | None |

## 10. Critical Rules

`tests/check-rule-inventory.bats` fails if any of these stops being `kept`.

| Rule | ID |
|---|---|
| Only trusted strict commands are signals | GL-03 |
| Merge with `reviewed_sha` as the expected SHA | MQ-01 |
| Always a fresh worker | GL-14 |
| The reviewer never sees the worker report | RV-09 |
| Freeze check before every merge | FZ-01 |
| No ship-class decision by timeout | GL-21 |
| Approval binds head, base, and evidence | GL-17 |
| One merge at a time | LO-02 |
| Never revert | PH-05 |
| No label read or written | GL-01 |

## 11. Retired Rules

| ID | Retired | Reason |
|---|---|---|
| R1 | Epic-body Mermaid fallback parser | YAGNI. `oe` refuses a host without sub-issues or blocked-by |
| R2 | `git wt` dependency | YAGNI. Plain `git worktree add` from a pinned ref |
| R3 | 30-minute foreign start-comment check | YAGNI. The lease replaces it |
| R4 | Dirty-checkout entry gate | YAGNI. The loop no longer switches or pulls the shared checkout |
| R5 | Rate-limit backoff and retry-once | YAGNI. A failed read exits 1 |
| R6 | CI-failure-attribution metric | YAGNI |
| R7 | Wall-clock metric | YAGNI |
| R8 | First-pass-APPROVE-rate metric | YAGNI |
| R9 | Publisher fallback commit | D4. The model never commits |
| R10 | Line-format state, ledger, and freeze comments | D2. Fenced JSON replaces them |
| R11 | `yq` fast path and reading workflows by eye | Epic defect. Go derives CHECKS_SET from an ordered YAML tree |
| R12 | v1 compatibility paths | D2. No backward compatibility |
| R13 | `commands.md` bash procedures | Removed at cutover; `oe` replaces them |

## 12. Inputs and Snapshot Mode

`oe` lives at `oe/`, built with `CGO_ENABLED=0`. Dependencies are not vendored: users run release binaries (#281) and never build, so `go.sum` and `go mod verify` guard dependency integrity, and CI checks `go.mod` and `go.sum` stay tidy. It runs only `gh` and `git`, always as an argv array, never through a shell; `oe checks run` is the sole exception and is described below. Global flags: `--epic <number|url>`, `--repo <owner/name>`, `--max-parallel <n>`, `--snapshot <file>`.

Every subcommand that needs the run inputs resolves them one way, in this order, before any write:

| Step | Rule | On failure |
|---|---|---|
| Arguments | Checked before any call. `--epic` is required and never guessed; an Epic URL names the repository, and a disagreeing `--repo` is an error | Exit 2 |
| `max-parallel` | Anything but a positive integer falls back to 3, and the reason is printed | Never fails |
| `gh --version` | At least 2.40.0 | Exit 8 |
| `gh auth status --hostname github.com` | Must succeed | Exit 8 |
| `gh api user` | Gives `ME` | Exit 1 |
| Repository | `--repo`, else the Epic URL, else `git remote get-url origin` on github.com | Unreadable origin exit 1; another host exit 8 |
| One GraphQL probe | The default branch, the Epic, and `subIssues` and `blockedBy` on the schema | Undefined `subIssues` or `blockedBy` exit 8; any other error, data beside errors included, exit 1 |

- A rate limit is reported as `rate limited` and exits 1, with no backoff.
- Any failed or partial read leaves the gh client unable to write: a later write exits 1 even if the caller ignored the read error.
- Every `gh api` call carries `--hostname github.com`, and a call naming another host exits 8. Child processes never inherit `GH_HOST` or `GH_REPO`; `GH_HOST` is set to `github.com`.
- A read cannot write: a `gh api` read that is not a GET, and a GraphQL read that is not a query, exit 8 before any call.
- `--snapshot` with an empty value exits 2; it never falls back to real calls.
- `--snapshot <file>` replays recorded `{argv, stdout, stderr, exit_code}` calls and never starts a process. A call missing from the file exits 1. Read-only subcommands give identical output on every run over one file.
- `oe checks derive` reads workflow files at the base and ref through `git`, and emits CHECKS_SET: every runnable and requires-runner entry in file, job, and step order. `oe checks run` executes each runnable entry with the captured shell, working directory, and env in its own process, and never executes a requires-runner entry; it reports the exit status and any worktree or index change. A set whose revision no longer matches the ref is refused as stale rather than run. Under `--snapshot`, `oe checks run` exits 8 before any call, because replaying a captured process is not possible.
- `oe ship publish` and `oe land merge` are the only subcommands that may push, open a PR, or merge. Under `--snapshot` they exit 8 before any call. `.claude/hooks/require-user-approval.sh` blocks both without the approval marker, whether they are run directly, by path, or through `skills/orchestrate-epic/scripts/oe`. The marker approves only the line it ends.

## 13. Classifiers

`oe board`, `oe readiness --pr <n>`, and `oe health` classify from one complete read and never write: every call is a GraphQL query, a GET, or a read-only git command. Each resolves the inputs as §12 does, then prints one JSON payload and exits 0, or prints one verdict line.

- A read is complete or it fails with exit 1. A connection cut off at its node limit, a next page with no cursor or that cannot be read, a count that does not add up, and a response with errors, data beside them included, all stop classification before anything is classified.
- Pull requests are read newest first back to the oldest creation time among the Epic and its Issues, because a pull request cannot be older than its Issue. A listing that stops short of that is truncated.
- The clock is GitHub's `Date` header, not the machine's, so a recorded snapshot replays to the same output.
- No query asks for a label. Local `feat/issue-*` branches are read only from a checkout whose origin is the repository read; a checkout that cannot be read is exit 1.

| Subcommand | Payload | Exit |
|---|---|---|
| `board` | Per Issue: state, reason, branch, PR. Per container: done and children. `frozen`, `health`, `actions`, `notifications`, and `lease` under `--observe` | 0 classified; 1 unreadable; 6 protocol; 7 a lease held by another token (`--lease-token` names this session's) |
| `readiness` | `status`, `reason`, `pr`, `head`, `next`, `repair` | 0 classified, whatever the status; 1 a signal could not be read, which is always BLOCKED with next `human` |
| `health` | `status`, `reason`, `record_id`, `pr`, `issue`, `merge`, `next` | 0 classified; 1 a signal could not be read, so every merge is held |

- A container is derived from its sub-issues and never classified or dispatched. A dependency on it is done only when every sub-issue is done, and a dependency of the container itself is a dependency of each of its sub-issues.
- An open Issue in a dependency cycle is `waiting` unless it is `parked` or `rejected`, which wait on a person and keep their state and note. No dispatch, re-verification, or landing is proposed for it, and one `dep-cycle:<sorted issues>` note is proposed per cycle.
- A merged PR on the current branch of a still-open Issue is `parked` and proposes `merged-open:<n>:<pr>`, even when a newer PR is open; closed PRs only are `rejected`. PRs are matched to the branch the Issue state records, so an applied redo leaves the old branch behind. With no branch recorded, any `feat/issue-<n>` or `feat/issue-<n>-<slug>` branch or PR is the Issue's work, so work a person started by hand is never dispatched again.
- An Issue with no state proposes no `apply_signals`: only `start` creates state, §5, so a decision comment on a `rejected` or `parked` Issue that a person started by hand is not applied. Whether a decision may create state is #285's to settle; until then a person resolves such an Issue by closing it.
- A decision not applied to the state yet is `pending_decision` and proposes `apply_signals`. It takes effect only once the state records it, so a parked Issue stays parked until then.
- Proposed actions are `apply_signals`, `freeze`, `land`, `reverify`, and `dispatch`, with in-progress dispatched before ready. The worker cap `--max-parallel` is applied where work is dispatched (#291), not here. A frozen Epic, or a post-merge result that needs a freeze, proposes no work; a pending post-merge result proposes no `land`.
- `board --observe` is for a person reading the board while another session holds the lease. It skips the exit 7, names the holder in `lease`, and proposes no action and no note, so it cannot drive a second Publisher. Without a foreign lease it changes nothing.
- `health` takes `HANDLED` from the ledger's `freeze`: the same merge commit and the same status. A release keeps that freeze recorded with `released` true, see §4.2; #285 writes it.

## 14. Secret Scan

Everything the loop publishes passes `oe scan` first. Only a clean report lets it publish.

| Subcommand | Scans | Run before |
|---|---|---|
| `scan outgoing` | Each commit on HEAD that the base lacks, then uncommitted changes and untracked files that are not ignored | A push or a pull request |
| `scan text` | One text, such as a note, review evidence, a pull request title or body, a question, the Run Plan, or the completion comment | A post |

| Flag | Subcommand | Default |
|---|---|---|
| `--base` | `scan outgoing` | `origin/HEAD` |
| `--worktree` | `scan outgoing` | The current directory, widened to its top level |
| `--file` | `scan text` | stdin |
| `--source` | `scan text` | `stdin`, the label of the text in the report |

| Exit | Case | Output |
|---|---|---|
| 0 | Clean | JSON report |
| 8 | A finding | JSON report |
| 8 | `scan outgoing` under `--snapshot` | Verdict |
| 1 | The scan cannot finish | Verdict |
| 2 | A base that looks like an option | Verdict |

A finding names its location and never the matched value or line.

| Field | Content |
|---|---|
| `rule` | The rule that matched |
| `where` | `commit-content`, `commit-message`, `commit-path`, `worktree-content`, `worktree-path`, or `text` |
| `commit` | The commit, when it applies |
| `path` | The path, or `(withheld)` when the path matches a content rule |
| `line` | The line, when it applies |

The rules cover at least the commit skill's patterns and the earlier secret screen.

| Rule | Matches |
|---|---|
| `aws-access-key` | AKIA followed by 16 upper-case letters or digits |
| `private-key-header` | A PEM header that ends in PRIVATE KEY |
| `github-token` | A GitHub token prefix followed by 20 or more letters or digits |
| `sk-api-key` | `sk-` followed by 20 or more letters, digits, dashes, or underscores |
| `slack-token` | A Slack token prefix followed by a token character |
| `password-or-token-literal` | A literal assigned to a key ending in password, passwd, or token |
| `unscannable` | Binary content or a NUL byte |
| Path rules | A base name, in any case, that starts with `.env` or `id_rsa` or another SSH key name, contains `credentials` or `secret`, ends in `.pem`, `.key`, `.p12`, or `.pfx`, or is a service account JSON file |

| Assigned value | Literal when |
|---|---|
| Quoted | 8 or more characters that mix two classes among lower case, upper case, digits, and symbols |
| Bare | 16 or more characters with letters and digits |
| Placeholder, reference, or template | Never |

| Case | Result |
|---|---|
| A secret one commit adds and a later commit deletes | A finding, because each commit is scanned on its own |
| A merge | Only lines new against every parent |
| A failed git call, an unreadable object, or a patch that cannot be parsed | Exit 1 |
| A shallow boundary inside the range | Exit 1, because it can hide an outgoing commit |
| Replace objects and the index | Ignored and never written, so the scan reads what a push sends |
| An error message | Never carries git's output |
