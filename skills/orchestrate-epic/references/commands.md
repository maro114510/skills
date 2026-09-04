# Command Reference

Read only the section for the step you are on. Commands run from the main checkout unless `git -C` targets a worktree.
`REPO` is `owner/repo`; `EPIC` is the Epic Issue number.

## §1 Load State (Step 2)

Three `gh` calls, whatever the child count. Never loop `gh issue view` per child: that payload embeds every blocker's full title and URL, so both the call count and the response size scale with the Epic.

```bash
# 1. Epic, its children's states, and the leftover-token check in one projection
gh issue view "$EPIC" --repo "$REPO" \
  --json number,title,body,subIssues \
  --jq '{epic:.number, tokens:(.body|test("\\{\\{T[0-9]+\\}\\}")),
         children:[.subIssues.nodes[]|{n:.number,s:.state,t:.title}]}'

# 2. Labels and dependency edges, open children only
EPIC="$EPIC" gh issue list --repo "$REPO" --state open --limit 200 \
  --json number,labels,blockedBy,parent \
  --jq '[.[]|select(.parent.number == (env.EPIC|tonumber))
        |{n:.number, l:[.labels[].name],
          b:[.blockedBy.nodes[]|select(.state=="OPEN")|.number]}]'

# 3. Every PR on a loop branch, keyed by Issue number
gh pr list --repo "$REPO" --state all --limit 200 \
  --json number,state,mergedAt,headRefName \
  --jq '[.[]|select(.headRefName|test("^feat/issue-[0-9]+(-|$)"))
        |{i:(.headRefName|capture("^feat/issue-(?<n>[0-9]+)").n|tonumber),
          p:.number, s:(if .mergedAt then "MERGED" else .state end), h:.headRefName}]'
```

`--jq` filters client-side, so only the projection reaches the context. `tokens: true` is the leftover-`{{Tn}}` signal Step 2 escalates on — it costs nothing, unlike carrying the Epic body.

Calls 2 and 3 page the repository's issues and PRs before filtering, so `--limit` truncates silently on a busy repository. Cross-check both against call 1's child list: if an open child is missing from call 2, or a `feat/issue-<n>` branch that exists locally has no row in call 3, the read is incomplete. Raise the limit and re-run rather than classifying on a partial board.

Branch and worktree recovery stays local and free:

```bash
git fetch origin --prune
git branch --list "feat/issue-*"
git worktree list
```

PR state decoding: `OPEN` → awaiting-merge; `MERGED` → merged; `CLOSED` with `mergedAt: null` → rejected (escalate).

Fetch the Epic body itself (`--jq .body`) only on the fallback path below, or when a leftover token needs to be shown to the user.

Fallback when `subIssues`/`blockedBy` are unavailable (older gh / GHES): parse the Epic body's "Dependencies & Parallel Execution Plan" section — Mermaid edges `X --> Y` mean Y depends on X; the wave-table variant lists each row's `#<number>` dependencies — then fetch each child's state individually. Tell the user the run is on this fallback, since a hand-edited Epic body can drift from the real relations.

## §2 Dispatch Bookkeeping (Step 4)

```bash
# Once per run
gh label create "loop:in-progress" --repo "$REPO" --color "BFD4F2" --description "orchestrate-epic worker is implementing" 2>/dev/null || true
git switch main && git pull origin main   # once, before any worker; on dirty-tree failure: stop and ask

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

git-wt may place worktrees outside the repo (config-dependent) — always use the printed path, never an assumed `.wt/`.

## §3 Ship an Approved Issue (Step 8)

`WT` is the worktree path; `BRANCH` is `feat/issue-<N>`.
Every sub-step is guarded so a mid-failure rerun resumes instead of erroring: commit only when uncommitted changes exist, push is repeat-safe, create the PR only when none exists for the branch.

```bash
# 1. Inspect what ships — input for the secret screen
git -C "$WT" add -N .                                      # intent-to-add: makes untracked files diff-visible (content stays unstaged)
git -C "$WT" status --short
git -C "$WT" diff "$(git -C "$WT" merge-base main HEAD)"   # uncommitted + any rogue commits, without post-branch main noise
git -C "$WT" log --oneline main..HEAD                      # non-empty = worker committed against its rules; flag to the user

# 2. Stage and commit — skip if `status --short` is empty (a rerun after the commit already landed)
git -C "$WT" add -A                        # ONLY when the secret screen found nothing
# After any hit, never use add -A: unstage flagged paths (git -C "$WT" restore --staged -- <path>)
# and stage the safe remainder explicitly with git -C "$WT" add -- <path>...
git -C "$WT" commit -m "$(cat <<'EOF'
<type>(<scope>): <summary derived from the Issue title>

<1-3 lines: what and why, from the worker summary>

Refs #<N>
EOF
)"

# 3. Push (repeat-safe), then create the PR — only if none exists yet for this branch
git -C "$WT" push -u origin "$BRANCH"
gh pr list --repo "$REPO" --head "$BRANCH" --state all --json number   # non-empty → PR exists, skip creation
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
gh pr create --repo "$REPO" --head "$BRANCH" --base "$BASE" --title "<Issue title>" --body "$(cat <<'EOF'
## Summary
<worker summary, condensed>

## Test evidence
<TESTS section from the worker report>

Closes #<N>
Part of Epic #<EPIC>
EOF
)"

# 4. Clear the marker
gh issue edit "$N" --repo "$REPO" --remove-label "loop:in-progress"
```

Secret screen (before step 2): the commit skill's Step 2 patterns against the status paths and diff — `.env*`, `*.pem`, `*.key`, `id_rsa*`, `*credentials*`, `*secret*`, `*.p12`, `service-account*.json`; `AKIA[0-9A-Z]{16}`, private-key headers, `gh[pousr]_[A-Za-z0-9]{20,}`, `sk-[A-Za-z0-9]{20,}`, `xox[baprs]-`, literal values assigned to `password`/`token`. Any hit: unstage it (`restore --staged`, since `add -N` touched the index), tell the user, ask — never ship it silently.

## §4 Cleanup After Merge (Step 9 rescan)

Only for an Issue that is **closed** with a **merged** PR:

```bash
git -C "$WT" status --short   # must be clean; if not, ask instead of forcing
git worktree remove "$WT"
git branch -d "$BRANCH"       # -d refuses if unmerged, which is the point
git worktree prune
```
