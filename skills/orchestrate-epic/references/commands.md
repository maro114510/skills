# Command Reference

Read only the section for the step you are on. Commands run from the main checkout unless `git -C` targets a worktree.
`REPO` is `owner/repo`; `EPIC` is the Epic Issue number.

## §1 Load State — Step 2

Three `gh` calls, whatever the child count. Never loop `gh issue view` per child: that payload embeds every blocker's full title and URL, so both the call count and the response size scale with the Epic.

```bash
# 1. Epic, its Tn's states, one level of Tn.m grandchildren, and the leftover-token check —
#    all in one projection. `gh issue view --json subIssues` cannot do this: each subIssues
#    node it returns is a flat LinkedIssue (number/title/state/url) with no subIssues field of
#    its own, so a second nesting level is not reachable through that convenience flag. Raw
#    `gh api graphql` has no such limit — GraphQL resolves the whole two-level tree in one round
#    trip, so this stays a single call regardless of Epic size.
OWNER="${REPO%/*}"; REPO_NAME="${REPO#*/}"
gh api graphql \
  -f query='
    query($owner: String!, $repo: String!, $num: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $num) {
          number
          body
          subIssues(first: 100) {
            nodes {
              number
              state
              title
              subIssues(first: 100) {
                nodes { number state title }
              }
            }
          }
        }
      }
    }' \
  -f owner="$OWNER" -f repo="$REPO_NAME" -F num="$EPIC" \
  --jq '.data.repository.issue |
    {epic:.number, tokens:(.body|test("\\{\\{T[0-9]+(\\.[0-9]+)?\\}\\}")),
     children:[.subIssues.nodes[]|{n:.number,s:.state,t:.title,
       grandchildren:[.subIssues.nodes[]|{n:.number,s:.state,t:.title}]}]}'

# 2. Labels and dependency edges, open Tn AND open Tn.m grandchildren of any container Tn.
#    CONTAINERS is the set of Tn numbers from call 1 that have a non-empty grandchildren list.
EPIC="$EPIC" CONTAINERS="$CONTAINERS" gh issue list --repo "$REPO" --state open --limit 200 \
  --json number,labels,blockedBy,parent \
  --jq --argjson containers "${CONTAINERS:-[]}" \
  '[.[]|select(.parent.number == (env.EPIC|tonumber) or ([.parent.number] | inside($containers)))
        |{n:.number, l:[.labels[].name],
          b:[.blockedBy.nodes[]|select(.state=="OPEN")|.number]}]'

# 3. Every PR on a loop branch, keyed by Issue number
gh pr list --repo "$REPO" --state all --limit 200 \
  --json number,state,mergedAt,headRefName \
  --jq '[.[]|select(.headRefName|test("^feat/issue-[0-9]+(-|$)"))
        |{i:(.headRefName|capture("^feat/issue-(?<n>[0-9]+)").n|tonumber),
          p:.number, s:(if .mergedAt then "MERGED" else .state end), h:.headRefName}]'
```

`--jq` filters client-side, so only the projection reaches the context. `tokens: true` is the leftover-`{{Tn}}`/`{{Tn.m}}` signal Step 2 escalates on — it costs nothing, unlike carrying the Epic body. `CONTAINERS` is derived from call 1's output before call 2 runs, via `[.children[]|select(.grandchildren|length>0)|.n]` — a `Tn` with a non-empty `grandchildren` array in call 1 is a container; every other `Tn` is a leaf and is never expected to have children of its own. Step 2's depth cap in create-github-issues means a `Tn.m` never has grandchildren of its own, so this single extra nesting level is always enough — no recursion needed.

Calls 2 and 3 page the repository's issues and PRs before filtering, so `--limit` truncates silently on a busy repository. Cross-check call 2 against call 1's `Tn` and grandchild lists, flattened: if an open `Tn` or `Tn.m` is missing from call 2, the read is incomplete — raise the limit and re-run rather than classifying on a partial board. Do not apply the same reasoning to call 3: a local `feat/issue-<n>` branch with no row there is not itself evidence of a truncated page — an Issue can legitimately be `ready` or `in-progress` with a branch that has no PR yet, since Step 7 is what creates one.

Branch and worktree recovery stays local and free:

```bash
git fetch origin --prune
git branch --list "feat/issue-*"
git worktree list
```

PR state decoding: `OPEN` → awaiting-merge; `MERGED` → merged; `CLOSED` with `mergedAt: null` → rejected, escalate.

