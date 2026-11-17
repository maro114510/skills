# A tag push on the commit the owner ran triggers a release

## Context

A release must ship a commit the owner has already run on `main`, while `main` keeps merging, at a median of about 7 minutes per pull request. Common release tools differ in what they ship:

| Approach | Example tools | Release starts when | Ships |
|---|---|---|---|
| Tag push | This repository's release workflow | A person pushes a tag | The tagged commit |
| Release pull request on `main` | release-please, changesets | A person merges the pull request that bumps the version | The head of `main` at that merge |
| Release on every merge | semantic-release | Any merge into a release branch | The head of that branch at that merge |

## Decision

A push of a `v<version>` tag on the Bump commit above the Run commit triggers the release workflow, which publishes the release only when its guards pass. A pull request brings the Bump commit back to `main` after the release. Only repository admins can create `v` tags.

## Rationale

| Alternative | Why it lost |
|---|---|
| Release pull request on `main` | Ships the head of `main` at the merge, which includes commits merged after the one the owner ran |
| Release pull request on a release-only branch | Ships the commit the owner ran, but adds a branch and a tool, while the pull request adds no second reviewer to a single-maintainer repository |
| Release on every merge | Ships every merge, which the decision to release when the owner chooses rules out |

| Decisive reason |
|---|
| A tag names any commit, so it alone ships the commit the owner ran without freezing `main` |
| The release workflow already runs on a tag push |

## Consequences

- No pull request records the release; the tag, the workflow run, and GitHub's immutable release record it instead.
- CI does not run on the Bump commit before the release, so the release workflow checks that the Bump commit changes nothing but the version fields.
- The Bump commit reaches `main` only through a separate pull request, which can be left unmerged or merged out of order.
- An admin can still push a tag outside this flow; the release workflow's guards are what refuse it.
