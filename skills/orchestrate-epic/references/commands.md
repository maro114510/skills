# Command Reference

Read only the section for the step you are on. Commands run from the main checkout unless `git -C` targets a worktree.
`REPO` is `owner/repo`; `EPIC` is the Epic Issue number.

## §1 Load State — Step 2

Four `gh` calls, whatever the child count. Never loop `gh issue view` or a comment read per child: that payload embeds every blocker's full title and URL, so both the call count and the response size scale with the Epic. No call reads a label: a child's state comes from its branches, PRs, and orchestrate-epic comments alone, and a label left on an Issue by an earlier version of this skill is ignored.

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

# 2. Dependency edges, open Tn AND open Tn.m grandchildren of any container Tn.
#    CONTAINERS is the set of Tn numbers from call 1 that have a non-empty grandchildren list.
EPIC="$EPIC" CONTAINERS="$CONTAINERS" gh issue list --repo "$REPO" --state open --limit 200 \
  --json number,blockedBy,parent \
  --jq --argjson containers "${CONTAINERS:-[]}" \
  '[.[]|select(.parent.number == (env.EPIC|tonumber) or ([.parent.number] | inside($containers)))
        |{n:.number,
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

# 4. The orchestrate-epic comments of every open dispatchable Issue — every open non-container Tn
#    and every open Tn.m — in ONE aliased GraphQL query, so the call count stays at one whatever the
#    Epic size. OPEN_ISSUES is the JSON array of those numbers, from calls 1 and 2; skip this call
#    when it is empty, since a query with no field is invalid. Define §1.5's ME and OE_JQ in this
#    same call. Each line is one Issue:
#      {n, total, state:{id,updated_at,body}|null, start:{created_at,body}|null,
#       rejected:{created_at}|null, signals:[human_comments-shaped objects]}
#    — the latest state comment, start comment, and rejection comment this identity posted, and the
#    trusted human comments created after the state comment's updated_at, or after the rejection
#    comment's created_at when no state comment exists; [] when neither exists, since such an Issue
#    can be neither parked nor rejected. The jq definitions are the same ones marker_comment and
#    human_comments use, so both paths classify identically. pipefail makes a gh failure, including
#    a GraphQL error, stop the run instead of reading as "no comments".
FIELDS='comments(first: 100) { totalCount nodes { databaseId createdAt updatedAt authorAssociation author { __typename login } body } }'
QUERY="query(\$owner: String!, \$repo: String!) { repository(owner: \$owner, name: \$repo) { $(
  jq -r --arg f "$FIELDS" '.[] | "i\(.): issue(number: \(.)) { number \($f) }"' <<<"$OPEN_ISSUES") } }"