Fetch the Epic body itself, via `--jq .body`, only on the fallback path below, or when a leftover token needs to be shown to the user.

Fallback when `subIssues`/`blockedBy` are unavailable — older gh, GHES, or the GraphQL call itself errors: parse the Epic body's "Dependencies & Parallel Execution Plan" section — Mermaid edges `X --> Y` mean Y depends on X; the wave-table variant lists each row's `#<number>` dependencies — then fetch each `Tn`'s state individually. For a `Tn` that turned out to be a container, its own body carries the same kind of section for its `Tn.m` children — parse it the same way, one level down. Tell the user the run is on this fallback, since a hand-edited body can drift from the real relations.

## §1.5 Entry Gate — Step 3

```bash
# Once per run
gh label create "oe:go" --repo "$REPO" --color "0E8A16" --description "human approved the orchestrate-epic Run Plan" 2>/dev/null || true

# Resolve this run's own identity once — every marker lookup below trusts only a comment this identity
# posted, never merely one that starts with the right prefix. On a public repo anyone can comment
# "<!-- orchestrate-epic:run-plan -->..." to spoof a marker and suppress the real lifecycle comment,
# or get the state upsert to read and edit a comment they planted instead of the real state.
ME=$(gh api user --jq .login)

# Find the Run Plan comment — --paginate --slurp fetches every page (an Epic can carry more
# comments than one page holds), `add` flattens the resulting array-of-arrays before [-1] picks the latest
gh api "repos/$REPO/issues/$EPIC/comments" --paginate --slurp --jq --arg me "$ME" \
  'add | [.[]|select(.user.login==$me and (.body|startswith("<!-- orchestrate-epic:run-plan -->")))][-1] // empty'

# Post it (create only — never edit/replace an existing Run Plan)
gh issue comment "$EPIC" --repo "$REPO" --body "$RUN_PLAN_BODY"

# Check for oe:go
gh issue view "$EPIC" --repo "$REPO" --json labels --jq '[.labels[].name]|any(.=="oe:go")'

# Repository facts for the Run Plan. Only a confirmed 404 means "no protection configured" — every
# other failure (auth, permission, network, 5xx) must stop and be reported, never be read as "no protection"
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
HTTP_STATUS=$(gh api "repos/$REPO/branches/$BASE/protection" -i 2>/dev/null | head -1 | awk '{print $2}')
if [ "$HTTP_STATUS" = "404" ]; then
  echo "no protection configured"
elif [ "$HTTP_STATUS" != "200" ]; then
  # empty $HTTP_STATUS (gh api itself failed — network, auth) also lands here, since it's neither 404 nor 200
  echo "protection check failed (HTTP ${HTTP_STATUS:-no response}) — stop and report, do not assume no protection" >&2
  exit 1
fi
git ls-tree -r "origin/$BASE" --name-only -- .github/workflows

# Completion exit comment (Step 9) — marked the same way as the Run Plan, so a rerun after completion
# doesn't post a second one; $EXIT_COMMENT_BODY must start with <!-- orchestrate-epic:completion -->
gh api "repos/$REPO/issues/$EPIC/comments" --paginate --slurp --jq --arg me "$ME" \
  'add | [.[]|select(.user.login==$me and (.body|startswith("<!-- orchestrate-epic:completion -->")))][-1] // empty'
gh issue comment "$EPIC" --repo "$REPO" --body "$EXIT_COMMENT_BODY"   # only when the check above found none
```

## §1.6 Derive the Check Set — Step 3

Derived once per round, from `.github/workflows/` on the default branch — never from `package.json`/`Makefile` script names. The result, `CHECKS_SET`, is an ordered list of `{command, working_directory, runnable}` entries, reused as-is by Step 4's worker prompt, Step 6's reviewer, and Step 7's pre-push run. Recompute it fresh each round; do not carry it over from a prior round in case a workflow file changed.

**The rule, applied by hand or via the script below — get this exactly right, since it is the only thing standing between the loop and the next "nobody owned CI-equivalence" incident:**

