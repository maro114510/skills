# Command Reference

## Tool permission contract

`allowed-tools` grants Bash commands one subcommand at a time: Claude Code splits a compound command on `&&`, `||`, `;`, `|`, `&`, and newlines, then matches each subcommand against the declared patterns. `Bash(gh:*)` matches only a subcommand whose first token is `gh`.

- Never add a top-level variable assignment, function, loop, or non-`gh` utility such as `mktemp`, `awk`, `printf`, `echo`, `grep`, or `cat`; none match `Bash(gh:*)`.
- A command that does not start with `gh` needs a matching grant in `allowed-tools`.
- Keep Issue bodies inline via heredoc; writing them to files would also require a `Write` grant.

## Step 5: Creating Issues

The Epic is created first: `gh issue create --parent` needs the parent to exist, and wave order lets each level reference earlier-wave numbers in `--blocked-by`. A container `Tn` is created like any other `Tn`; its `Tn.m` grandchildren and body substitution come later.

**Number tracking**

- `gh issue create` prints the new Issue URL on success.
- Record its trailing number against the id: `T1`, `T1.1`, `T2`, and so on; a grandchild is keyed by its full `Tn.m` id.
- A failed create prints an error, not a URL, so it gets no number; treat it as failed and continue.
- To resume an interrupted run, recover a number with `gh issue list --repo <owner/repo> --state all --search "in:title <Tn title>" --json number,title,url,state`, continuing only when exactly one returned title matches `<Tn title>`; otherwise stop rather than attach an ambiguous Issue to the dependency graph.

### 5.1 Create the Epic

`{{Tn}}` placeholders stay in the body; record the number from the printed URL as the Epic number.

```bash
gh issue create \
  --repo <owner/repo> \
  --title "<Epic title>" \
  --body-file - <<'EOF'
<Epic body, {{Tn}} placeholders as approved in Step 4>
EOF
```

### 5.2 Create every Tn in wave order

Repeat per `Tn`, in wave order, Wave 1 first. `--blocked-by` lists every `Tm` in its `depends_on`; GitHub treats the Issue as blocked until all of them close, so omit it when there are none. A container `Tn` body still holds `{{Tn.m}}` tokens; 5.4 fills them in.

```bash
gh issue create \
  --repo <owner/repo> \
  --title "<Tn title>" \
  --parent <Epic number> \
  --blocked-by "<real numbers of every Tm in TN's depends_on>" \
  --body-file - <<'EOF'
<Tn body — leaf shape, or container shape with {{Tn.m}} tokens still in place>
EOF
```

Record each number before the next create. On a failed `Tn`:

- Skip its `Tn.m` grandchildren; they have no valid parent.
- Report it in Step 6.
- Drop it from any later `Tn`'s `--blocked-by`; it has no number.

### 5.3 Create Tn.m grandchildren for each container Tn

Only for a container `Tn`. `--parent` is the container's number; `--blocked-by` may list only sibling `Tn.m` under the same parent, never a `Tn` or another container's child.

```bash
gh issue create \
  --repo <owner/repo> \
  --title "<Tn.m title>" \
  --parent <container Tn's number> \
  --blocked-by "<real numbers of every sibling Tn.m in this Tn.m's depends_on>" \
  --body-file - <<'EOF'
<Tn.m body — leaf shape, no tokens>
EOF
```

On a failed `Tn.m`, continue with the rest; the container is still updated. Report it in Step 6 and drop it from later siblings' `--blocked-by`.

### 5.4 Substitute placeholders into each container Tn body

Replace every `{{Tn.m}}` in the approved body with `#<number>`, or `(creation failed)` for a grandchild that failed in 5.3. Mechanical substitution only; no wording changes.

```bash
gh issue edit <container Tn's number> \
  --repo <owner/repo> \
  --body-file - <<'EOF'
<container Tn body, with every {{Tn.m}} replaced by #<number> or "(creation failed)">
EOF
```

Update every container before 5.5, so the Epic substitution never reaches past a `Tn` body.