COMMENTS=$(set -o pipefail
  gh api graphql -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO_NAME" |
    jq -c --arg me "$ME" "$OE_JQ"'
      .data.repository | to_entries[] | .value
      | (.comments.nodes | map(oe_rest)) as $c
      | ($c | oe_latest($me; "<!-- orchestrate-epic-state -->")) as $state
      | ($c | oe_latest($me; "orchestrate-epic: rejected")) as $rej
      | {n: .number, total: .comments.totalCount,
         state: ($state | if . then {id, updated_at, body} else null end),
         start: ($c | oe_latest($me; "orchestrate-epic: 実装を開始しました")
                    | if . then {created_at, body} else null end),
         rejected: ($rej | if . then {created_at} else null end),
         signals: (($state.updated_at // $rej.created_at) as $since
                   | if $since then [$c | oe_human($since)] else [] end)}') \
  || { echo "comment read failed — stop and report, do not classify" >&2; exit 1; }
```

Call 4 is complete only when it returns exactly one line per number in `OPEN_ISSUES`; fewer means the read is partial, so stop rather than classify. An Issue whose `total` exceeds 100 has comments beyond the first page, so its projection can miss the latest state comment: discard that Issue's line and read it with §1.5's paginated REST helpers instead — `marker_comment` for the state, start, and rejection markers, and `human_comments` for the signals, with the same window. Only those Issues cost an extra call. A rejected Issue's check in SKILL.md Step 2 additionally drops every signal not created after `rejected.created_at`, since its window is the later of the two timestamps.

`--jq` filters client-side, so only the projection reaches the context. `tokens: true` is the leftover-`{{Tn}}`/`{{Tn.m}}` signal Step 2 escalates on — it costs nothing, unlike carrying the Epic body. `CONTAINERS` is derived from call 1's output before call 2 runs, via `[.children[]|select(.grandchildren|length>0)|.n]` — a `Tn` with a non-empty `grandchildren` array in call 1 is a container; every other `Tn` is a leaf and is never expected to have children of its own. Step 2's depth cap in create-github-issues means a `Tn.m` never has grandchildren of its own, so this single extra nesting level is always enough — no recursion needed.

Calls 2 and 3 page the repository's issues and PRs before filtering, so `--limit` truncates silently on a busy repository. Cross-check call 2 against call 1's `Tn` and grandchild lists, flattened: if an open `Tn` or `Tn.m` is missing from call 2, the read is incomplete — raise the limit and re-run rather than classifying on a partial board. Do not apply the same reasoning to call 3: a local `feat/issue-<n>` branch with no row there is not itself evidence of a truncated page — an Issue can legitimately be `ready` or `in-progress` with a branch that has no PR yet, since Step 7 is what creates one.

Branch and worktree recovery stays local and free:

```bash
git fetch origin --prune
git branch --list "feat/issue-*"
git branch -r --list "origin/feat/issue-*"   # a remote branch counts as "a branch anywhere" too, SKILL.md Step 2
git worktree list
```

Post-merge health, one more read whatever the child count: run `bash "<skill-dir>/scripts/base-health.sh" "$REPO" "$EPIC"`, §3.7, once, and keep its output for Step 3. When it prints an `issue=` line and a `status=` other than `CLEAR`, `PASS`, or `HANDLED`, that closed Issue is `verifying`, never `done`, SKILL.md Step 2. Any non-zero exit stops the run, like every other failed read here.

PR state decoding: `OPEN` → awaiting-merge only when its `sha` and the current base match the state comment's bound pair and its `review_evidence` is present, §2.5; otherwise reverify, including a matching pair with `review_evidence` `none` or absent, SKILL.md Step 2; `MERGED` → merged; `CLOSED` with `mergedAt: null` → rejected, escalate.

Fetch the Epic body itself, via `--jq .body`, only on the fallback path below, or when a leftover token needs to be shown to the user.

Fallback when `subIssues`/`blockedBy` are unavailable — older gh, GHES, or the GraphQL call itself errors: parse the Epic body's "Dependencies & Parallel Execution Plan" section — Mermaid edges `X --> Y` mean Y depends on X; the wave-table variant lists each row's `#<number>` dependencies — then fetch each `Tn`'s state individually. For a `Tn` that turned out to be a container, its own body carries the same kind of section for its `Tn.m` children — parse it the same way, one level down. Tell the user the run is on this fallback, since a hand-edited body can drift from the real relations.

## §1.5 Entry Gate — Step 3

```bash
# Resolve this run's own identity once — every marker lookup below trusts only a comment this identity
# posted, never merely one that starts with the right prefix. On a public repo anyone can comment
# "<!-- orchestrate-epic:run-plan -->..." to spoof a marker and suppress the real lifecycle comment,
# or get the state upsert to read and edit a comment they planted instead of the real state.
ME=$(gh api user --jq .login)

# Shared jq definitions over REST-shaped comment arrays, used by marker_comment and human_comments
# below and by §1's call 4, so a GraphQL read and a REST read reach the same answer. oe_rest maps a
# GraphQL comment node onto the REST fields, restoring the `[bot]` suffix REST puts on a bot login and
# GraphQL omits; oe_latest is the latest comment by $me whose body starts
# with $m, or null; oe_human is the trusted human-signal filter documented on human_comments;
# oe_merge_authorized is the merge-grant rule documented on merge_authorized.
OE_JQ='
  def oe_rest: {id: .databaseId, created_at: .createdAt, updated_at: .updatedAt,
                author_association: .authorAssociation, user: {login: ((.author.login // "") + (if .author.__typename == "Bot" then "[bot]" else "" end))}, body};
  def oe_latest($me; $m): [.[] | select(.user.login == $me and ((.body // "") | startswith($m)))][-1];
  def oe_human($since):
    .[]
    | select(.created_at > $since)
    | select(.author_association == "OWNER" or .author_association == "MEMBER"
             or .author_association == "COLLABORATOR")
    | (.body // "") as $b
    | select(($b | startswith("orchestrate-epic") or startswith("<!--")) | not)
    | [$b | split("\n")[] | gsub("^\\s+|\\s+$"; "") | select(. != "")] as $lines
    | select($lines | length > 0)
    | {id, created_at, author: .user.login, body: $b,
       command: (if all($lines[]; . == $lines[0])
                    and ($lines[0] | IN("epic-approve", "epic-retry", "epic-redo", "epic-drop",
                                        "epic-auto-merge", "epic-revoke-auto-merge", "epic-release"))
                 then $lines[0] else null end)};
  def oe_merge_authorized:
    any(.[]; .command == "epic-approve")
    and ([.[] | select(.command == "epic-auto-merge" or .command == "epic-revoke-auto-merge")]
         | sort_by(.created_at, .id) | last | .command) == "epic-auto-merge";
'

# The one marker-comment lookup, used here and by §2.5, §2.6, and §3. Prints the latest comment on
# Issue $1 posted by $ME whose body starts with $2, as one JSON object; prints nothing and exits 0
# when none matches; exits non-zero when gh, jq, or $ME fails. --paginate --slurp fetches every
# page (an Epic can carry more comments than one page holds) and `add` flattens the pages before
# [-1] picks the latest. gh rejects slurping combined with its own jq filter flag, so the filter
# runs in jq, which §1.6 already requires; pipefail keeps a gh failure from reading as "no comment".
# Shell state does not persist between tool calls: define it, OE_JQ, ME, and REPO in the same call as each lookup.
marker_comment() (
  set -o pipefail
  [ -n "$ME" ] || { echo "marker_comment: ME is empty" >&2; exit 1; }
  gh api "repos/$REPO/issues/$1/comments" --paginate --slurp |
    jq -c --arg me "$ME" --arg m "$2" "$OE_JQ"'add // [] | oe_latest($me; $m) // empty'
)

# The one human-signal lookup, used here and, for an Issue §1's call 4 cannot cover, by SKILL.md
# Step 2's un-parking and rejected checks.
# Prints every trusted human comment on Issue $1 created strictly after the ISO-8601 timestamp $2,
# oldest first, one compact JSON object per line: {id, created_at, author, body, command}.
# Trusted means author_association OWNER, MEMBER, or COLLABORATOR, and a body that does not start
# with `orchestrate-epic` or `<!--` (A6/A7, docs/design/skills-remediation-policy.md). `command` is
# set only when every non-blank line, trimmed of surrounding whitespace, is exactly the same one of
# epic-approve, epic-retry, epic-redo, epic-drop, epic-auto-merge, epic-revoke-auto-merge,
# epic-release, in lowercase; otherwise it is null and the comment
# is context, never a decision. "let's not epic-retry yet", "EPIC-RETRY", "epic-retry please", and
# a comment mixing two different commands therefore all carry command: null. created_at, not
# updated_at: a comment edited into a command after the fact does not move into the window. A blank
# comment is skipped. Prints nothing and exits 0 when none matches; exits non-zero when gh or jq fails.
human_comments() (
  set -o pipefail
  gh api "repos/$REPO/issues/$1/comments" --paginate --slurp |
    jq -c --arg since "$2" "$OE_JQ"'add // [] | oe_human($since)'
)

# Find the Run Plan comment. A failed lookup stops here — never read it as "no Run Plan" and post one
RUN_PLAN=$(marker_comment "$EPIC" '<!-- orchestrate-epic:run-plan -->') \
  || { echo "Run Plan lookup failed — stop and report, do not post a Run Plan" >&2; exit 1; }

# Post it only when the lookup succeeded with empty output (create only — never edit/replace an existing Run Plan)
[ -n "$RUN_PLAN" ] || { gh issue comment "$EPIC" --repo "$REPO" --body "$RUN_PLAN_BODY"; exit; }   # Step 3 exits after posting, with gh's status

# Check for approval: a trusted `epic-approve` comment created after the Run Plan comment. A comment
# posted before the Run Plan, or by any other author_association, never approves. This gate reads no
# label. A failed lookup stops the run; it never reads as approved or as not approved.
PLAN_AT=$(jq -r '.created_at' <<<"$RUN_PLAN")
SIGNALS=$(human_comments "$EPIC" "$PLAN_AT") \
  || { echo "approval lookup failed — stop and report, do not dispatch" >&2; exit 1; }
[ "$(jq -s 'any(.[]; .command == "epic-approve")' <<<"$SIGNALS")" = "true" ] || { echo "no epic-approve after the Run Plan — exit at the gate" >&2; exit 0; }

# The one merge-authorization check, SKILL.md Step 3 "Merge Authorization". Run it fresh,
# immediately before every merge request, never once per round, so an epic-revoke-auto-merge
# posted mid-round stops every later merge. Prints `granted` only when the Epic's trusted signals
# after the Run Plan — the same window and trust check as epic-approve above — contain an
# epic-approve AND the latest of epic-auto-merge / epic-revoke-auto-merge, by created_at, is
# epic-auto-merge; prints `not-granted` otherwise, including when no Run Plan exists. epic-approve
# alone authorizes dispatch, shipping, and PR creation, never a merge. Exits non-zero when any read
# fails; the caller then treats merging as not authorized, since an unreadable grant is never one:
#   AUTH=$(merge_authorized) || AUTH=unreadable; [ "$AUTH" = granted ] || <do not merge>
# Define OE_JQ, ME, REPO, EPIC, marker_comment, and human_comments in this same call.
merge_authorized() (
  set -o pipefail
  PLAN=$(marker_comment "$EPIC" '<!-- orchestrate-epic:run-plan -->') || exit 1
  [ -n "$PLAN" ] || { echo not-granted; exit 0; }
  AT=$(jq -r '.created_at' <<<"$PLAN") || exit 1
  SIG=$(human_comments "$EPIC" "$AT") || exit 1
  jq -rs "$OE_JQ"'if oe_merge_authorized then "granted" else "not-granted" end' <<<"$SIG"
)

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

# Completion exit comment (Step 10) — marked the same way as the Run Plan, so a rerun after completion
# doesn't post a second one; $EXIT_COMMENT_BODY must start with <!-- orchestrate-epic:completion -->
COMPLETION=$(marker_comment "$EPIC" '<!-- orchestrate-epic:completion -->') \
  || { echo "completion lookup failed — stop and report, do not post an exit comment" >&2; exit 1; }
[ -n "$COMPLETION" ] || gh issue comment "$EPIC" --repo "$REPO" --body "$EXIT_COMMENT_BODY"
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

Fast path with `yq` (mikefarah, v4+) and `jq`, streaming each workflow's content straight through both — no temp file, so two Publisher sessions on the same repo never collide on one. Both are required dependencies for this section and for the check-run loop in §3, and `jq` also for §1.5's marker-comment lookup, alongside the `gh`/`git` this file already assumes:

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

## §1.7 Freeze Check and Epic Ledger — Steps 3 to 7

`<skill-dir>` is this skill's base directory, which the harness states on invocation. The script resolves this run's identity itself and reads every page of the Epic's comments; it never posts or edits. Pass reservations only for what is about to spawn, SKILL.md Step 3's "Freeze and Release":

```bash
FREEZE=$(bash "<skill-dir>/scripts/epic-freeze.sh" "$REPO" "$EPIC" [worker_dispatches=<n>] [reviewer_passes=<n>] [fix_cycles=<n>])
RC=$?
STATUS=$(sed -n 's/^status=//p' <<<"$FREEZE")
RESERVE=$(sed -n 's/^reserve=//p' <<<"$FREEZE")
# RC 1 / UNREADABLE → stop and report; act as frozen, post nothing
# FROZEN            → render "Frozen Epic" and exit; post nothing, the freeze comment already notified once
# RELEASE           → reset the ledger below, then run the check again
# CLEAR, no ledger  → create the ledger below, then run the check again
# CLEAR, exceed     → post the freeze comment below; spawn nothing, stop the round
# CLEAR, ok         → write the reserved counts below, then spawn
```

Output lines: `status=`, `reason=`, `freeze_id=`, `release_id=`, `ledger_id=`; when a ledger exists, `ledger_release=` and one `<counter>=<used>/<bound>` per counter; `reserve=ok|exceed` only on `CLEAR` with a reservation. The reason names every counter a reservation would exceed, as `<counter> <used> + <n> > <bound>`. `--snapshot <file|-> --me <login>` classifies a saved comment array instead of calling `gh`, which is how `scripts/test-epic-freeze.bats` exercises every rule.

Ledger writes, in the same call as the check so `$FREEZE` is the result just read. `N` is the count of dispatchable Issues not `done` from this invocation's Step 2, at least 1:

```bash
# $1 release id or none, then used and bound for worker_dispatches, reviewer_passes, fix_cycles
render_ledger() {
  printf '%s\n' '<!-- orchestrate-epic:ledger -->' 'orchestrate-epic ledger:' "- release: $1" \
    "- worker_dispatches: $2 / $3" "- reviewer_passes: $4 / $5" "- fix_cycles: $6 / $7"
}
# Edits the ledger in place, or creates it when none exists. A failed write stops the run — never spawn after one.
upsert_ledger() {
  LEDGER_ID=$(sed -n 's/^ledger_id=//p' <<<"$FREEZE")
  if [ -n "$LEDGER_ID" ] && [ "$LEDGER_ID" != none ]; then
    gh api "repos/$REPO/issues/comments/$LEDGER_ID" -X PATCH -f body="$1" >/dev/null
  else
    gh issue comment "$EPIC" --repo "$REPO" --body "$1"
  fi || { echo "ledger write failed — stop and report, spawn nothing" >&2; exit 1; }
}
used()  { sed -n "s/^$1=\([0-9]*\)\/.*/\1/p" <<<"$FREEZE"; }
bound() { sed -n "s/^$1=[0-9]*\/\([0-9]*\)$/\1/p" <<<"$FREEZE"; }

# Create (CLEAR, ledger_id=none) — every counter at 0
upsert_ledger "$(render_ledger none 0 $((5 * N)) 0 $((4 * N)) 0 $((2 * N)))"

# Release (RELEASE) — counters to 0, bounds recomputed, the release recorded so it is processed once
upsert_ledger "$(render_ledger "$(sed -n 's/^release_id=//p' <<<"$FREEZE")" 0 $((5 * N)) 0 $((4 * N)) 0 $((2 * N)))"

# Reserve (CLEAR, reserve=ok) — add exactly what was reserved, W/R/F being the reserved n or 0
upsert_ledger "$(render_ledger "$(sed -n 's/^ledger_release=//p' <<<"$FREEZE")" \
  $(($(used worker_dispatches) + W)) "$(bound worker_dispatches)" \
  $(($(used reviewer_passes) + R)) "$(bound reviewer_passes)" \
  $(($(used fix_cycles) + F)) "$(bound fix_cycles)")"
```

Freeze (CLEAR, `reserve=exceed`), only from that `CLEAR` result, so a freeze is posted once: `$FREEZE_BODY` is the "Freeze Comment" template, starting with `<!-- orchestrate-epic:freeze -->`, its `- reason:` line the check's `reason=` value on one line, and its counts the ledger's current `<used> / <bound>`:

```bash
gh issue comment "$EPIC" --repo "$REPO" --body "$FREEZE_BODY" \
  || { echo "freeze comment failed — stop and report; spawn, ship, and merge nothing" >&2; exit 1; }
```

A freeze for unhealthy post-merge checks, §3.7, adds `- merge: <merge commit>` and `- health: <FAIL|UNCONFIRMED>` lines after `- reason:`; `base-health.sh` reads them to know this result already notified the human. The script reads the freeze reason back from that `- reason:` line, so a re-invoked loop reports why the Epic is frozen without any session memory. Only the latest ledger and freeze comment posted by this run's identity count; the release is the earliest trusted `epic-release` created after the latest freeze, by the same trust rule as §1.5's `human_comments`.

## §2 Dispatch Bookkeeping — Step 4

```bash
# Once per run
BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)   # same resolution as §1.5 — never hardcode main
git fetch origin "$BASE"   # once, before any worker; updates only origin/$BASE. Never switch or pull the starting checkout — other sessions may share it. On failure: stop and tell the user

# Per dispatched Issue, serially
BRANCH="feat/issue-$N"   # or the state comment's recorded epic-redo branch, such as feat/issue-$N-2
if git show-ref --verify --quiet "refs/heads/$BRANCH" \
   || git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git wt "$BRANCH"                  # existing branch: reuses its worktree, or checks it out; git wt rejects a start-point here
else
  git wt "$BRANCH" "origin/$BASE"   # new branch: starts from the fetched default branch, never the possibly stale local one
fi
# git wt prints the worktree path — capture it for the worker prompt
# The start comment is the in-flight marker SKILL.md Step 2 reads through §1's call 4: keep its
# leading "orchestrate-epic: 実装を開始しました" exactly, or a resumed run cannot find it.
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
# Define §1.5's OE_JQ and marker_comment in this same call too.

# Read the latest state comment. Empty output means none exists yet — still cycle 0. A failed
# lookup is not "none": stop instead of resuming at cycle 0 or creating a second state comment.
# Every page is read, since a long-running Issue can carry more comments than one page holds.
# $ME filters out any comment planted by someone other than this run's own identity — otherwise an
# attacker-authored marker could be read as, or overwritten as, real state.
STATE=$(marker_comment "$N" '<!-- orchestrate-epic-state -->') \
  || { echo "state comment lookup failed — stop and report, do not assume cycle 0" >&2; exit 1; }

# Upsert: re-run the lookup above in this same call, then edit the existing state comment if found, else create it
STATE_ID=$(jq -r '.id // empty' <<<"$STATE")
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
- decisions: <このIssueについて人間が下した判断。`<epic-retry|epic-redo|epic-drop>[ — <epic-redo のブランチ>] (comment <判断コメントの id>; context: <文脈コメントの id をカンマ区切り、無ければ なし>)`。なければ なし>
- review_evidence: <有効な承認がなければ none。あれば空にして、次の行から reviewed_sha の APPROVE を出した reviewer report の BEHAVIOR_CHANGE 行と CRITERIA 各行を、それぞれ先頭に 2 スペースを付けてそのまま並べる>
```

`review_evidence` is always the last field, and its value lines are indented by two spaces, so the single-line `^- <field>:` lookups in §3 never read a criterion's text as another field. The field is **present** only when an empty header is followed by at least one indented line — exactly what §3's `REVIEW_EVIDENCE` extraction returns non-empty for; `none`, a header with no lines under it, or no such field at all is not present, everywhere this skill checks it. A bound verdict looks like:

```
- review_evidence:
  BEHAVIOR_CHANGE: yes — <basis>
  1. <criterion verbatim> -> verified [behavior] — <command or input and observed result>
  2. <criterion verbatim> -> verified [static] — <file:line>
```

`cycle` counts every fix cycle from Step 6 — a fresh-worker re-dispatch for reviewer findings plus its re-review; one for blocking findings and one for nit-only findings each add 1, since the 2-cycle cap is what bounds nit resolution too, not only blocking. A staleness re-verification pass, Step 6, dispatches no worker and leaves it unchanged; so does a BLOCKED answer or FAILED retry from Step 5, and neither resets it. The one exception is an authorized `epic-retry` or `epic-redo` decision on a `parked` or `rejected` Issue, SKILL.md Step 2's un-parking check, which resets `cycle` to 0 — a human decision restarts the fix-cycle budget on purpose. Short of that, Step 6 reads it back on a resumed session so the 2-cycle cap holds across a restart instead of starting over at 0.

`decisions` holds the latest human decision only, replaced by the next one: the `epic-*` command, the `id` of the comment that carried it, and the `id`s of the trusted non-command comments posted in the same window, SKILL.md Step 2. The command comment carries nothing but the command, so the human's reasons live in those context comments; Step 4 hands their full bodies to every worker it dispatches for this Issue after an `epic-retry` or `epic-redo`, fetched by `id` so they still reach the worker after a restart, when the state comment's newer `updated_at` has moved the window past them:

```bash
gh api "repos/$REPO/issues/comments/$CONTEXT_ID" --jq '{author: .user.login, created_at, body}'
```

`pending_findings` holds the findings, blocking or nit, handed to an in-flight fix cycle — including the nits of an APPROVE, which Step 6 treats as REQUEST_CHANGES for state purposes. It is cleared by the next review result and by an `epic-retry`/`epic-redo`, and it never makes Step 2 classify the Issue `parked`; only a non-empty `unresolved_blockers` or an `epic-drop` in `decisions` does. A resumed `in-progress` Issue passes it into the fresh worker's prompt, Step 4.

`head_sha` alone is not an approval — it is written after every review, including a REQUEST_CHANGES. The bound verdict is `reviewed_sha` + `verified_base` + `review_evidence`, written in the same upsert so no reader ever sees one without the others: Step 6 sets all three only on a finding-free APPROVE that passes its "Acceptance Evidence" validation and whose pre-review pin (`REVIEW_HEAD`, `REVIEW_BASE`) still matches after the review, and resets all three to `none` on a REQUEST_CHANGES, an APPROVE carrying nits or failing validation, a park, a stale gate in Step 7, or a human `epic-retry`/`epic-redo` restart. Step 2's open-PR sanity check compares the SHAs against the PR's `headRefOid` and the current `origin/$BASE`, classifying a mismatch, or a `review_evidence` that is not present, `reverify` so §2.6 re-verifies it; Step 7's verdict gate does the same against the worktree HEAD and `origin/$BASE` before shipping; Step 8's merge request, §3.6, sends `reviewed_sha` as its expected SHA. A mismatch on either SHA, or missing evidence, means the recorded verdict cannot authorize a ship or a merge. A state comment written before `review_evidence` existed has no such line, which reads as missing evidence: its open PR is re-verified once instead of trusted.

git-wt may place worktrees outside the repo, depending on its config — always use the printed path, never an assumed `.wt/`.

## §2.6 Pin and Integrate the Base, Re-verify an Open PR — Steps 2, 4, 6

```bash
# Step 2 / Step 4, reverify only: comment a stale open PR once per stale pair, then sync the
# worktree to the PR head before review. $PR_HEAD is call 3's headRefOid.
MARK="<!-- orchestrate-epic:stale-verdict $PR_HEAD $(git rev-parse "origin/$BASE") -->"
STALE=$(marker_comment "$N" "$MARK") \
  || { echo "stale-verdict lookup failed — stop and report" >&2; exit 1; }   # §1.5's marker_comment
# REASON matches why Step 2 classified it reverify: the SHAs no longer match the bound pair, or they
# match but review_evidence is not present (§2.5), such as a state comment from before that field.
REASON="PR の HEAD または default branch が承認時から変わったため、承認は無効です。再検証します。"
# REASON="承認に受け入れ条件ごとの review 証跡が記録されていないため、承認は無効です。再検証します。"   # evidence-only case
[ -n "$STALE" ] || gh issue comment "$N" --repo "$REPO" --body "$MARK
orchestrate-epic: $REASON"   # non-empty → already reported, skip
git -C "$WT" fetch origin "$BRANCH"
if [ "$(git -C "$WT" rev-parse HEAD)" != "$PR_HEAD" ]; then
  git -C "$WT" merge-base --is-ancestor HEAD "$PR_HEAD" \
    && git -C "$WT" merge --ff-only "$PR_HEAD" \
    || { echo "worktree and PR head diverged — stop and tell the user" >&2; exit 1; }
fi
# then upsert the state comment: head_sha=$PR_HEAD, reviewed_sha/verified_base/review_evidence=none

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

`WT` is the worktree path; `BRANCH` is the branch selected for this Issue in Step 4 — `feat/issue-<N>` normally, or its state-comment-recorded `epic-redo` branch when one applies.
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
ME=$(gh api user --jq .login)   # same resolution as §1.5 / §2.5, with §1.5's OE_JQ and marker_comment defined in this call
STATE=$(marker_comment "$N" '<!-- orchestrate-epic-state -->') \
  || { echo "state comment lookup failed — stop and report, do not ship" >&2; exit 1; }
STATE_BODY=$(jq -r '.body // empty' <<<"$STATE")
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
# The reviewer's per-criterion evidence bound to REVIEWED_SHA, §2.5: the two-space-indented lines
# under an empty `- review_evidence:` header. Empty when the field is `none` or absent.
REVIEW_EVIDENCE=$(printf '%s\n' "$STATE_BODY" | sed -n '/^- review_evidence:[[:space:]]*$/,${/^  /p;}')
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
#    push, or PR. The recorded APPROVE is bound to exactly (reviewed_sha, verified_base,
#    review_evidence), the values SKILL.md Step 6 wrote; a HEAD or default branch that moved since
#    makes the verdict stale and none of sub-steps 4-5 may run for that Issue. A fallback commit
#    from sub-step 2 moves HEAD off reviewed_sha and is caught here. $REVIEWED_SHA, $VERIFIED_BASE,
#    and $REVIEW_EVIDENCE were read from the §2.5 state comment before sub-step 2; "none" or empty
#    evidence means no live approval exists. This is the same pair Step 8's merge request, §3.6,
#    sends as its expected head SHA, so a HEAD that changes between this comparison and the merge
#    fails that request instead of merging an unreviewed commit.
git -C "$WT" fetch origin --prune
if [ -z "$REVIEWED_SHA" ] || [ "$REVIEWED_SHA" = "none" ] \
   || [ -z "$VERIFIED_BASE" ] || [ "$VERIFIED_BASE" = "none" ] \
   || [ -z "$REVIEW_EVIDENCE" ] \
   || [ "$(git -C "$WT" rev-parse HEAD)" != "$REVIEWED_SHA" ] \
   || [ "$(git -C "$WT" rev-parse "origin/$BASE")" != "$VERIFIED_BASE" ]; then
  # Stale or missing verdict: reset reviewed_sha/verified_base/review_evidence to none and go back to SKILL.md
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
  # Treat exactly like a secret-screen hit — this actually stops sub-step 5, it is not only a
  # comment. Restore the worktree to exactly what the worker committed first: a failed check can
  # leave $WT dirty (build output, a partial lockfile write), and Step 4 reuses this same worktree on
  # the next dispatch, Step 6 re-runs `add -N .` over it — neither should see check-run leftovers as
  # if they were new changes.
  git -C "$WT" reset --hard "$REVIEWED_SHA"   # == HEAD here, guaranteed by the sub-step 3 gate
  git -C "$WT" clean -fd
  # Post the failing command(s), exit code, and captured output as a comment on the Issue, upsert
  # the state comment's unresolved_blockers (SKILL.md Step 7), which is what parks it, and
  # move on to the next Issue in the round — do not reach sub-step 5 below for this Issue.
elif ! git -C "$WT" fetch origin "$BASE" \
     || [ "$(git -C "$WT" rev-parse "origin/$BASE")" != "$VERIFIED_BASE" ] \
     || [ "$(git -C "$WT" rev-parse HEAD)" != "$REVIEWED_SHA" ]; then
  # 5a. Publication gate — sub-step 3's fetch ran before CHECKS_SET, so a base that advanced
  # (or a HEAD that moved) while the checks ran is only visible to a fresh fetch here. Treat it
  # exactly like a sub-step 3 mismatch: no push, no PR; reset reviewed_sha/verified_base/review_evidence to none
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
    # Never create the PR; upsert unresolved_blockers so it stays parked.
    echo "$REFS"
  else
    # $REFS holds the closing line for the body, SKILL.md Step 7
    bash "$SCRIPTS/create-linked-pr.sh" --repo "$REPO" --head "$BRANCH" --base "$BASE" --title "<Issue title>" --body-file - <<'EOF'
## Summary
<worker summary, condensed>

## Check evidence
<CHECKS section from the worker report>

## Acceptance evidence
Gathered by the independent reviewer on reviewed_sha against verified_base; valid only while both still match. This is a snapshot taken when the PR was created; the Issue's state comment holds the evidence currently bound, and is the one every gate reads.
<$REVIEW_EVIDENCE, verbatim — never the worker's CRITERIA in its place>

## Review
- reviewed_sha: <$REVIEWED_SHA>
- verified_base: <$VERIFIED_BASE>
- Reviewer nits and resolution: <each nit from every review pass, `<file>:<line> — <nit> -> <how it was resolved, citing the fix commit>`; or なし>

<closing line from issue-refs.sh or SKILL.md Step 7>
Part of Epic #<EPIC>
EOF
    # No marker to clear: the open PR is what SKILL.md Step 2 now classifies this Issue by.
  fi
fi
```

Secret screen, run before step 2 above: the commit skill's Step 2 patterns against the status paths and diff — `.env*`, `*.pem`, `*.key`, `id_rsa*`, `*credentials*`, `*secret*`, `*.p12`, `service-account*.json`; `AKIA[0-9A-Z]{16}`, private-key headers, `gh[pousr]_[A-Za-z0-9]{20,}`, `\bsk-[A-Za-z0-9_-]{20,}`, `xox[baprs]-`, literal values assigned to `password`/`token`. Any hit stops this Issue before sub-step 2: run `git -C "$WT" reset` only to drop sub-step 1's intent-to-add entries from the index, stage and commit nothing, post the finding as a comment on the Issue, upsert the state comment's `unresolved_blockers`, and park it per SKILL.md Step 7 — no commit, no check run, no push, no PR for that Issue, and never ship the remaining files without the flagged one.

## §3.5 Merge Readiness — before every merge

`<skill-dir>` is this skill's base directory, which the harness states on invocation. `PR` is the Issue's PR number from §1's call 3, and `N` its Issue number. Run it fresh right before each merge request, after §1.5's `merge_authorized` prints `granted`, in one call that also defines §1.5's `ME`, `OE_JQ`, and `marker_comment`:

```bash
# Freeze check first, §1.7: a freeze posted mid-round, by this session or another, holds every merge
FREEZE=$(bash "<skill-dir>/scripts/epic-freeze.sh" "$REPO" "$EPIC")
[ $? -eq 0 ] && [ "$(sed -n 's/^status=//p' <<<"$FREEZE")" = CLEAR ] \
  || { echo "Epic not CLEAR — do not merge: $FREEZE" >&2; exit 4; }   # stop landing, SKILL.md Step 8
STATE=$(marker_comment "$N" '<!-- orchestrate-epic-state -->') \
  || { echo "state comment lookup failed — do not merge" >&2; exit 1; }
STATE_BODY=$(jq -r '.body // empty' <<<"$STATE")
field() { printf '%s' "$STATE_BODY" | sed -nE "s/^- $1:[[:space:]]*(.*)\$/\\1/p" | head -n1; }   # same as §3
REVIEWED_SHA=$(field reviewed_sha)
VERIFIED_BASE=$(field verified_base)
REVIEW_EVIDENCE=$(printf '%s\n' "$STATE_BODY" | sed -n '/^- review_evidence:[[:space:]]*$/,${/^  /p;}')
git fetch origin "$BASE" || { echo "base fetch failed — do not merge" >&2; exit 1; }
[ -n "$REVIEWED_SHA" ] && [ "$REVIEWED_SHA" != none ] && [ -n "$REVIEW_EVIDENCE" ] \
  || { echo "no bound verdict — do not merge" >&2; exit 1; }
# Moved base, usually an earlier merge: re-verify, never park (SKILL.md Step 3 "Landing Order")
[ "$(git rev-parse "origin/$BASE")" = "$VERIFIED_BASE" ] \
  || { echo "base moved since verified_base — do not merge; re-verify against the new base" >&2; exit 3; }
READINESS=$(bash "<skill-dir>/scripts/pr-readiness.sh" "$REPO" "$PR")
RC=$?
STATUS=$(sed -n 's/^status=//p' <<<"$READINESS")
PR_HEAD=$(sed -n 's/^head=//p' <<<"$READINESS")
[ "$RC" -eq 0 ] && [ "$STATUS" = READY ] && [ "$PR_HEAD" = "$REVIEWED_SHA" ] \
  || { echo "not merge-ready: $READINESS" >&2; exit 1; }   # hold the merge
```

The freeze check holds the merge on anything but exit 0 with `status=CLEAR`, `FROZEN`, `RELEASE`, and `UNREADABLE` alike. The next part re-checks the whole bound verdict, SKILL.md Step 6, right before the merge: `reviewed_sha` and `review_evidence` present, and `verified_base` still the current `origin/$BASE`. Only a moved base exits 3, so the caller can route it to re-verification, SKILL.md Step 3 "Landing Order", and only a freeze check that is not `CLEAR` exits 4, so the caller stops landing; every other hold exits 1. Step 8's landing pass runs the same block without the final `READY` guard, to read `$READINESS`'s `next=` and `repair=` lines for a PR that is not merge-ready; a merge itself still needs the guard, §3.6. Output is `status=`, `reason=`, `pr=`, `head=`, `next=`, and, on `next=repair`, `repair=` lines; `head=` is the PR head the snapshot was taken on, so a `READY` for a head other than the state comment's `reviewed_sha`, §2.5, classified a commit nobody reviewed and holds the merge too. Exit 1 means a required signal was unreadable — `gh` failed, a field was missing, or a connection held more than 100 nodes — and prints `status=BLOCKED`. Exit 2 is a usage error. `--snapshot <file|->` classifies a saved response of the same GraphQL query instead of calling `gh`, which is how `scripts/test-pr-readiness.bats` exercises every rule. Every check on the head counts, required or not, so a pending one waits and a failed one blocks; a repository with no PR checks at all stays `WAITING` and, after Step 8's short no-checks bound, `next=human`, so a human merges its PRs.

## §3.6 Land — Step 8

Same call setup as §3.5: §1.5's `ME`, `OE_JQ`, `marker_comment`, `human_comments`, and `merge_authorized`, §3.7's `health_gate`, plus `REPO`, `EPIC`, `BASE`, `N`, and `PR`. `HEAD_NOW` is the `head=` line §3.5 just printed. Every lookup that fails stops the action it guards; a failed read is never "nothing found".

```bash
TRUSTED='(.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR")) or .author.__typename == "Bot"'

# Repair input. The latest repair marker for this PR — the trailing space keeps PR 12 from matching 123.
REPAIR=$(marker_comment "$N" "<!-- orchestrate-epic:pr-repair $PR ") \
  || { echo "repair marker lookup failed — do not repair" >&2; exit 1; }
# The marker carries the head it repaired and `since`, the newest feedback createdAt handed over then.
# Filtering on that, not the marker's own created_at, keeps feedback posted while the repair was being
# persisted — after the read, before the marker — from falling into a gap no later repair reads.
MARKER_LINE=$(jq -r '.body // ""' <<<"${REPAIR:-null}" | head -n1)
REPAIR_HEAD=$(sed -n 's/^<!-- orchestrate-epic:pr-repair [0-9]* \([0-9a-f]*\) [^ ]* -->$/\1/p' <<<"$MARKER_LINE")
REPAIR_AT=$(sed -n 's/^<!-- orchestrate-epic:pr-repair [0-9]* [0-9a-f]* \([^ ]*\) -->$/\1/p' <<<"$MARKER_LINE")
REPAIR_AT=${REPAIR_AT:-1970-01-01T00:00:00Z}   # no marker yet: all feedback is new
KINDS=$(sed -n 's/^repair=//p' <<<"$READINESS")   # §3.5's repair= line: checks,conflict,review subset
case ",$KINDS," in *,conflict,*) CONFLICT=yes ;; *) CONFLICT=no ;; esac