1. List every file under `.github/workflows` on the default branch (`git ls-tree -r "origin/$BASE" --name-only -- .github/workflows`, `.yml`/`.yaml` only) and read each one's content from that same ref — never the local worktree copy, which can be mid-edit by a worker. `origin/$BASE` is already current at this point: Step 2 runs `git fetch origin --prune` every invocation, before Step 3 derives `CHECKS_SET`, per §1.
2. Keep a workflow only if its `on:` triggers include `pull_request` (any form), or `push` restricted to a `branches` list containing `$BASE`, or `push` with neither a `branches` nor a `tags` filter (fully unrestricted, so it fires on a push to the default branch too). Drop everything else — `push` restricted to `tags` only, `schedule`, `workflow_dispatch`-only — a workflow that never runs against a PR or a push to the default branch cannot be what "CI ran" means for a shipped branch. This filter is mandatory, not an optional narrowing: without it, `CHECKS_SET` picks up a tag-triggered release job or any other workflow irrelevant to a shipped branch, and the loop starts running things far more dangerous than a missing linter.
3. Within each kept workflow, walk every job in `jobs:` in file order, and every step in that job's `steps:` in order. For a step carrying a `run:` key, capture the run block **verbatim, one entry per step** — never merge two steps' commands into one entry, never split one step's multi-line block into several, never deduplicate two entries with identical text, whatever their content. Two separate steps that happen to run the same linter are two entries, whether written as two `run:` steps or as one multi-line `run:` block invoking it twice, because CI actually executes it (that many times); collapsing them is exactly the kind of inference this rule exists to forbid. Note the step's `working-directory:` if set, else the job's `defaults.run.working-directory`, else the repo root.
4. For a step carrying a `uses:` key instead of `run:`, add one entry naming the action (`action: <uses value>`) with no command — it is part of what CI runs but not something a shell can replay locally — **except** `actions/checkout`, `actions/setup-*`, and `actions/cache`, which perform no verification themselves and are dropped rather than reported as an unverifiable check. This is the one named, closed exclusion list in this rule, not an open-ended judgment call: any other `uses:` step, including a linter distributed as an action (e.g. `rhysd/actionlint`, `ludeeus/action-shellcheck`), is captured.
5. Classify every captured entry: **requires-runner** if its text contains a `${{ ... }}` GitHub Actions expression, `sudo`, a global-scope install or mutation (`npm install -g`, any `-g`/`--global` package-manager flag, `gh release create`, a `--scope user` plugin/package install, `git config --global`, or `pip install` in any form — unlike `npm install`, which defaults to a project-local `node_modules`, a bare `pip install` has no project-local default and mutates the ambient Python environment), or if it came from step 4 (a `uses:`-only step, checkout/setup/cache excluded already). Everything else is **runnable**. Do not narrow this further by guessing intent from the command's name — the point is whether it is safe and possible to execute unattended in a worktree, not whether it "looks like a check."
6. Only **runnable** entries are ever executed, by the worker, the reviewer, or the Publisher's own pre-push run. **requires-runner** entries are still reported — in the Run Plan and in whatever surfaces `CHECKS_SET` — as "not locally verifiable," never silently dropped and never executed.

Fast path with `yq` (mikefarah, v4+) and `jq`, streaming each workflow's content straight through both — no temp file, so two Publisher sessions on the same repo never collide on one. Both are required dependencies for this section and for the check-run loop in §3, alongside the `gh`/`git` this file already assumes:

```bash
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
for f in $(git ls-tree -r "origin/$BASE" --name-only -- .github/workflows | grep -E '\.ya?ml$'); do
  WF_JSON=$(git show "origin/$BASE:$f" | yq -o=json '.')
  KEEP=$(jq -e --arg base "$BASE" '.on |
    if type=="array" then any(.=="pull_request" or .=="push")
    elif type=="object" then
      has("pull_request")
        or (has("push") and (
          ((.push|type)!="object")
          or ((.push.branches // null) != null and (.push.branches | index($base)))
          or ((.push.branches // null) == null and (.push.tags // null) == null)
        ))
    else . == true or . == "pull_request" or . == "push"
    end' <<<"$WF_JSON" >/dev/null 2>&1 && echo yes || echo no)
  [ "$KEEP" = "yes" ] || continue
  jq -c --arg f "$f" '
    .jobs // {} | to_entries[] | .value as $job |
    ($job.defaults.run["working-directory"] // "") as $jobwd |
    ($job.steps // [])[] |
    if has("run") then
      {file:$f, kind:"run", workdir:(.["working-directory"] // $jobwd), command:.run}
    elif has("uses") and (.uses | test("^actions/(checkout|setup-|cache)") | not) then
      {file:$f, kind:"action", ref:.uses}
    else empty end' <<<"$WF_JSON"
done
```

