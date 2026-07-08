# Command Reference

## Step 5: Creating Issues

The Epic is created first: native sub-issue linking (`gh issue create --parent`) needs the parent to already exist, and creating children in wave order lets each one reference already-created earlier-wave numbers directly via `--blocked-by`.

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

### 5.2 Create child Issues in wave order

Declare an associative array once, then repeat the create block for every child Issue (`Tn`), keyed by its `Tn` id — do not overwrite a single pair of variables across iterations, or every `Tn` but the last loses its number. Process `Tn` in wave order (Wave 1 first, ascending) so that any `Tm` a later `Tn` depends on already has a real number in `CHILD_NUM`:

```bash
declare -A CHILD_NUM

# Repeat this block per Tn, in wave order, substituting T1, T2, ... for TN:
# --blocked-by takes a comma-separated list of every Tm in TN's depends_on — one, several, or omitted
# entirely if TN has none. GitHub treats an issue as blocked by ALL listed issues, not just one:
# it isn't considered unblocked until every one of them is closed.
CHILD_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<child Issue title for TN>" \
  --body "$(cat <<'EOF'
<child Issue body for TN>
EOF
)" \
  --parent "$EPIC_NUM" \
  --blocked-by "<comma-separated real numbers of every Tm in TN's depends_on>")
CHILD_NUM[TN]=$(echo "$CHILD_URL" | grep -oE '[0-9]+$')
```

If a single child Issue creation fails, print the error and continue with the remaining `Tn` — don't abort the whole run. Note any failed `Tn` in the Step 6 completion report so the user knows which parent/blocked-by relation is missing.

### 5.3 Substitute placeholders into the Epic body

Take the Step 4-approved Epic body and replace every `{{Tn}}` token with `#${CHILD_NUM[Tn]}` using the array built above — a mechanical substitution only, no wording changes. Then update the Epic:

```bash
gh issue edit "$EPIC_NUM" \
  --repo "$REPO" \
  --body "$(cat <<'EOF'
<Epic body, with every {{Tn}} already replaced by #<number>>
EOF
)"
```

## Step 6: Completion report

See the "Step 6: Completion Report" template in `references/templates.<LANG>.md` (e.g. `templates.ja.md` for `ja`).
