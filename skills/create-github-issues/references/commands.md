# Command Reference

## Step 5: Creating Issues

Child Issues are created first so their real numbers exist before the Epic's dependency diagram is written.

### 5.1 Create each child Issue

Declare associative arrays once, then repeat the create block for every child Issue (`Tn`), keyed by its `Tn` id — do not overwrite a single pair of variables across iterations, or every `Tn` but the last loses its number:

```bash
declare -A CHILD_NUM CHILD_NODE_ID

# Repeat this block per Tn, substituting T1, T2, ... for TN:
CHILD_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<child Issue title for TN>" \
  --body "$(cat <<'EOF'
<child Issue body for TN>
EOF
)")
CHILD_NUM[TN]=$(echo "$CHILD_URL" | grep -oE '[0-9]+$')
CHILD_NODE_ID[TN]=$(gh issue view "${CHILD_NUM[TN]}" --repo "$REPO" --json id --jq '.id')
```

### 5.2 Build the Epic body and create the Epic

Take the Step 4-approved Epic body and replace every `{{Tn}}` token with `#${CHILD_NUM[Tn]}` using the array built above — a mechanical substitution only, no wording changes. Then create it:

```bash
EPIC_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<Epic title>" \
  --body "$(cat <<'EOF'
<Epic body, with every {{Tn}} already replaced by #<number>>
EOF
)")
EPIC_NUM=$(echo "$EPIC_URL" | grep -oE '[0-9]+$')
EPIC_NODE_ID=$(gh issue view "$EPIC_NUM" --repo "$REPO" --json id --jq '.id')
```

## Step 6: Link child Issues to Epic via GraphQL

Run this for each child Issue, substituting `TN` for its `Tn` id (using the same `CHILD_NODE_ID` array from Step 5.1):

```bash
gh api graphql \
  -f query='
    mutation AddSubIssue($issueId: ID!, $subIssueId: ID!) {
      addSubIssue(input: {issueId: $issueId, subIssueId: $subIssueId}) {
        issue { number title }
        subIssue { number title }
      }
    }
  ' \
  -f issueId="$EPIC_NODE_ID" \
  -f subIssueId="${CHILD_NODE_ID[TN]}"
```

## Step 7: Completion report

See the "Step 7: Completion Report" template in `references/templates.<LANG>.md` (e.g. `templates.ja.md` for `ja`).
