# Command Reference

Read only the section for the step you are on. Commands run from the main checkout unless `git -C` targets a worktree.
`REPO` is `owner/repo`; `EPIC` is the Epic Issue number.

## §1 Load State (Step 2)

```bash
gh issue view "$EPIC" --repo "$REPO" --json number,title,body,state,subIssues

# Per open child — blockedBy is the dependency ground truth (requires gh >= 2.96)
gh issue view "$N" --repo "$REPO" --json number,title,state,labels,blockedBy

# Prior progress per open child
git fetch origin --prune
git branch --list "feat/issue-$N" ; git ls-remote --heads origin "feat/issue-$N"
gh pr list --repo "$REPO" --head "feat/issue-$N" --state all --json number,state,url,mergedAt
git worktree list   # match branch names to recover worktree paths
```

PR state decoding: `OPEN` → awaiting-merge; `MERGED` → merged; `CLOSED` with `mergedAt: null` → rejected (escalate).

Fallback when `subIssues`/`blockedBy` fields are unavailable (older gh / GHES): parse the Epic body's "Dependencies & Parallel Execution Plan" section — Mermaid edges `X --> Y` mean Y depends on X; the wave-table variant lists each row's `#<number>` dependencies — then fetch each child's state individually. Tell the user the run is on this fallback, since a hand-edited Epic body can drift from the real relations.

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
git -C "$WT" status --short
git -C "$WT" diff "$(git -C "$WT" merge-base main HEAD)"   # uncommitted + any rogue commits, without post-branch main noise
git -C "$WT" log --oneline main..HEAD                      # non-empty = worker committed against its rules; flag to the user

# 2. Stage and commit — skip if `status --short` is empty (a rerun after the commit already landed)
git -C "$WT" add -A
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

Secret screen (before step 2): the commit skill's Step 2 patterns against the status paths and diff — `.env*`, `*.pem`, `*.key`, `id_rsa*`, `*credentials*`, `*secret*`, `*.p12`, `service-account*.json`; `AKIA[0-9A-Z]{16}`, private-key headers, `gh[pousr]_[A-Za-z0-9]{20,}`, `sk-[A-Za-z0-9]{20,}`, `xox[baprs]-`, literal values assigned to `password`/`token`. Any hit: leave unstaged, tell the user, ask.

## §4 Cleanup After Merge (Step 9 rescan)

Only for an Issue that is **closed** with a **merged** PR:

```bash
git -C "$WT" status --short   # must be clean; if not, ask instead of forcing
git worktree remove "$WT"
git branch -d "$BRANCH"       # -d refuses if unmerged, which is the point
git worktree prune
```
