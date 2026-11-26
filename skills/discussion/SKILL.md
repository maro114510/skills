---
name: discussion
description: >
  Post, comment on, rewrite, record a decision on, or close a GitHub Discussion in this repository, with its one template and the `gh` commands. Use for "open a Discussion", "close this Discussion", "record the decision", 「Discussionを立てて」「Discussionを閉じて」「決定を記録して」.
argument-hint: "[post | comment | rewrite | decide | close] [Discussion number or topic]"
---

# discussion

Hold the template and the steps for a Discussion's lifecycle.
The rules, such as categories, what a post may carry, and the close reasons, are in the Discussions section of AGENTS.md; read it first and follow it, because this file never restates it.

## Structure

| Part | Holds | Written |
|---|---|---|
| Body | The current brief, rewritten in place | At post, and again as evidence or options change |
| Comment, evidence | A new observation | Appended |
| Comment, decision | The question and the owner's answer, quoted | Appended once per decision, never edited |
| Comment, close | The reason, and what would reopen it or where the work went | Appended before the close |

- A body rewrite never removes a decision, because decisions live only in comments.
- One Discussion decides one thing. Split a post that bundles several.
- Rewrite an existing Discussion into the template when it is taken up, not before.
- Every write takes its text from a file, so quoting and newlines survive.

## Template

Required in every body: Observation, Options, Question, Unresolved. An observation-only post may write "none yet" under Options and, under Question, what would decide whether to act.

````markdown
## Observation
What happened, with evidence a public reader can check.
## Goal and non-goals
The goal, and which part of it the observation breaks.
## Options
| Option | Removes | Loses | Wins when |
|---|---|---|---|
| Do nothing | | | |
## Recommendation
Proposed disposition: an Issue, a Design Doc, decline, or hold, and why.
## Question
The one question the owner answers now.
## Unresolved
- Before the decision:
- During implementation:
## What it would let us remove
What in the repository it would remove, or none.
````

"Wins when" is the condition under which that option is the right choice; an option that can win under no real condition is a straw man, so drop it.

## Commands

The repository ID is `R_kgDOR_3Rlw`. The category ID is `DIC_kwDOR_3Rl84DKbjP` for Ideas or `DIC_kwDOR_3Rl84DKbjN` for General.

```bash
# Search
gh api graphql -f query='query($q:String!){search(type:DISCUSSION,query:$q,first:10){nodes{... on Discussion{number title url}}}}' \
  -f q='repo:maro114510/skills <words>'
# Read a Discussion: its ID, body, state, and comments
gh api graphql -f query='query($n:Int!){repository(owner:"maro114510",name:"skills"){discussion(number:$n){id title body closed comments(first:100){nodes{url body}}}}}' \
  -F n=<number>
# Post
gh api graphql -f query='mutation($r:ID!,$c:ID!,$t:String!,$b:String!){createDiscussion(input:{repositoryId:$r,categoryId:$c,title:$t,body:$b}){discussion{url}}}' \
  -f r=R_kgDOR_3Rlw -f c=<category> -f t='<title>' -F b=@<body-file>
# Comment: evidence, decision, or close
gh api graphql -f query='mutation($d:ID!,$b:String!){addDiscussionComment(input:{discussionId:$d,body:$b}){comment{url}}}' \
  -f d=<discussion-id> -F b=@<comment-file>
# Rewrite the body
gh api graphql -f query='mutation($d:ID!,$b:String!){updateDiscussion(input:{discussionId:$d,body:$b}){discussion{url}}}' \
  -f d=<discussion-id> -F b=@<body-file>
# Close. <reason> is RESOLVED, OUTDATED, or DUPLICATE
gh api graphql -f query='mutation($d:ID!,$r:DiscussionCloseReason!){closeDiscussion(input:{discussionId:$d,reason:$r}){discussion{url closed}}}' \
  -f d=<discussion-id> -f r=<reason>
```

## Steps

### Post

1. Search for the same topic as AGENTS.md says, and comment on an existing Discussion instead when one holds it.
2. Write the body from the template into a file, and post it.

### Comment

1. Read the Discussion, so the comment adds what is new.
2. Write the observation, with its evidence, into a file and add it as a comment.
3. When it changes the options or the recommendation, rewrite the body too.

### Rewrite the body

1. Read the Discussion with its comments, and keep the template's section names.
2. Write the new body into a file that holds the current brief only: no history, and no restated decision. Link a decision comment instead.
3. Update the body.

### Record a decision

1. Do this only after the owner answers the question explicitly, as AGENTS.md says an agreement is recorded.
2. Add a comment that holds the date, a note that the owner decided it in conversation, and a table of the question and the owner's answer, each quoted. Never edit it afterward; a later change of mind is a new decision comment.
3. Rewrite the body so it no longer asks the answered question, and link the decision comment.

### Close

1. Read the Discussion, and pick the reason AGENTS.md defines that fits. For Resolved, confirm the Issue has opened or the Design Doc has merged, and link it on the Discussion first. For Duplicate, link the other Discussion and summarize in a sentence what this one held; the original stays readable, and its text is never copied.
2. Add the closing comment, which states the reason and, for Outdated, the observation that would reopen it.
3. Close the Discussion with that reason, only after the comment exists.