### 5.5 Substitute placeholders into the Epic body

Replace every `{{Tn}}` in the approved Epic body with `#<number>`, or `(creation failed)` for a `Tn` that failed in 5.2. Mechanical substitution only.

```bash
gh issue edit <Epic number> \
  --repo <owner/repo> \
  --body-file - <<'EOF'
<Epic body, with every {{Tn}} replaced by #<number> or "(creation failed)">
EOF
```

### 5.6 Verify sub-issue and blocked-by relations against GitHub

Script output is not proof: read the relations back before Step 6 and stop on any mismatch. `Issue` exposes `blockedBy`, `blocking`, and `issueDependenciesSummary`; `blockedByIssues` does not exist.

```bash
gh api graphql -f query='{ __type(name:"Issue"){ fields { name } } }'
```

Sub-issue count: Epic sub-issues are the `Tn` level only, so the expected count is the number of non-dotted ids created.

```bash
gh api graphql -f owner="<owner>" -f name="<name>" -F number=<Epic number> -f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      id
      subIssues(first: 100) { totalCount nodes { id number title } }
    }
  }
}'
```

Reconcile until `totalCount` matches. Read the Epic's `id` for the recovery commands.

| Mismatch | Recovery |
|---|---|
| Extra: a number no `Tn` owns | Detach, close, unlist |
| Missing: a recorded `Tn` absent | Re-attach with `addSubIssue` |

Extra:

```bash
gh api graphql -F epicId="<Epic node id>" -F dupId="<duplicate node id>" -f query='
mutation($epicId: ID!, $dupId: ID!) {
  removeSubIssue(input: { issueId: $epicId, subIssueId: $dupId }) { issue { number } }
}'

gh issue close <duplicate number> --repo <owner/repo> --comment "Duplicate of #<canonical number> — detached from the Epic."
```

If project automation added the duplicate, delete its project item with `gh project item-delete <project number> --owner <owner> --id <item-id>`.

Missing:

```bash
gh api graphql -F epicId="<Epic node id>" -F tnId="<Tn node id>" -f query='
mutation($epicId: ID!, $tnId: ID!) {
  addSubIssue(input: { issueId: $epicId, subIssueId: $tnId }) { issue { number } }
}'
```

Blocked-by sets: each dependent `Tn` or `Tn.m` must list exactly its successful `depends_on` numbers; failed IDs are intentionally omitted and reported in Step 6.

```bash
gh api graphql -f owner="<owner>" -f name="<name>" -F number=<dependent Tn or Tn.m number> -f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) { blockedBy(first: 100) { nodes { number } } }
  }
}'
```

### 5.7 Link the Epic and every Issue to a project, only when asked

Run only when Step 1 recorded a project number; otherwise skip. `gh issue create` has no `--project` flag, so linking happens after creation.

`gh project` needs the `project` scope; add it with `gh auth refresh -s project`. That command fails while `GITHUB_TOKEN` is exported and needs `--hostname` when it cannot prompt, so ask the user to unset `GITHUB_TOKEN` in their shell and rerun. If the keyring already carries the scope, `gh project` works without that step.

Add the Epic and every child by URL, one command per Issue:

```bash
gh project item-add <project number> --owner <owner> --url "<Issue URL>" --format json
```

- Auto-add workflows can pull in Issues the skill never created, and a closed duplicate lands as `Done`, reading as finished work. Remove such items with `gh project item-delete <project number> --owner <owner> --id <item-id>`.
- Never map this run's Wave numbers onto a `Stage` or `Wave` field; that is the program's vocabulary. Leave it unset and keep waves in the Epic body. Set only a user-requested field with `gh project item-edit --id <item> --project-id <project-id> --field-id <field-id> --single-select-option-id <option-id>`, ids from `gh project view` and `gh project field-list --format json`.

## Step 6: Completion report

See the "Step 6: Completion Report" template in `references/templates.<LANG>.md`, for example `templates.ja.md` for `ja`.