# checks: failed check runs, the latest run per name, and failed commit statuses on the head.
# A GitHub Actions check run's id is its job id: the worker reads `gh run view --job <id> --log-failed`.
FAILED=$(gh api "repos/$REPO/commits/$HEAD_NOW/check-runs?filter=latest" --paginate \
      --jq '.check_runs[] | select(.status == "completed" and (.conclusion | IN("success", "neutral", "skipped") | not))
            | {name, job_id: .id, url: .html_url}' || exit 1
    gh api "repos/$REPO/commits/$HEAD_NOW/status" --paginate \
      --jq '.statuses[] | select(.state == "failure" or .state == "error") | {name: .context, url: .target_url}' || exit 1
  ) || { echo "failed-check read failed — do not repair" >&2; exit 1; }   # either read failing stops it
# This head was already handed to a worker: neither its failed checks nor a conflict on it counts again
[ "$REPAIR_HEAD" = "$HEAD_NOW" ] && { FAILED=""; CONFLICT=no; }

# review: unresolved threads and each reviewer's current CHANGES_REQUESTED review. Only trusted
# feedback created after the latest repair marker goes to the worker. A thread with no trusted
# comment, or an untrusted CHANGES_REQUESTED review, is counted as untrusted and never passed on.
# shellcheck disable=SC2016
REVIEW=$(set -o pipefail
  gh api graphql -F owner="${REPO%/*}" -F repo="${REPO#*/}" -F num="$PR" -f query='
    query($owner: String!, $repo: String!, $num: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $num) {
      reviewThreads(first: 100) { nodes { isResolved path line comments(first: 50) { totalCount nodes {
        createdAt authorAssociation author { __typename login } body } } } }
      latestOpinionatedReviews(first: 100) { nodes {
        state createdAt authorAssociation author { __typename login } body } } } } }' |
  jq -c --arg since "$REPAIR_AT" '.data.repository.pullRequest
    | def ok: '"$TRUSTED"';
      def item: {author: .author.login, created_at: .createdAt, body};
      [.reviewThreads.nodes[] | select(.isResolved == false)] as $open
    | [.latestOpinionatedReviews.nodes[] | select(.state == "CHANGES_REQUESTED")] as $changes
    | {threads: [$open[] | {path, line, truncated: (.comments.totalCount > 50),
                            comments: [.comments.nodes[] | select(ok and .createdAt > $since) | item]}
                 | select(.comments | length > 0)],
       reviews: [$changes[] | select(ok and .createdAt > $since) | item],
       untrusted: ([$open[] | select(any(.comments.nodes[]; ok) | not)] | length)
                  + ([$changes[] | select(ok | not)] | length)}') \
  || { echo "review read failed — do not repair" >&2; exit 1; }