Each output line is one compact JSON object — `.command` embeds internal newlines as `\n`, so a multi-line `run:` block always survives as exactly one `CHECKS_SET` entry regardless of how many lines or semicolons it contains. Classify each object per step 5 above; the script derives, filters, and orders the candidates, it does not decide runnable-vs-requires-runner for you. If `yq` is unavailable, read the workflow files directly and extract `run:`/`uses:` steps by the same rule; never approximate by grepping `package.json` scripts instead. Every `run:` block in a kept workflow originates from a file on the repository's own default branch, so treat it as trusted input if a later step needs to execute it (Step 4, Step 6, commands §3) — the same trust boundary this loop already extends to a worker's own commits.

**Worked example — this repository's own four workflows**, since the Issue's partner-repo replay (a CI that runs two `oxlint` commands `npm run lint` doesn't cover) isn't reachable from here. Applying the rule above to `.github/workflows/*.yml` on `main`, verified by actually running the script above against them:

| Workflow | Kept? | Entries in `CHECKS_SET` | Classification |
|---|---|---|---|
| `lint-actions.yml` (`pull_request`, `push:[main]`) | yes | `action: rhysd/actionlint@914e7df...` | requires-runner (`uses:`-only step) |
| `lint-shell.yml` (`pull_request`, `push:[main]`) | yes | `sudo locale-gen …` / `awk --version …` / `bash skills/ja-style-check/scripts/test-scan.sh` (one step, one entry, multi-line) | requires-runner (`sudo`) |
| `lint-shell.yml` | yes | `action: ludeeus/action-shellcheck@00cae50...` | requires-runner (`uses:`-only step) |
| `lint-shell.yml` | yes | `pip install semgrep` | requires-runner (`pip install` mutates the ambient Python environment) |
| `lint-shell.yml` | yes | `semgrep --config p/security-audit --config p/secrets --error .` | runnable, but only meaningful if `semgrep` is already on `PATH` — the preceding step is `requires-runner` and this loop never runs it |
| `release.yml` (`push`, `tags:[v*]` only) | **no** — dropped by the trigger filter | — | — |
| `test-plugin-install.yml` (`push:[main]`, `pull_request`, `workflow_dispatch`) | yes | `npm install -g @anthropic-ai/claude-code` (job `validate`) | requires-runner (`-g` global install) |
| `test-plugin-install.yml` | yes | `claude plugin validate .` (job `validate`) | runnable |
| `test-plugin-install.yml` | yes | `git config --global url…` / `git config --global url…` (job `test-install`, one step, two lines) | requires-runner (`--global`) |
| `test-plugin-install.yml` | yes | `npm install -g @anthropic-ai/claude-code` (job `test-install`, a second, separate entry — not deduped against the one above) | requires-runner (`-g` global install) |
| `test-plugin-install.yml` | yes | `claude plugin marketplace add ./` | runnable |
| `test-plugin-install.yml` | yes | `claude plugin marketplace list` | runnable |
| `test-plugin-install.yml` | yes | `claude plugin install skills@maro114510-agent-skills --scope user` | requires-runner (`--scope user` global-scope install) |
| `test-plugin-install.yml` | yes | `claude plugin list \| grep skills` | runnable |

`actions/checkout` and `actions/setup-node` steps in every job are dropped by step 4's named exclusion, so they never clutter the list. `release.yml` is the case the trigger filter exists to catch: without it, `CHECKS_SET` would include `gh release create`, and Step 7 would run that against every shipped worktree. The two `npm install -g` entries, the `git config --global` entry, and the `pip install semgrep` entry show the requires-runner classification catching global-state mutation even where nothing about the command's *name* looks unlike an ordinary check — and `semgrep`'s own invocation shows that a `runnable` entry can still be a no-op in practice when the `requires-runner` step it depends on was, correctly, never run.

## §2 Dispatch Bookkeeping — Step 4

```bash
# Once per run
gh label create "loop:in-progress" --repo "$REPO" --color "BFD4F2" --description "orchestrate-epic worker is implementing" 2>/dev/null || true
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)   # same resolution as §1.5 — never hardcode main
git switch "$BASE" && git pull origin "$BASE"   # once, before any worker; on dirty-tree failure: stop and tell the user

# Per dispatched Issue, serially
git wt "feat/issue-$N"   # prints the worktree path — capture it for the worker prompt; reuses existing worktrees
gh issue edit "$N" --repo "$REPO" --add-label "loop:in-progress"
gh issue comment "$N" --repo "$REPO" --body "orchestrate-epic: 実装を開始しました (branch: \`feat/issue-$N\`)"

# Per answered BLOCKED question (Step 5) — human answers must survive the session
gh issue comment "$N" --repo "$REPO" --body "$(cat <<'EOF'
orchestrate-epic Q&A:
Q: <workerの質問>
A: <ユーザーの回答>
EOF
)"
```

## §2.5 State Comment — Steps 2, 5, 6, 7

One sticky comment per Issue, distinct from the start/Q&A comments above, identified by a leading marker so it can be found and edited in place instead of piling up duplicates.

```bash
ME=$(gh api user --jq .login)   # same resolution as §1.5 — read it fresh here if this section runs on its own

# Read the latest state comment (empty output if none exists yet — still cycle 0).
# --paginate --slurp fetches every page — a long-running Issue can carry more comments than one
# page holds, and [-1] alone would silently pick a stale mid-list comment instead of the real latest.
# $ME filters out any comment planted by someone other than this run's own identity — otherwise an
# attacker-authored marker could be read as, or overwritten as, real state.
gh api "repos/$REPO/issues/$N/comments" --paginate --slurp --jq --arg me "$ME" \
  'add | [.[]|select(.user.login==$me and (.body|startswith("<!-- orchestrate-epic-state -->")))][-1] // empty'

# Upsert: edit the existing state comment if found, else create it
STATE_ID=$(gh api "repos/$REPO/issues/$N/comments" --paginate --slurp --jq --arg me "$ME" \
  'add | [.[]|select(.user.login==$me and (.body|startswith("<!-- orchestrate-epic-state -->")))][-1].id // empty')
if [ -n "$STATE_ID" ]; then
  gh api "repos/$REPO/issues/comments/$STATE_ID" -X PATCH -f body="$BODY"
else
  gh issue comment "$N" --repo "$REPO" --body "$BODY"
fi
```

`$BODY` carries all four fields every time, even when a field is empty — a partial write is worse than a stale one, since a missing field reads as "never recorded" on the next resume:

```
<!-- orchestrate-epic-state -->
orchestrate-epic state:
- cycle: <再ディスパッチ回数。初回ディスパッチは 0>
- head_sha: <workerが報告した HEAD_SHA。コミットがまだなければ none>
- unresolved_blockers: <なし、またはレビューア指摘を番号付きで file:line — 要約>
- decisions: <このIssueについて人間が下した判断。なければ なし>
```

`cycle` counts reviewer fix cycles only, a REQUEST_CHANGES re-dispatch from Step 6; a BLOCKED answer or FAILED retry from Step 5 leaves it unchanged, and neither resets it. The one exception is an authorized `retry` or `redo` decision on a `parked` or `rejected` Issue, SKILL.md Step 2's un-parking check, which resets `cycle` to 0 — a human decision restarts the fix-cycle budget on purpose. Short of that, Step 6 reads it back on a resumed session so the 2-fix-cycle cap holds across a restart instead of starting over at 0.

git-wt may place worktrees outside the repo, depending on its config — always use the printed path, never an assumed `.wt/`.

## §3 Ship an Approved Issue — Step 7

`WT` is the worktree path; `BRANCH` is the branch selected for this Issue in Step 4 — `feat/issue-<N>` normally, or its state-comment-recorded `redo` branch when one applies.
Every sub-step is guarded so a mid-failure rerun resumes instead of erroring: commit only when work is left uncommitted, push is repeat-safe, create the PR only when none exists for the branch.

```bash
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)   # same resolution as §1.5 — never hardcode main

# 1. Inspect what ships — input for the secret screen
git -C "$WT" add -N .                                      # intent-to-add: makes untracked files diff-visible (content stays unstaged)
git -C "$WT" status --short
git -C "$WT" diff "$(git -C "$WT" merge-base "$BASE" HEAD)"   # uncommitted changes plus the worker's own commit(s), without post-branch main noise
git -C "$WT" fetch origin "$BRANCH" 2>/dev/null
git -C "$WT" rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1 && echo "PUSHED EXTERNALLY — flag to the user"   # succeeds only if the branch reached the remote before this step pushed it

# 2. Stage and commit — skip entirely when HEAD already matches the worker report's own HEAD_SHA
# (non-empty, not UNKNOWN): the worker's commit contract already covers everything it changed, so
# there is nothing left to add. Otherwise `reset` first, to undo sub-step 1's `add -N .` — without it,
# an untracked file Step 6's reviewer left behind while running CHECKS_SET in this same worktree (a
# cache dir, a lockfile) stays intent-to-add in the index and would ride into a bare `git commit` even
# though sub-step 3 below only ever stages the worker's own CHANGED_FILES paths. Stage exactly those
# paths — never `add -A`/`add -u`, which would also pick up that same reviewer-left untracked or
# in-place-modified state. After a secret-screen hit specifically, unstage the flagged path first with
# `git -C "$WT" restore --staged -- <path>`, then stage the remaining CHANGED_FILES as usual.
if [ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "UNKNOWN" ] && [ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_SHA" ]; then
  : # nothing left to commit — proceed to the check run
else
  git -C "$WT" reset
  git -C "$WT" add -- <CHANGED_FILES paths from the worker report>
  git -C "$WT" commit -m "$(cat <<'EOF'
<type>(<scope>): <summary derived from the Issue title>

<1-3 lines: what and why, from the worker summary>

Refs #<N>
EOF
)"
fi

# 3. Run CHECKS_SET's runnable entries once, against the just-committed state — the Publisher-side
# check run required by #143. $CHECKS_SET_RUNNABLE is CHECKS_SET filtered to `runnable` entries,
# newline-delimited compact JSON as commands §1.6 produces (one object per line: {workdir, command}).
# Each `run:` block is trusted input — it comes from a workflow file on the repository's own default
# branch, the same trust boundary already extended to a worker's own commits.
CHECK_FAILED=0
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  WORKDIR=$(jq -r '.workdir // ""' <<<"$entry")
  COMMAND=$(jq -r '.command' <<<"$entry")
  OUTPUT=$(cd "$WT/${WORKDIR:-.}" && eval "$COMMAND" 2>&1)
  STATUS=$?
  if [ "$STATUS" -ne 0 ]; then
    CHECK_FAILED=1
    printf 'RED (exit %s): %s\n%s\n' "$STATUS" "$COMMAND" "$OUTPUT"   # capture for the Issue comment below
  fi
done <<<"$CHECKS_SET_RUNNABLE"
# CHECK_FAILED != 0: treat exactly like a secret-screen hit — post the failing command(s), exit
# code, and relevant output as a comment on the Issue, upsert the state comment's unresolved_blockers
# (SKILL.md Step 7), leave loop:in-progress, skip sub-steps 4-5 for this Issue, continue with the rest
# of the round. Nothing above stages or commits anything, so a check that writes a lockfile, build
# output, or cache directory into $WT never enters the pushed commit — there is no `add` step after
# this one, matching sub-step 2's explicit-path staging above.

# 4. Push (repeat-safe), then create the PR — only if none exists yet for this branch
git -C "$WT" push -u origin "$BRANCH"
gh pr list --repo "$REPO" --head "$BRANCH" --state all --json number   # non-empty → PR exists, skip creation
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
gh pr create --repo "$REPO" --head "$BRANCH" --base "$BASE" --title "<Issue title>" --body "$(cat <<'EOF'
## Summary
<worker summary, condensed>

## Check evidence
<CHECKS and CRITERIA sections from the worker report>

Closes #<N>
Part of Epic #<EPIC>
EOF
)"

# 5. Clear the marker
gh issue edit "$N" --repo "$REPO" --remove-label "loop:in-progress"
```

Secret screen, run before step 2 above: the commit skill's Step 2 patterns against the status paths and diff — `.env*`, `*.pem`, `*.key`, `id_rsa*`, `*credentials*`, `*secret*`, `*.p12`, `service-account*.json`; `AKIA[0-9A-Z]{16}`, private-key headers, `gh[pousr]_[A-Za-z0-9]{20,}`, `sk-[A-Za-z0-9]{20,}`, `xox[baprs]-`, literal values assigned to `password`/`token`. Any hit: unstage it via `restore --staged`, since `add -N` touched the index, post the finding as a comment on the Issue, and park it per SKILL.md Step 7 — never ship it silently.

## §4 Cleanup After Merge — Step 8 rescan

Only for an Issue that is **closed** with a **merged** PR:

```bash
git -C "$WT" status --short   # must be clean; if not, report it instead of forcing
git worktree remove "$WT"
git branch -d "$BRANCH"       # -d refuses if unmerged, which is the point
git worktree prune
```
