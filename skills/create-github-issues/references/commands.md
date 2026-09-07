# Command Reference

## Step 5: Creating Issues

The Epic is created first: native sub-issue linking (`gh issue create --parent`) needs the parent to already exist, and creating each level in wave order lets it reference already-created earlier-wave numbers directly via `--blocked-by`. A `Tn` promoted to a container (Step 2) still gets created here like any other `Tn` — only its own `Tn.m` grandchildren and body substitution come later (5.3, 5.4).

`CHILD_NUM` is one associative array for the whole run, keyed by dotted id (`T1`, `T1.1`, `T2`, ...) — a grandchild's key is its full `Tn.m` id, not just `m`.

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

Declare the associative array once, then repeat the create block for every `Tn` (leaf or container), keyed by its id — do not overwrite a single pair of variables across iterations, or every `Tn` but the last loses its number. Process `Tn` in wave order (Wave 1 first, ascending) so that any `Tm` a later `Tn` depends on already has a real number in `CHILD_NUM`. A container `Tn`'s body still holds unsubstituted `{{Tn.m}}` tokens at this point — that's expected, 5.4 fixes it up once its grandchildren exist:

```bash
declare -A CHILD_NUM

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
  --blocked-by "<comma-separated real numbers of every Tm in TN's depends_on>")
CHILD_NUM[TN]=$(echo "$CHILD_URL" | grep -oE '[0-9]+$')
```

If a single `Tn` creation fails, print the error, skip creating its would-be `Tn.m` grandchildren (5.3) entirely — there is no valid parent for them — and continue with the remaining `Tn`. Note any failed `Tn` in the Step 6 completion report so the user knows which parent/blocked-by relation, and which grandchildren, are missing. Before creating any later `Tn` whose `depends_on` names a failed one, drop that id from its `--blocked-by` list — `CHILD_NUM` has no entry for it, so passing it through would hand `gh issue create` a nonexistent number.

### 5.3 Create Tn.m grandchildren for each container Tn

Only for `Tn` that Step 2 promoted to a container. Same pattern as 5.2, one level down: `--parent` is the container's own real number from `CHILD_NUM[Tn]`, `--blocked-by` may only list sibling `Tn.m` under the same parent (never a `Tn`, never a different container's child):

```bash
# Repeat this block per Tn.m, in wave order, for each container Tn:
GRANDCHILD_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<Tn.m title>" \
  --body "$(cat <<'EOF'
<Tn.m body — leaf shape, no tokens>
EOF
)" \
  --parent "${CHILD_NUM[Tn]}" \
  --blocked-by "<comma-separated real numbers of every sibling Tn.m in this Tn.m's depends_on>")
CHILD_NUM[Tn.m]=$(echo "$GRANDCHILD_URL" | grep -oE '[0-9]+$')
```

If a single `Tn.m` creation fails, print the error and continue with the remaining `Tn.m` under the same container — its container is still created/updated normally (5.4). Note the failed `Tn.m` in the Step 6 completion report, and, same as 5.2, drop it from any later sibling's `--blocked-by` list instead of passing a nonexistent number.

### 5.4 Substitute placeholders into each container Tn body

For every container `Tn`, replace every `{{Tn.m}}` token in its Step 4-approved body with `#${CHILD_NUM[Tn.m]}` (or the inline "(creation failed)" note for a grandchild that failed in 5.3) — a mechanical substitution only, no wording changes. Then update it:

```bash
gh issue edit "${CHILD_NUM[Tn]}" \
  --repo "$REPO" \
  --body "$(cat <<'EOF'
<container Tn body, with every {{Tn.m}} already replaced by #<number> or "(creation failed)">
EOF
)"
```

Do this for every container before moving to 5.5, so the Epic substitution never has to reach past a `Tn`'s own body.

### 5.5 Substitute placeholders into the Epic body

Take the Step 4-approved Epic body and replace every `{{Tn}}` token with `#${CHILD_NUM[Tn]}` (or the inline "(creation failed)" note for a `Tn` that failed in 5.2) using the array built above — a mechanical substitution only, no wording changes. Then update the Epic:

```bash
gh issue edit "$EPIC_NUM" \
  --repo "$REPO" \
  --body "$(cat <<'EOF'
<Epic body, with every {{Tn}} already replaced by #<number> or "(creation failed)">
EOF
)"
```

## Step 6: Completion report

See the "Step 6: Completion Report" template in `references/templates.<LANG>.md` (e.g. `templates.ja.md` for `ja`).