# untrusted > 0 → next=human, no repair. No checks, no conflict, no threads, no reviews → next=human.
# The next marker's since: the newest createdAt handed over now, or the previous since when none was.
SINCE=$(jq -r --arg prev "$REPAIR_AT" '[$prev, (.threads[].comments[].created_at), (.reviews[].created_at)] | max' <<<"$REVIEW")

# Persist, then mark, then spawn: reserve (§1.7), upsert the state comment with pending_findings (§2.5),
# then post the marker. A failed marker post spawns nothing.
gh issue comment "$N" --repo "$REPO" --body "<!-- orchestrate-epic:pr-repair $PR $HEAD_NOW $SINCE -->
orchestrate-epic: PR #$PR の修復を worker に依頼しました（種類: $KINDS）。" \
  || { echo "repair marker post failed — spawn nothing" >&2; exit 1; }

# Merge Hold, once per PR head and reason — $HOLD_REASON is the template's 理由 value, $HOLD_BODY the
# "Merge Hold" template. A new reason on the same head, such as a rejected merge after a draft, posts again.
MARK="<!-- orchestrate-epic:merge-hold $PR $HEAD_NOW $(printf '%s' "$HOLD_REASON" | cksum | cut -d' ' -f1) -->"
HOLD=$(marker_comment "$N" "$MARK") || { echo "merge-hold lookup failed" >&2; exit 1; }
[ -n "$HOLD" ] || gh issue comment "$N" --repo "$REPO" --body "$MARK
$HOLD_BODY" || echo "merge-hold post failed — report it; the next pass retries" >&2
```

The merge request, in one call, with nothing between the last check and the request:

```bash
# Post-merge health first, §3.7: the previous merge's default-branch checks must have passed before
# anything else lands. 5 → wait and poll; 4 → stop landing, after posting §3.7's freeze if it says so.
health_gate || exit $?
# Settings next, so nothing slow sits between the last base read and the request.
# GraphQL, since REST omits the allow_* fields for a token without admin rights. null fails the read.
# shellcheck disable=SC2016
METHOD=$(gh api graphql -F owner="${REPO%/*}" -F repo="${REPO#*/}" \
  -f query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { mergeCommitAllowed squashMergeAllowed } }' \
  --jq '.data.repository | if (.mergeCommitAllowed | type) != "boolean" or (.squashMergeAllowed | type) != "boolean" then error("unreadable")
        elif .mergeCommitAllowed then "merge" elif .squashMergeAllowed then "squash" else "" end') \
  || { echo "merge settings unreadable — do not merge" >&2; exit 1; }
