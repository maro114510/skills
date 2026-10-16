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

# 3. Every PR on a loop branch, keyed by Issue number. headRefOid is the PR's current head
#    commit — compare it against the state comment's reviewed_sha to detect a verdict that
#    went stale when the head moved after review.
gh pr list --repo "$REPO" --state all --limit 200 \
  --json number,state,mergedAt,headRefName,headRefOid \
  --jq '[.[]|select(.headRefName|test("^feat/issue-[0-9]+(-|$)"))
        |{i:(.headRefName|capture("^feat/issue-(?<n>[0-9]+)").n|tonumber),
          p:.number, s:(if .mergedAt then "MERGED" else .state end), h:.headRefName,
          sha:.headRefOid}]'
```

`--jq` filters client-side, so only the projection reaches the context. `tokens: true` is the leftover-`{{Tn}}`/`{{Tn.m}}` signal Step 2 escalates on — it costs nothing, unlike carrying the Epic body. `CONTAINERS` is derived from call 1's output before call 2 runs, via `[.children[]|select(.grandchildren|length>0)|.n]` — a `Tn` with a non-empty `grandchildren` array in call 1 is a container; every other `Tn` is a leaf and is never expected to have children of its own. Step 2's depth cap in create-github-issues means a `Tn.m` never has grandchildren of its own, so this single extra nesting level is always enough — no recursion needed.

Calls 2 and 3 page the repository's issues and PRs before filtering, so `--limit` truncates silently on a busy repository. Cross-check call 2 against call 1's `Tn` and grandchild lists, flattened: if an open `Tn` or `Tn.m` is missing from call 2, the read is incomplete — raise the limit and re-run rather than classifying on a partial board. Do not apply the same reasoning to call 3: a local `feat/issue-<n>` branch with no row there is not itself evidence of a truncated page — an Issue can legitimately be `ready` or `in-progress` with a branch that has no PR yet, since Step 7 is what creates one.

Branch and worktree recovery stays local and free:

```bash
git fetch origin --prune
git branch --list "feat/issue-*"
git worktree list
```

PR state decoding: `OPEN` → awaiting-merge, or reverify when its `sha` or the current base no longer matches the state comment's bound pair, SKILL.md Step 2; `MERGED` → merged; `CLOSED` with `mergedAt: null` → rejected, escalate.

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

Derived once per round, from `.github/workflows/` on the default branch — never from `package.json`/`Makefile` script names. The result, `CHECKS_SET`, is an ordered list of `{command, working_directory, env, runnable}` entries, reused as-is by Step 4's worker prompt, Step 6's reviewer, and Step 7's pre-push run. Recompute it fresh each round; do not carry it over from a prior round in case a workflow file changed.

**The rule, applied by hand or via the script below — get this exactly right, since it is the only thing standing between the loop and the next "nobody owned CI-equivalence" incident:**

1. List every file under `.github/workflows` on the default branch (`git ls-tree -r "origin/$BASE" --name-only -- .github/workflows`, `.yml`/`.yaml` only) and read each one's content from that same ref — never the local worktree copy, which can be mid-edit by a worker. `origin/$BASE` is already current at this point: Step 2 runs `git fetch origin --prune` every invocation, before Step 3 derives `CHECKS_SET`, per §1.
2. Keep a workflow only if its `on:` triggers include `pull_request` (any form), or `push` restricted to a `branches` list containing `$BASE`, or `push` with neither a `branches` nor a `tags` filter (fully unrestricted, so it fires on a push to the default branch too). Drop everything else — `push` restricted to `tags` only, `schedule`, `workflow_dispatch`-only — a workflow that never runs against a PR or a push to the default branch cannot be what "CI ran" means for a shipped branch. This filter is mandatory, not an optional narrowing: without it, `CHECKS_SET` picks up a tag-triggered release job or any other workflow irrelevant to a shipped branch, and the loop starts running things far more dangerous than a missing linter.
3. Within each kept workflow, walk every job in `jobs:` in file order, and every step in that job's `steps:` in order. For a step carrying a `run:` key, capture the run block **verbatim, one entry per step** — never merge two steps' commands into one entry, never split one step's multi-line block into several, never deduplicate two entries with identical text, whatever their content. Two separate steps that happen to run the same linter are two entries, whether written as two `run:` steps or as one multi-line `run:` block invoking it twice, because CI actually executes it (that many times); collapsing them is exactly the kind of inference this rule exists to forbid. Note the step's `working-directory:` if set, else the job's `defaults.run.working-directory`, else the repo root. Also note the step's effective `env:` (the job's `env:` merged with the step's own, the step winning on a key collision) and its effective `shell:` (the step's `shell:`, else the job's `defaults.run.shell`, else unset) — a command that depends on an environment variable or a non-default shell must carry that with it, not be replayed bare.
4. For a step carrying a `uses:` key instead of `run:`, add one entry naming the action (`action: <uses value>`) with no command — it is part of what CI runs but not something a shell can replay locally — **except** `actions/checkout`, `actions/setup-*`, and `actions/cache`, which perform no verification themselves and are dropped rather than reported as an unverifiable check. This is the one named, closed exclusion list in this rule, not an open-ended judgment call: any other `uses:` step, including a linter distributed as an action (e.g. `rhysd/actionlint`, `ludeeus/action-shellcheck`), is captured.
5. Classify every captured entry: **requires-runner** if its command text *or* its effective `env:` contains a `${{ ... }}` GitHub Actions expression, if its command text contains `sudo` or a global-scope install or mutation (`npm install -g`, any `-g`/`--global` package-manager flag, `gh release create`, a `--scope user` plugin/package install, `git config --global`, or `pip install` in any form — unlike `npm install`, which defaults to a project-local `node_modules`, a bare `pip install` has no project-local default and mutates the ambient Python environment), if its effective `shell:` is set to anything other than `bash`, `sh`, or unset (a runner-specific interpreter — `pwsh`, `python`, a custom invocation like `bash -e {0}` — cannot be safely replayed by the plain `bash`/`sh` execution the other three roles use), or if it came from step 4 (a `uses:`-only step, checkout/setup/cache excluded already). Everything else is **runnable**. Do not narrow this further by guessing intent from the command's name — the point is whether it is safe and possible to execute unattended in a worktree, not whether it "looks like a check."
6. Only **runnable** entries are ever executed, by the worker, the reviewer, or the Publisher's own pre-push run — and always with their captured `env:` exported first, in their captured `working_directory`. **requires-runner** entries are still reported — in the Run Plan and in whatever surfaces `CHECKS_SET` — as "not locally verifiable," never silently dropped and never executed. Two entries whose command comes from the same job can be classified differently even when one depends on the other's setup — for example a `pip install <linter>` step (`requires-runner`, a global-scope install) followed by a step invoking that linter (`runnable` on its own text, but a no-op in an environment where the install never ran). This rule classifies **per entry**, not per dependency chain: tracking which `runnable` entries transitively depend on a `requires-runner` one would mean inferring intent between steps, which is exactly what this rule forbids elsewhere. Report a `runnable` entry that fails only because a preceding `requires-runner` step was — correctly — never run as an expected, documented gap, not a defect in the derivation.

Fast path with `yq` (mikefarah, v4+) and `jq`, streaming each workflow's content straight through both — no temp file, so two Publisher sessions on the same repo never collide on one. Both are required dependencies for this section and for the check-run loop in §3, alongside the `gh`/`git` this file already assumes:

```bash
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
for f in $(git ls-tree -r "origin/$BASE" --name-only -- .github/workflows | grep -E '\.ya?ml$'); do
  WF_JSON=$(git show "origin/$BASE:$f" | yq -o=json '.')
  KEEP=$(jq -e --arg base "$BASE" '
    def glob_re: "^" + (gsub("\\."; "\\.") | gsub("\\*"; ".*")) + "$";
    def branch_matches($patterns): ($patterns // []) | any(. as $p | ($base | test($p|glob_re)));
    .on |
    if type=="array" then any(.=="pull_request" or .=="push")
    elif type=="object" then
      has("pull_request")
        or (has("push") and (
          ((.push|type)!="object")
          or (.push|has("branches")) and branch_matches(.push.branches)
          or ((.push|has("branches")|not) and (.push|has("branches-ignore")) and (branch_matches(.push["branches-ignore"])|not))
          or ((.push|has("branches")|not) and (.push|has("branches-ignore")|not) and (.push|has("tags")|not))
        ))
    else . == true or . == "pull_request" or . == "push"
    end' <<<"$WF_JSON" >/dev/null 2>&1 && echo yes || echo no)
  [ "$KEEP" = "yes" ] || continue
  jq -c --arg f "$f" '
    .jobs // {} | to_entries[] | .value as $job |
    ($job.defaults.run["working-directory"] // "") as $jobwd |
    ($job.defaults.run.shell // "") as $jobshell |
    ($job.env // {}) as $jobenv |
    ($job.steps // [])[] |
    if has("run") then
      {file:$f, kind:"run", workdir:(.["working-directory"] // $jobwd),
       shell:(.shell // $jobshell), env:($jobenv + (.env // {})), command:.run}
    elif has("uses") and (.uses | test("^actions/(checkout|setup-|cache)") | not) then
      {file:$f, kind:"action", ref:.uses}
    else empty end' <<<"$WF_JSON"
done
```

Each output line is one compact JSON object — `.command` embeds internal newlines as `\n`, so a multi-line `run:` block always survives as exactly one `CHECKS_SET` entry regardless of how many lines or semicolons it contains. Classify each object per step 5 above; the script derives, filters, and orders the candidates, it does not decide runnable-vs-requires-runner for you. `branch_matches` is a best-effort glob (`*` only, no `**`/character classes) rather than full GitHub Actions branch-filter syntax — good enough to tell whether the default branch itself is matched or excluded, which is all this rule needs. If `yq` is unavailable, read the workflow files directly and extract `run:`/`uses:` steps by the same rule; never approximate by grepping `package.json` scripts instead. Every `run:` block in a kept workflow originates from a file on the repository's own default branch, so treat it as trusted input if a later step needs to execute it (Step 4, Step 6, commands §3) — the same trust boundary this loop already extends to a worker's own commits.

**Worked example — this repository's own four workflows**, since the Issue's partner-repo replay (a CI that runs two `oxlint` commands `npm run lint` doesn't cover) isn't reachable from here. Applying the rule above to `.github/workflows/*.yml` on `main`, verified by actually running the script above against them:

| Workflow | Kept? | Entries in `CHECKS_SET` | Classification |
|---|---|---|---|
| `lint-actions.yml` (`pull_request`, `push:[main]`) | yes | `action: rhysd/actionlint@914e7df...` | requires-runner (`uses:`-only step) |
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
git fetch origin "$BASE"   # once, before any worker; updates only origin/$BASE. Never switch or pull the starting checkout — other sessions may share it. On failure: stop and tell the user

# Per dispatched Issue, serially
BRANCH="feat/issue-$N"   # or the state comment's recorded redo branch, such as feat/issue-$N-2
if git show-ref --verify --quiet "refs/heads/$BRANCH" \
   || git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git wt "$BRANCH"                  # existing branch: reuses its worktree, or checks it out; git wt rejects a start-point here
else
  git wt "$BRANCH" "origin/$BASE"   # new branch: starts from the fetched default branch, never the possibly stale local one
fi
# git wt prints the worktree path — capture it for the worker prompt
gh issue edit "$N" --repo "$REPO" --add-label "loop:in-progress"
gh issue comment "$N" --repo "$REPO" --body "orchestrate-epic: 実装を開始しました (branch: \`$BRANCH\`)"

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

`$BODY` carries every field below every time, even when a field is empty — a partial write is worse than a stale one, since a missing field reads as "never recorded" on the next resume:

```
<!-- orchestrate-epic-state -->
orchestrate-epic state:
- cycle: <fix cycle 回数。reviewer 指摘を受けた worker 再 dispatch と再 review を、blocking・nit のみを問わず 1 回として数え、初回 review は 0。staleness 再検証は数えない>
- head_sha: <現在記録している HEAD。worker が報告した HEAD_SHA、または Publisher 自身が作った base 取り込みの merge commit・fallback commit。コミットがまだなければ none>
- reviewed_sha: <直近の APPROVE が束縛された HEAD。有効な承認がなければ none>
- verified_base: <その APPROVE の review 開始前に固定した default branch の commit SHA。有効な承認がなければ none>
- pending_findings: <なし、または実行中の fix cycle に渡したレビューア指摘（blocking・nit とも）を番号付きで file:line — 要約。parked 判定には使わない>
- unresolved_blockers: <なし、または park の原因になった指摘・問いを番号付きで file:line — 要約>
- decisions: <このIssueについて人間が下した判断。なければ なし>
```

`cycle` counts every fix cycle from Step 6 — a fresh-worker re-dispatch for reviewer findings plus its re-review; one for blocking findings and one for nit-only findings each add 1, since the 2-cycle cap is what bounds nit resolution too, not only blocking. A staleness re-verification pass, Step 6, dispatches no worker and leaves it unchanged; so does a BLOCKED answer or FAILED retry from Step 5, and neither resets it. The one exception is an authorized `retry` or `redo` decision on a `parked` or `rejected` Issue, SKILL.md Step 2's un-parking check, which resets `cycle` to 0 — a human decision restarts the fix-cycle budget on purpose. Short of that, Step 6 reads it back on a resumed session so the 2-cycle cap holds across a restart instead of starting over at 0.

`pending_findings` holds the findings, blocking or nit, handed to an in-flight fix cycle — including the nits of an APPROVE, which Step 6 treats as REQUEST_CHANGES for state purposes. It is cleared by the next review result and by a `retry`/`redo`, and it never makes Step 2 classify the Issue `parked`; only `unresolved_blockers` does. A resumed `in-progress` Issue passes it into the fresh worker's prompt, Step 4.

`head_sha` alone is not an approval — it is written after every review, including a REQUEST_CHANGES. The ship-integrity pair is `reviewed_sha` + `verified_base`: Step 6 sets both only on a finding-free APPROVE whose pre-review pin (`REVIEW_HEAD`, `REVIEW_BASE`) still matches after the review, and resets both to `none` on a REQUEST_CHANGES, an APPROVE carrying nits, a park, a stale gate in Step 7, or a human `retry`/`redo` restart. Step 2's open-PR sanity check compares them against the PR's `headRefOid` and the current `origin/$BASE`, classifying a mismatch `reverify` so §2.6 re-verifies it; Step 7's verdict gate compares them against the worktree HEAD and `origin/$BASE` before shipping; #145's merge request sends `reviewed_sha` as its expected SHA. A mismatch on either field means the recorded verdict cannot authorize a ship or a merge.

git-wt may place worktrees outside the repo, depending on its config — always use the printed path, never an assumed `.wt/`.

## §2.6 Pin and Integrate the Base, Re-verify an Open PR — Steps 2, 4, 6

```bash
# Step 2 / Step 4, reverify only: comment a stale open PR once per stale pair, then sync the
# worktree to the PR head before review. $PR_HEAD is call 3's headRefOid.
MARK="<!-- orchestrate-epic:stale-verdict $PR_HEAD $(git rev-parse "origin/$BASE") -->"
gh api "repos/$REPO/issues/$N/comments" --paginate --slurp --jq --arg me "$ME" --arg m "$MARK" \
  'add | any(.[]; .user.login==$me and (.body|startswith($m)))'   # true → already reported, skip
gh issue comment "$N" --repo "$REPO" --body "$MARK
orchestrate-epic: PR の HEAD または default branch が承認時から変わったため、承認は無効です。再検証します。"
git -C "$WT" fetch origin "$BRANCH"
if [ "$(git -C "$WT" rev-parse HEAD)" != "$PR_HEAD" ]; then
  git -C "$WT" merge-base --is-ancestor HEAD "$PR_HEAD" \
    && git -C "$WT" merge --ff-only "$PR_HEAD" \
    || { echo "worktree and PR head diverged — stop and tell the user" >&2; exit 1; }
fi
# then upsert the state comment: head_sha=$PR_HEAD, reviewed_sha/verified_base=none

# Step 6, every review: pin the base, integrate it if HEAD does not already contain it
git -C "$WT" fetch origin "$BASE"
REVIEW_BASE=$(git -C "$WT" rev-parse "origin/$BASE")
if ! git -C "$WT" merge-base --is-ancestor "$REVIEW_BASE" HEAD; then
  if [ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ] \
     && git -C "$WT" merge --no-ff --no-edit -m "Merge $BASE into $BRANCH" "$REVIEW_BASE"; then
    : # then upsert the state comment's head_sha to $(git -C "$WT" rev-parse HEAD)
  else
    git -C "$WT" merge --abort 2>/dev/null || true
    # Dirty tree or conflict: no review this pass. Hand "merge $REVIEW_BASE and resolve the
    # conflicts" to a fresh worker as a blocking finding — a fix cycle, SKILL.md Step 6.
  fi
fi
git -C "$WT" add -N .
REVIEW_HEAD=$(git -C "$WT" rev-parse HEAD)
```

A merge, never a rebase: a branch that already has a PR must move forward without a force-push, and the merge commit is exactly the combination the reviewer and `CHECKS_SET` then evaluate.

## §3 Ship an Approved Issue — Step 7

`WT` is the worktree path; `BRANCH` is the branch selected for this Issue in Step 4 — `feat/issue-<N>` normally, or its state-comment-recorded `redo` branch when one applies.
Every sub-step is guarded so a mid-failure rerun resumes instead of erroring: commit only when work is left uncommitted, push is repeat-safe, create the PR only when none exists for the branch.

```bash
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)   # same resolution as §1.5 — never hardcode main

# 1. Inspect what ships — input for the secret screen
git -C "$WT" add -N .                                      # intent-to-add: makes untracked files diff-visible (content stays unstaged)
git -C "$WT" status --short
git -C "$WT" diff "$(git -C "$WT" merge-base "origin/$BASE" HEAD)"   # uncommitted changes plus the worker's own commit(s), without post-branch main noise; origin/$BASE, never the local default branch, which this loop never updates
git -C "$WT" fetch origin "$BRANCH" 2>/dev/null
git -C "$WT" rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1 && echo "PUSHED EXTERNALLY — flag to the user"   # succeeds only if the branch reached the remote before this step pushed it

#    A reverify Issue's branch is on the remote by design — the flag above applies only when no PR
#    for this branch was known to this round.

# Read the recorded state once. HEAD_SHA is the state comment's head_sha — the worker's report
# value, advanced whenever the Publisher commits itself (Step 6's integration merge, the fallback
# commit below) — not the original worker report, which a promoted commit has superseded.
ME=$(gh api user --jq .login)   # same resolution as §1.5 / §2.5
STATE_BODY=$(gh api "repos/$REPO/issues/$N/comments" --paginate --slurp --jq --arg me "$ME" \
  'add | [.[]|select(.user.login==$me and (.body|startswith("<!-- orchestrate-epic-state -->")))][-1].body // empty')
field() { printf '%s' "$STATE_BODY" | sed -nE "s/^- $1:[[:space:]]*(.*)\$/\\1/p" | head -n1; }
HEAD_SHA=$(field head_sha)

# 2. Stage and commit — skip when HEAD already equals the recorded HEAD_SHA or reviewed_sha
# (non-empty, not UNKNOWN/none) AND none of the worker's CHANGED_FILES paths still has an
# uncommitted change. A reverify Issue has no worker report this round, so its CHANGED_FILES list
# is empty. The worker's commit contract is supposed to cover everything it changed, but if any of
# those paths is still dirty, shipping HEAD alone would drop reviewed work; commit the remainder
# here instead. Otherwise `reset` first, to undo sub-step 1's `add -N .` — without it, an untracked
# file Step 6's reviewer left behind while running CHECKS_SET in this same worktree (a cache dir, a
# lockfile) stays intent-to-add in the index and would ride into a bare `git commit`, which is why
# this sub-step stages only the worker's own CHANGED_FILES paths. Stage exactly those paths — never
# `add -A`/`add -u`, which would also pick up that same reviewer-left untracked or in-place-modified
# state. A secret-screen hit never reaches this sub-step: it exits this Issue after sub-step 1,
# so nothing from that Issue is staged or committed here — excluding the flagged path and
# committing the rest is not an option, since the flagged content may already be in HEAD.
# A commit made here moves HEAD off reviewed_sha; sub-step 3's gate catches that and sends the
# Issue back for re-review rather than shipping a commit the reviewer never saw.
REVIEWED_SHA=$(field reviewed_sha)
VERIFIED_BASE=$(field verified_base)
CUR=$(git -C "$WT" rev-parse HEAD)
if { { [ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "UNKNOWN" ] && [ "$HEAD_SHA" != "none" ] && [ "$CUR" = "$HEAD_SHA" ]; } \
     || { [ -n "$REVIEWED_SHA" ] && [ "$REVIEWED_SHA" != "none" ] && [ "$CUR" = "$REVIEWED_SHA" ]; }; } \
   && [ -z "$(git -C "$WT" status --porcelain -- <CHANGED_FILES paths from the worker report>)" ]; then
  : # nothing left to commit — proceed to the verdict gate
else
  git -C "$WT" reset
  git -C "$WT" add -- <CHANGED_FILES paths from the worker report>
  if ! git -C "$WT" diff --cached --quiet; then   # never run an empty commit
    git -C "$WT" commit -m "$(cat <<'EOF'
<type>(<scope>): <summary derived from the Issue title>

<1-3 lines: what and why, from the worker summary>

Refs #<N>
EOF
)"
    # Promote the fallback commit: upsert the state comment's head_sha to it (§2.5), so a re-entry
    # after sub-step 3's re-review finds HEAD == head_sha and skips this sub-step instead of
    # attempting a second, empty commit.
    HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
  fi
fi

# 3. Verdict freshness gate — after sub-step 2 has frozen the committed artifact, before any check,
#    push, or PR. The recorded APPROVE is bound to exactly (reviewed_sha, verified_base), the values
#    SKILL.md Step 6 wrote; a HEAD or default branch that moved since makes the verdict stale and
#    none of sub-steps 4-6 may run for that Issue. A fallback commit from sub-step 2 moves HEAD off
#    reviewed_sha and is caught here. $REVIEWED_SHA / $VERIFIED_BASE were read from the §2.5 state
#    comment before sub-step 2; "none" means no live approval exists. This is the same pair #145's merge request will
#    send as its expected head SHA, so a HEAD that changes between this comparison and the merge
#    fails that request instead of merging an unreviewed commit.
git -C "$WT" fetch origin --prune
if [ -z "$REVIEWED_SHA" ] || [ "$REVIEWED_SHA" = "none" ] \
   || [ -z "$VERIFIED_BASE" ] || [ "$VERIFIED_BASE" = "none" ] \
   || [ "$(git -C "$WT" rev-parse HEAD)" != "$REVIEWED_SHA" ] \
   || [ "$(git -C "$WT" rev-parse "origin/$BASE")" != "$VERIFIED_BASE" ]; then
  # Stale or missing verdict: reset reviewed_sha/verified_base to none and go back to SKILL.md
  # Step 6's staleness re-verification pass (at most one per Issue per round), which re-pins
  # origin/$BASE, re-reviews, rebinds the pair — then rerun Step 7 from sub-step 3. Do not check,
  # push, or open a PR from here.
  echo "STALE VERDICT — reviewed_sha=$REVIEWED_SHA verified_base=$VERIFIED_BASE; re-review before shipping" >&2
  exit 1
fi

# 4. Run CHECKS_SET's runnable entries once, against the just-committed state — the Publisher-side
# check run required by #143. $CHECKS_SET_RUNNABLE is CHECKS_SET filtered to `runnable` entries,
# newline-delimited compact JSON as commands §1.6 produces (one object per line: {workdir, env, command}).
# Each `run:` block is trusted input — it comes from a workflow file on the repository's own default
# branch, the same trust boundary already extended to a worker's own commits.
CHECK_FAILED=0
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  WORKDIR=$(jq -r '.workdir // ""' <<<"$entry")
  COMMAND=$(jq -r '.command' <<<"$entry")
  ENV_EXPORTS=$(jq -r '.env // {} | to_entries | map("export \(.key)=\(.value|@sh)") | join("; ")' <<<"$entry")
  OUTPUT=$(cd "$WT/${WORKDIR:-.}" && eval "${ENV_EXPORTS:+$ENV_EXPORTS; }$COMMAND" 2>&1)
  STATUS=$?
  if [ "$STATUS" -ne 0 ]; then
    CHECK_FAILED=1
    printf 'RED (exit %s): %s\n%s\n' "$STATUS" "$COMMAND" "$OUTPUT"   # capture for the Issue comment below
  fi
done <<<"$CHECKS_SET_RUNNABLE"
if [ "$CHECK_FAILED" -ne 0 ]; then
  # Treat exactly like a secret-screen hit — this actually stops sub-steps 5-6, it is not only a
  # comment. Restore the worktree to exactly what the worker committed first: a failed check can
  # leave $WT dirty (build output, a partial lockfile write), and Step 4 reuses this same worktree on
  # the next dispatch, Step 6 re-runs `add -N .` over it — neither should see check-run leftovers as
  # if they were new changes.
  git -C "$WT" reset --hard "$REVIEWED_SHA"   # == HEAD here, guaranteed by the sub-step 3 gate
  git -C "$WT" clean -fd
  # Post the failing command(s), exit code, and captured output as a comment on the Issue, upsert
  # the state comment's unresolved_blockers (SKILL.md Step 7), leave loop:in-progress in place, and
  # move on to the next Issue in the round — do not reach sub-step 5 below for this Issue.
elif ! git -C "$WT" fetch origin "$BASE" \
     || [ "$(git -C "$WT" rev-parse "origin/$BASE")" != "$VERIFIED_BASE" ] \
     || [ "$(git -C "$WT" rev-parse HEAD)" != "$REVIEWED_SHA" ]; then
  # 5a. Publication gate — sub-step 3's fetch ran before CHECKS_SET, so a base that advanced
  # (or a HEAD that moved) while the checks ran is only visible to a fresh fetch here. Treat it
  # exactly like a sub-step 3 mismatch: no push, no PR; reset reviewed_sha/verified_base to none
  # and return the Issue to SKILL.md Step 6's re-verification pass. Clear check-run leftovers
  # first, without moving HEAD, so the re-review does not see them as new changes.
  git -C "$WT" reset --hard HEAD
  git -C "$WT" clean -fd
  echo "STALE VERDICT AFTER CHECKS — base or HEAD moved; re-verify before shipping" >&2
else
  # 5. Push (repeat-safe), then create the PR — only if none exists yet for this branch
  SCRIPTS="<create-pr skill dir>/scripts"
  git -C "$WT" push -u origin "$BRANCH"
  gh pr list --repo "$REPO" --head "$BRANCH" --state all --json number   # non-empty → PR exists: bash "$SCRIPTS/create-linked-pr.sh" --repo "$REPO" --link <number>, skip creation
  if ! REFS=$(cd "$WT" && bash "$SCRIPTS/issue-refs.sh" "origin/$BASE"); then
    # Exit 3 is a CONFLICT: park the Issue like a red check run, SKILL.md Step 7.
    # Never create the PR and keep loop:in-progress.
    echo "$REFS"
  else
    # $REFS holds the closing line for the body, SKILL.md Step 7
    bash "$SCRIPTS/create-linked-pr.sh" --repo "$REPO" --head "$BRANCH" --base "$BASE" --title "<Issue title>" --body-file - <<'EOF'
## Summary
<worker summary, condensed>

## Check evidence
<CHECKS and CRITERIA sections from the worker report>

## Review
- reviewed_sha: <$REVIEWED_SHA>
- verified_base: <$VERIFIED_BASE>
- Reviewer nits and resolution: <each nit from every review pass, `<file>:<line> — <nit> -> <how it was resolved, citing the fix commit>`; or なし>

<closing line from issue-refs.sh or SKILL.md Step 7>
Part of Epic #<EPIC>
EOF

    # 6. Clear the marker
    gh issue edit "$N" --repo "$REPO" --remove-label "loop:in-progress"
  fi
fi
```

Secret screen, run before step 2 above: the commit skill's Step 2 patterns against the status paths and diff — `.env*`, `*.pem`, `*.key`, `id_rsa*`, `*credentials*`, `*secret*`, `*.p12`, `service-account*.json`; `AKIA[0-9A-Z]{16}`, private-key headers, `gh[pousr]_[A-Za-z0-9]{20,}`, `\bsk-[A-Za-z0-9_-]{20,}`, `xox[baprs]-`, literal values assigned to `password`/`token`. Any hit stops this Issue before sub-step 2: run `git -C "$WT" reset` only to drop sub-step 1's intent-to-add entries from the index, stage and commit nothing, post the finding as a comment on the Issue, upsert the state comment's `unresolved_blockers`, and park it per SKILL.md Step 7 — no commit, no check run, no push, no PR for that Issue, and never ship the remaining files without the flagged one.

## §4 Cleanup After Merge — Step 8 rescan

Only for an Issue that is **closed** with a **merged** PR:

```bash
git -C "$WT" status --short   # must be clean; if not, report it instead of forcing
git worktree remove "$WT"
git branch -d "$BRANCH"       # -d refuses if unmerged, which is the point
git worktree prune
```
