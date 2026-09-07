# Command Reference

Read only the section for the step you are on. Commands run from the main checkout unless `git -C` targets a worktree.
`REPO` is `owner/repo`; `EPIC` is the Epic Issue number.

## §1 Load State (Step 2)

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

`--jq` filters client-side, so only the projection reaches the context. `tokens: true` is the leftover-`{{Tn}}`/`{{Tn.m}}` signal Step 2 escalates on — it costs nothing, unlike carrying the Epic body. `CONTAINERS` is derived from call 1's output before call 2 runs (`[.children[]|select(.grandchildren|length>0)|.n]`) — a `Tn` with a non-empty `grandchildren` array in call 1 is a container; every other `Tn` is a leaf and is never expected to have children of its own. A `Tn.m` never has grandchildren of its own (Step 2's depth cap in create-github-issues), so this single extra nesting level is always enough — no recursion needed.

Calls 2 and 3 page the repository's issues and PRs before filtering, so `--limit` truncates silently on a busy repository. Cross-check both against call 1's `Tn` and grandchild lists (flattened): if an open `Tn` or `Tn.m` is missing from call 2, or a `feat/issue-<n>` branch that exists locally has no row in call 3, the read is incomplete. Raise the limit and re-run rather than classifying on a partial board.

Branch and worktree recovery stays local and free:

```bash
git fetch origin --prune
git branch --list "feat/issue-*"
git worktree list
```

PR state decoding: `OPEN` → awaiting-merge; `MERGED` → merged; `CLOSED` with `mergedAt: null` → rejected (escalate).

Fetch the Epic body itself (`--jq .body`) only on the fallback path below, or when a leftover token needs to be shown to the user.

Fallback when `subIssues`/`blockedBy` are unavailable (older gh / GHES, or the GraphQL call itself errors): parse the Epic body's "Dependencies & Parallel Execution Plan" section — Mermaid edges `X --> Y` mean Y depends on X; the wave-table variant lists each row's `#<number>` dependencies — then fetch each `Tn`'s state individually. For a `Tn` that turned out to be a container, its own body carries the same kind of section for its `Tn.m` children — parse it the same way, one level down. Tell the user the run is on this fallback, since a hand-edited body can drift from the real relations.

## §1.5 Entry Gate (Step 3)

```bash
# Once per run
gh label create "oe:go" --repo "$REPO" --color "0E8A16" --description "human approved the orchestrate-epic Run Plan" 2>/dev/null || true

# Find the Run Plan comment — --paginate --slurp fetches every page (an Epic can carry more
# comments than one page holds), `add` flattens the resulting array-of-arrays before [-1] picks the latest
gh api "repos/$REPO/issues/$EPIC/comments" --paginate --slurp --jq 'add | [.[]|select(.body|startswith("<!-- orchestrate-epic:run-plan -->"))][-1] // empty'

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
  echo "protection check failed (HTTP $HTTP_STATUS) — stop and report, do not assume no protection" >&2
fi
git ls-tree -r "origin/$BASE" --name-only -- .github/workflows

# Completion exit comment (Step 9) — marked the same way as the Run Plan, so a rerun after completion
# doesn't post a second one; $EXIT_COMMENT_BODY must start with <!-- orchestrate-epic:completion -->
gh api "repos/$REPO/issues/$EPIC/comments" --paginate --slurp --jq 'add | [.[]|select(.body|startswith("<!-- orchestrate-epic:completion -->"))][-1] // empty'
gh issue comment "$EPIC" --repo "$REPO" --body "$EXIT_COMMENT_BODY"   # only when the check above found none
```

## §2 Dispatch Bookkeeping (Step 4)

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

## §2.5 State Comment (Steps 2, 5, 6, 7)

One sticky comment per Issue, distinct from the start/Q&A comments above, identified by a leading marker so it can be found and edited in place instead of piling up duplicates.

```bash
# Read the latest state comment (empty output if none exists yet — still cycle 0).
# --paginate --slurp fetches every page — a long-running Issue can carry more comments than one
# page holds, and [-1] alone would silently pick a stale mid-list comment instead of the real latest.
gh api "repos/$REPO/issues/$N/comments" --paginate --slurp --jq 'add | [.[]|select(.body|startswith("<!-- orchestrate-epic-state -->"))][-1] // empty'

# Upsert: edit the existing state comment if found, else create it
STATE_ID=$(gh api "repos/$REPO/issues/$N/comments" --paginate --slurp --jq 'add | [.[]|select(.body|startswith("<!-- orchestrate-epic-state -->"))][-1].id // empty')
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

`cycle` counts reviewer fix cycles only (a REQUEST_CHANGES re-dispatch from Step 6) and never resets; a BLOCKED answer or FAILED retry from Step 5 leaves it unchanged. Step 6 reads it back on a resumed session so the 2-fix-cycle cap holds across a restart instead of starting over at 0.

git-wt may place worktrees outside the repo (config-dependent) — always use the printed path, never an assumed `.wt/`.

## §3 Ship an Approved Issue (Step 7)

`WT` is the worktree path; `BRANCH` is `feat/issue-<N>`.
Every sub-step is guarded so a mid-failure rerun resumes instead of erroring: commit only when work is left uncommitted, push is repeat-safe, create the PR only when none exists for the branch.

```bash
# 1. Inspect what ships — input for the secret screen
git -C "$WT" add -N .                                      # intent-to-add: makes untracked files diff-visible (content stays unstaged)
git -C "$WT" status --short
git -C "$WT" diff "$(git -C "$WT" merge-base main HEAD)"   # uncommitted changes plus the worker's own commit(s), without post-branch main noise
git -C "$WT" fetch origin "$BRANCH" 2>/dev/null
git -C "$WT" rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1 && echo "PUSHED EXTERNALLY — flag to the user"   # succeeds only if the branch reached the remote before this step pushed it

# 2. Stage and commit — skip only if `status --short` is empty AND `git -C "$WT" rev-parse HEAD`
# matches the worker report's HEAD_SHA (the worker already committed everything there was)
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

## Check evidence
<CHECKS and CRITERIA sections from the worker report>

Closes #<N>
Part of Epic #<EPIC>
EOF
)"

# 4. Clear the marker
gh issue edit "$N" --repo "$REPO" --remove-label "loop:in-progress"
```

Secret screen (before step 2): the commit skill's Step 2 patterns against the status paths and diff — `.env*`, `*.pem`, `*.key`, `id_rsa*`, `*credentials*`, `*secret*`, `*.p12`, `service-account*.json`; `AKIA[0-9A-Z]{16}`, private-key headers, `gh[pousr]_[A-Za-z0-9]{20,}`, `sk-[A-Za-z0-9]{20,}`, `xox[baprs]-`, literal values assigned to `password`/`token`. Any hit: unstage it (`restore --staged`, since `add -N` touched the index), post the finding as a comment on the Issue, and park it (SKILL.md Step 7) — never ship it silently.

## §4 Cleanup After Merge (Step 8 rescan)

Only for an Issue that is **closed** with a **merged** PR:

```bash
git -C "$WT" status --short   # must be clean; if not, report it instead of forcing
git worktree remove "$WT"
git branch -d "$BRANCH"       # -d refuses if unmerged, which is the point
git worktree prune
```