[ -n "$METHOD" ] || { echo "only rebase merging is allowed — leave it for the human" >&2; exit 1; }
AUTH=$(merge_authorized) || AUTH=unreadable
[ "$AUTH" = granted ] || { echo "merge not authorized ($AUTH) — leave it for the human" >&2; exit 1; }
# <§3.5's block here, unchanged: freeze CLEAR, bound verdict, base == verified_base (exit 3), READY on reviewed_sha>
[ "$(sed -n 's/^next=//p' <<<"$READINESS")" = merge ] || { echo "not next=merge — do not merge" >&2; exit 1; }
# The post-merge record, once every gate passed and before the last base read, so a restart right
# after the merge still checks this merge's health before the next one, and a PR the loop never
# tried to merge is never recorded. A failed write merges nothing.
HEALTH_RECORD="$(printf '%s\n' '<!-- orchestrate-epic:post-merge -->' 'orchestrate-epic post-merge:' "- pr: $PR" "- issue: $N")"
RECORD_ID=$(sed -n 's/^record_id=//p' <<<"$HEALTH")
if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != none ]; then
  gh api "repos/$REPO/issues/comments/$RECORD_ID" -X PATCH -f body="$HEALTH_RECORD" >/dev/null
else
  gh issue comment "$EPIC" --repo "$REPO" --body "$HEALTH_RECORD" >/dev/null
