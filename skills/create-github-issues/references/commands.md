# Command Reference

## Step 5: Creating Issues

The Epic is created first: native sub-issue linking (`gh issue create --parent`) needs the parent to already exist, and creating each level in wave order lets it reference already-created earlier-wave numbers directly via `--blocked-by`. A `Tn` promoted to a container (Step 2) still gets created here like any other `Tn` — only its own `Tn.m` grandchildren and body substitution come later (5.3, 5.4).

`CHILD_NUM_FILE` is one plain file for the whole run, standing in for a bash associative array (unsupported on bash 3.2, macOS's default `/bin/bash`). Each created Issue gets one `id<TAB>number` line, keyed by dotted id (`T1`, `T1.1`, `T2`, ...) — a grandchild's key is its full `Tn.m` id, not just `m`. Two helpers:

```bash
CHILD_NUM_FILE=$(mktemp)

record_child_num() {  # record_child_num <id> <number>
  printf '%s\t%s\n' "$1" "$2" >> "$CHILD_NUM_FILE"
}

child_num() {  # child_num <id> -> prints the recorded number, or nothing
  awk -F'\t' -v id="$1" '$1 == id { v = $2 } END { print v }' "$CHILD_NUM_FILE"
}
```

`child_num` uses `awk` field matching, not `grep`, so the `.` in `T1.1` isn't treated as a regex wildcard.

Batching many `Tn`/`Tn.m` creations in one script run means a mid-run failure leaves later ones simply not created. To resume, rerun from the first `Tn`/`Tn.m` not yet created, reusing the same `$CHILD_NUM_FILE`. 5.2/5.3 chain creation and recording with `&&` on one line, so recording can only fail immediately after the Issue is created — never silently later. If that append itself fails, find the Issue via `gh issue list --repo "$REPO" --search "<Tn title>"`, append its `<id><TAB><number>` line to `$CHILD_NUM_FILE` by hand, then resume.

### 5.1 Create the Epic

Create the Epic using the Step 4-approved body, `{{Tn}}` placeholders left in place:

```bash
EPIC_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<Epic title>" \
  --body "$(cat <<'EOF'
<Epic body, {{Tn}} placeholders as approved in Step 4>
EOF
)")
EPIC_NUM=$(echo "$EPIC_URL" | grep -oE '[0-9]+$')
```

### 5.2 Create every Tn in wave order

Set up `$CHILD_NUM_FILE` once (see above), then repeat the create block for every `Tn` (leaf or container), keyed by its id. Process `Tn` in wave order (Wave 1 first, ascending) so that any `Tm` a later `Tn` depends on already has a real number recorded. A container `Tn`'s body still holds unsubstituted `{{Tn.m}}` tokens at this point — that's expected, 5.4 fixes it up once its grandchildren exist:

```bash
# Repeat this block per Tn, in wave order, substituting T1, T2, ... for TN:
# --blocked-by takes a comma-separated list of every Tm in TN's depends_on — one, several, or omitted
# entirely if TN has none. GitHub treats an issue as blocked by ALL listed issues, not just one:
# it isn't considered unblocked until every one of them is closed.
CHILD_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<Tn title>" \
  --body "$(cat <<'EOF'
<Tn body — leaf shape, or container shape with {{Tn.m}} tokens still in place>
EOF
)" \
  --parent "$EPIC_NUM" \
  --blocked-by "<comma-separated real numbers of every Tm in TN's depends_on>") \
  && record_child_num "TN" "$(echo "$CHILD_URL" | grep -oE '[0-9]+$')"
```

If a single `Tn` creation fails, print the error, skip creating its would-be `Tn.m` grandchildren (5.3) entirely — there is no valid parent for them — and continue with the remaining `Tn`. Note any failed `Tn` in the Step 6 completion report so the user knows which parent/blocked-by relation, and which grandchildren, are missing. Before creating any later `Tn` whose `depends_on` names a failed one, drop that id from its `--blocked-by` list — `child_num` returns nothing for it, so passing it through would hand `gh issue create` a nonexistent number.

### 5.3 Create Tn.m grandchildren for each container Tn

Only for `Tn` that Step 2 promoted to a container. Same pattern as 5.2, one level down: `--parent` is the container's own real number from `child_num "Tn"`, `--blocked-by` may only list sibling `Tn.m` under the same parent (never a `Tn`, never a different container's child):

```bash
# Repeat this block per Tn.m, in wave order, for each container Tn:
GRANDCHILD_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<Tn.m title>" \
  --body "$(cat <<'EOF'
<Tn.m body — leaf shape, no tokens>
EOF
)" \
  --parent "$(child_num "Tn")" \
  --blocked-by "<comma-separated real numbers of every sibling Tn.m in this Tn.m's depends_on>") \
  && record_child_num "Tn.m" "$(echo "$GRANDCHILD_URL" | grep -oE '[0-9]+$')"
```

If a single `Tn.m` creation fails, print the error and continue with the remaining `Tn.m` under the same container — its container is still created/updated normally (5.4). Note the failed `Tn.m` in the Step 6 completion report, and, same as 5.2, drop it from any later sibling's `--blocked-by` list instead of passing a nonexistent number.

### 5.4 Substitute placeholders into each container Tn body

