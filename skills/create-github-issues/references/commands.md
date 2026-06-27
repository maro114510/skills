# Command Reference

## Step 5: Creating Issues

### 5.1 Create the Epic (parent Issue)

```bash
EPIC_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<Epic title>" \
  --body "<Epic body>")
EPIC_NUM=$(echo "$EPIC_URL" | grep -oE '[0-9]+$')
EPIC_NODE_ID=$(gh issue view "$EPIC_NUM" --repo "$REPO" --json id --jq '.id')
```

### 5.2 Create each child Issue

Repeat for every child Issue:

```bash
CHILD_URL=$(gh issue create \
  --repo "$REPO" \
  --title "<child Issue title>" \
  --body "<child Issue body>")
CHILD_NUM=$(echo "$CHILD_URL" | grep -oE '[0-9]+$')
CHILD_NODE_ID=$(gh issue view "$CHILD_NUM" --repo "$REPO" --json id --jq '.id')
```

## Step 6: Link child Issues to Epic via GraphQL

Run this for each child Issue:

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
  -f subIssueId="$CHILD_NODE_ID"
```

## Step 7: Completion report

```
## 作成完了

### Epic
- #<number> <title>  (<URL>)

### 子Issue
- #<number> <title>
- #<number> <title>
...

Epic と各子Issue は GraphQL（addSubIssue）で紐づけました。
GitHub 上の Sub-Issues パネルで確認できます。
```