fi || { echo "post-merge record not written — do not merge" >&2; exit 1; }
# Last read before the request: §3.5's base check ran before its readiness query, so read the
# base ref from GitHub once more. A moved base exits 3, like §3.5.
LIVE_BASE=$(gh api "repos/$REPO/git/ref/heads/$BASE" --jq .object.sha) \
  || { echo "base ref unreadable — do not merge" >&2; exit 1; }
[ "$LIVE_BASE" = "$VERIFIED_BASE" ] || { echo "base moved since verified_base — do not merge" >&2; exit 3; }
# REST, never `gh pr merge`: it turns on auto-merge or enqueues the PR when requirements are unmet.
# sha= makes GitHub refuse with 409 if the head is no longer the reviewed commit. It checks only the
# head, never the base: a base advanced between the read above and this request is caught after the
# merge, below, unless the repository requires branches to be up to date or uses a merge queue, in
# which case GitHub itself rejects the request.
RESP=$(gh api -i -X PUT "repos/$REPO/pulls/$PR/merge" -f sha="$REVIEWED_SHA" -f merge_method="$METHOD" 2>/dev/null)
HTTP=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' <<<"$RESP")
BODY=$(sed '1,/^\r*$/d' <<<"$RESP")
case "$HTTP" in
  200) RESULT=merged;     DETAIL=$(jq -r '.sha' <<<"$BODY") ;;
  409) RESULT=head-moved; DETAIL=$(jq -r '.message // empty' <<<"$BODY") ;;
  ""|5*)  # No response or a server error, which may still have merged: read what GitHub did, never retry blindly
       DETAIL=$(gh pr view "$PR" --repo "$REPO" --json state,mergeCommit --jq 'if .state == "MERGED" then .mergeCommit.oid else "" end') || DETAIL=""
       if [ -n "$DETAIL" ]; then RESULT=merged; else RESULT=unknown; fi ;;
  *)   RESULT=rejected;   DETAIL="HTTP $HTTP: $(jq -r '.message // empty' <<<"$BODY")" ;;