For every container `Tn`, replace every `{{Tn.m}}` token in its Step 4-approved body with `#$(child_num "Tn.m")` (or the inline "(creation failed)" note for a grandchild that failed in 5.3) — a mechanical substitution only, no wording changes. Then update it:

```bash
gh issue edit "$(child_num "Tn")" \
  --repo "$REPO" \
  --body "$(cat <<'EOF'
<container Tn body, with every {{Tn.m}} already replaced by #<number> or "(creation failed)">
EOF
)"
```

Do this for every container before moving to 5.5, so the Epic substitution never has to reach past a `Tn`'s own body.

### 5.5 Substitute placeholders into the Epic body

Take the Step 4-approved Epic body and replace every `{{Tn}}` token with `#$(child_num "Tn")` (or the inline "(creation failed)" note for a `Tn` that failed in 5.2) using `$CHILD_NUM_FILE` built above — a mechanical substitution only, no wording changes. Then update the Epic:

```bash
gh issue edit "$EPIC_NUM" \
  --repo "$REPO" \
  --body "$(cat <<'EOF'
<Epic body, with every {{Tn}} already replaced by #<number> or "(creation failed)">
EOF
)"
```

### 5.6 Verify sub-issue and blocked-by relations against GitHub

Script output is not proof. Read the relations back from GitHub before the Step 6 report; on any mismatch, report it to the user and stop.

`Issue` exposes `blockedBy`, `blocking`, `issueDependenciesSummary`. `blockedByIssues` does not exist.

```bash
gh api graphql -f query='{ __type(name:"Issue"){ fields { name } } }'
OWNER="${REPO%/*}"
NAME="${REPO#*/}"
```

**Sub-issue count.** Epic sub-issues are the `Tn` level only; `Tn.m` hangs off its container. Expected count = non-dotted ids in `$CHILD_NUM_FILE`.

```bash
EXPECTED_TN_COUNT=$(awk -F'\t' '$1 !~ /\./ { n++ } END { print n + 0 }' "$CHILD_NUM_FILE")

gh api graphql -f owner="$OWNER" -f name="$NAME" -F number="$EPIC_NUM" -f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      id
      subIssues(first: 100) { totalCount nodes { id number title } }
    }
  }
}'
```

Reconcile until `totalCount` and the number sets agree.

- **Extra** — a number no `Tn` owns. Detach, close, unlist.

```bash
gh api graphql -F epicId="$EPIC_ID" -F dupId="$DUP_ID" -f query='
mutation($epicId: ID!, $dupId: ID!) {
  removeSubIssue(input: { issueId: $epicId, subIssueId: $dupId }) { issue { number } }
}'

gh issue close "$DUP_NUM" --repo "$REPO" --comment "Duplicate of #$CANONICAL_NUM — detached from the Epic."
```

  If project automation auto-added the duplicate, delete its project item with `gh project item-delete`.

- **Missing** — a recorded `Tn` absent from the nodes; its `--parent` was lost. Re-attach with `addSubIssue`.

```bash
gh api graphql -F epicId="$EPIC_ID" -F tnId="$TN_ID" -f query='
mutation($epicId: ID!, $tnId: ID!) {
  addSubIssue(input: { issueId: $epicId, subIssueId: $tnId }) { issue { number } }
}'
```

**Blocked-by sets.** Per dependent `Tn`/`Tn.m`, `blockedBy` must equal its `depends_on` numbers.

```bash
EXPECTED_BLOCKERS="$(child_num "T1") $(child_num "T2")"

gh api graphql -f owner="$OWNER" -f name="$NAME" -F number="$(child_num "Tn")" -f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) { blockedBy(first: 100) { nodes { number } } }
  }
}'
```

Missing or unexpected entry = mismatch: report and stop.

### 5.7 Link the Epic and every Issue to a project (only when asked)

Run only when Step 1 set `$PROJECT_NUM`; `gh issue create` has no `--project` flag, so linking happens after creation. Otherwise skip.

- **Auth**: `gh project` needs the `project` scope. `gh auth refresh -s project` fails when `GITHUB_TOKEN` is exported, and needs `--hostname` without a prompt. If the keyring already has the scope, prefix commands with `env -u GITHUB_TOKEN`; else stop and report.
- **Add** Epic and every child under repo owner `$OWNER`, by URL:

```bash
env -u GITHUB_TOKEN gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$EPIC_URL" --format json
while IFS=$'\t' read -r id num; do
  env -u GITHUB_TOKEN gh project item-add "$PROJECT_NUM" --owner "$OWNER" \
    --url "https://github.com/$REPO/issues/$num" --format json
done < "$CHILD_NUM_FILE"
```

- **Automation**: auto-add workflows add Issues the skill never created, and a closed duplicate lands as `Done`, reading as finished work. Remove them with `gh project item-delete "$PROJECT_NUM" --owner "$OWNER" --id <item-id>`.
- **Fields**: never map this run's Wave numbers onto a `Stage`/`Wave` field — it is the program's vocabulary; leave it unset, keep waves in the Epic body. Only a user-requested field is set, via `gh project item-edit --id <item> --project-id <project-id> --field-id <field-id> --single-select-option-id <option-id>`, ids from `gh project view` and `gh project field-list --format json`.

## Step 6: Completion report

See the "Step 6: Completion Report" template in `references/templates.<LANG>.md` (e.g. `templates.ja.md` for `ja`).