esac
# Merged on the verified base? With either method the merge commit's first parent is the base it
# landed on. Anything else means the base moved inside the window above: the merged combination was
# never reviewed. A parent that cannot be read counts the same, since it is not proof.
if [ "$RESULT" = merged ]; then
  PARENT=$(gh api "repos/$REPO/commits/$DETAIL" --jq '.parents[0].sha') || PARENT=""
  [ "$PARENT" = "$VERIFIED_BASE" ] || { RESULT=merged-unverified-base; DETAIL="$DETAIL (first parent ${PARENT:-unreadable}, verified_base $VERIFIED_BASE)"; }
fi

# Record before anything else merges — once per PR, reviewed_sha, and result. $RESULT_BODY is the "Merge Result"
# template. A failed record stops landing: no further merge this invocation.
MARK="<!-- orchestrate-epic:merge-result $PR $REVIEWED_SHA $RESULT -->"
DONE=$(marker_comment "$N" "$MARK") || { echo "merge-result lookup failed — stop landing" >&2; exit 1; }
[ -n "$DONE" ] || gh issue comment "$N" --repo "$REPO" --body "$MARK
$RESULT_BODY" || { echo "merge result not recorded — stop landing" >&2; exit 1; }

# merged-unverified-base: freeze the Epic so no further merge lands on an unverified default branch.
# Never revert. Post the freeze comment only from CLEAR, §1.7, with this reason on its `- reason:` line.
if [ "$RESULT" = merged-unverified-base ]; then
  FREEZE=$(bash "<skill-dir>/scripts/epic-freeze.sh" "$REPO" "$EPIC")
  [ "$(sed -n 's/^status=//p' <<<"$FREEZE")" = CLEAR ] && FREEZE_REASON="PR #$PR merged on unverified base: $DETAIL"
  # → §1.7's freeze comment with $FREEZE_REASON, then stop landing (exit 4 either way)
  exit 4
fi
```

`merged-unverified-base` closes the one gap the head-only `sha=` leaves: the default branch advancing between the last base read and the request. Prevention there is only atomic with the repository's up-to-date requirement or a merge queue, which this loop never requires, so the loop detects it on the merge commit instead and freezes before anything else lands. The result marker names `reviewed_sha` and the result, so an earlier `rejected` or `unknown` never suppresses the record of a later attempt that merged, on the same verdict or a renewed one. A merged PR closes its Issue through the PR body's `Closes` line; with `Related`, the Issue stays open and Step 2's merged-PR-but-Issue-open check handles it. The post-merge record is written only after the grant and readiness passed. If the request still does not merge — a moved base, a 409, a rejection — the record names a PR that is not merged, which §3.7 reads as `CLEAR`.

## §3.7 Post-merge Health — Steps 2 and 8

`<skill-dir>` is this skill's base directory. `scripts/base-health.sh` reads this loop's sticky post-merge record on the Epic, marker `<!-- orchestrate-epic:post-merge -->`, which §3.6 upserts before every merge request with the PR and Issue it is about to merge. It then reads that PR's merge commit and every check on it. It never posts or edits.

```bash
# Sets HEALTH; returns 0 proceed, 5 wait, 4 stop landing. On a freeze it also prints
# `freeze_merge=`, `freeze_health=`, and `freeze_reason=` to stdout, since shell state ends with
# this call. Then, in the next call, post §1.7's freeze comment — only when §1.7's check prints
# status=CLEAR, so it is posted once — with `- reason: <freeze_reason>`, `- merge: <freeze_merge>`,
# and `- health: <freeze_health>`, each copied verbatim; a `- merge:` or `- health:` line that is
# not exactly the value never matches, and every epic-release would freeze the Epic again. Then stop
# landing. Never revert.
health_gate() {
  local rc next status
  FREEZE_REASON="" FREEZE_MERGE=""
  HEALTH=$(bash "<skill-dir>/scripts/base-health.sh" "$REPO" "$EPIC")
  rc=$?
  next=$(sed -n 's/^next=//p' <<<"$HEALTH")
  status=$(sed -n 's/^status=//p' <<<"$HEALTH")
  [ "$rc" -eq 0 ] || { echo "post-merge health unreadable — merge nothing, stop landing: $HEALTH" >&2; return 4; }
  case "$next" in
  proceed) return 0 ;;
  wait) echo "default-branch checks pending — merge nothing yet: $HEALTH" >&2; return 5 ;;
  freeze)
    FREEZE_MERGE=$(sed -n 's/^merge=//p' <<<"$HEALTH")
    FREEZE_REASON="post-merge default-branch checks $status on $FREEZE_MERGE (PR #$(sed -n 's/^pr=//p' <<<"$HEALTH")): $(sed -n 's/^reason=//p' <<<"$HEALTH")"
    printf 'freeze_merge=%s\nfreeze_health=%s\nfreeze_reason=%s\n' "$FREEZE_MERGE" "$status" "$FREEZE_REASON"
    echo "default branch unhealthy — freeze the Epic, merge nothing" >&2
    return 4 ;;
  *) echo "unexpected post-merge health: $HEALTH" >&2; return 4 ;;
  esac
}
```

| `status=` | `next=` | Meaning |
|---|---|---|
| `CLEAR` | `proceed` | No record, or the recorded PR did not merge |
| `PASS` | `proceed` | Every check on the merge commit passed; the merged Issue counts as `done` |
| `PENDING` | `wait` | A check is pending, none is reported yet within 10 minutes of the merge, or every check passed but 2 minutes have not elapsed since the merge, so a slower workflow can still report |
| `FAIL` | `freeze` | A check on the merge commit failed, timed out, went stale, or asks for human action |
| `UNCONFIRMED` | `freeze` | A check was cancelled — usually superseded by a later push — none was reported 10 minutes after the merge, or one is still pending an hour after it, such as a job awaiting environment approval, so health cannot be confirmed |
| `HANDLED` | `proceed` | `FAIL` or `UNCONFIRMED` already named by a freeze this loop posted with the same merge commit and the same status; that freeze and its `epic-release` own it |
| `UNREADABLE` | `hold` | Exit 1: the record, the PR, or a check could not be read |

`health_gate`'s return 4 means two things: with `freeze_merge=` on stdout, freeze the Epic; without it, the health could not be read, so stop landing and report, posting nothing.

Other lines: `reason=`, `record_id=` (`none` without a record), and, with a record, `pr=`, `issue=`, and, once merged, `merge=`. Every check counts, required or not, and only a pass confirms health. The classification is `pr-readiness.sh`'s, so a check reads the same before and after its merge, with one exception: `ACTION_REQUIRED`, a human hold on a PR, is a failure here, since a merge that already landed cannot wait for one. `HANDLED` matches only a freeze whose `- merge:` line names this merge commit and whose `- health:` line names this status, which is what lets `epic-release` resume the Epic without the same failure freezing it again, while a different result on the same merge — a cancelled run re-run into a real failure — still freezes it. `--snapshot <file|-> --me <login>` classifies a saved `{comments, pull, now}` object instead of calling `gh`, which is how `scripts/test-base-health.bats` exercises every rule.

## §4 Cleanup After Merge — Step 9 rescan

Only for an Issue that is **closed** with a **merged** PR:

```bash
git -C "$WT" status --short   # must be clean; if not, report it instead of forcing
git worktree remove "$WT"
git branch -d "$BRANCH"       # -d refuses if unmerged, which is the point
git worktree prune
```
