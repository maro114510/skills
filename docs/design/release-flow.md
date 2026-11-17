# Release Flow

## Overview

Documented installs follow releases, and `main` is the owner's early-access track. A release ships a commit the owner has already run, not whatever merged last, and every supported harness gets the same release.

Distribution stays harness-neutral: the documented installs go through package managers that serve every supported harness, and no harness-specific mechanism is required to get a release.

| Responsible for | Not responsible for |
|---|---|
| Turning a commit the owner ran into an immutable, tagged release with generated notes | When to release, which the owner chooses |
| The version each documented install route resolves | How work merges into `main`, which stays as it is |
| Keeping the Claude Code plugin's version naming its content | A release schedule or its automation |

## Domain Model

| Concept | Definition |
|---|---|
| Early-access track | `main`, which the owner installs through APM or npx skills without naming a version |
| Run commit | A commit on `main` the owner has run and chooses to release. It is the single parent of its Release tag's commit. `v1.2.0`, the last tag made on `main`, is its own Run commit |
| Release branch | A branch that starts at the Run commit and holds the Bump commit on top |
| Bump commit | The one commit a release adds to the Run commit. It sets the new version in both manifests, the marketplace entry's `ref`, and the npx skills tag in the README |
| Release tag | `v<version>` on the Bump commit. GitHub's immutable releases keep a published tag on that content |
| Previous release | The published GitHub Release with the highest version below this one |
| Release range | The commits after the Previous release's Run commit, up to this release's Run commit, leaving out the commits Back-merge PRs added to `main`. The version bump and the Release notes both count this range |
| Release notes | Notes the release workflow generates with git-cliff for the Release range, opening with one entry per breaking commit: its `BREAKING CHANGE` or `BREAKING-CHANGE` footer text, or its subject when it has neither |
| Back-merge PR | The pull request that brings the Bump commit from the Release branch into `main` |

| Route | Role | Documented install resolves | Without a version |
|---|---|---|---|
| APM | Recommended package manager | The newest Release tag within the current major version, through a `#^<major>.0.0` range | `main` |
| GitHub CLI | Package manager | The latest release, its default | The latest release |
| npx skills | Package manager | The exact Release tag, `#v<version>` | `main` |
| Claude Code plugin | Supplementary, Claude Code only | The Release tag that the marketplace entry's `ref` on `main` names, so it moves when the Back-merge PR merges | The same; this route has no early-access track |

## Scenarios

### Cutting a release

The owner has run `main` for some time and wants other users to get that commit.

```mermaid
sequenceDiagram
    autonumber
    actor Owner
    participant WF as Release workflow
    Owner->>Owner: Create the Release branch at the Run commit
    Owner->>Owner: Add the Bump commit
    Owner->>WF: Push the Release tag on the Bump commit
    alt Every guard holds
        WF->>WF: Generate the Release notes
        WF->>WF: Publish the GitHub Release
    else A guard fails
        WF->>WF: Refuse the tag
    end
    Owner->>Owner: Open the Back-merge PR
    opt The Back-merge PR moves no version or ref to an older release
        Owner->>Owner: Merge the Back-merge PR as any other PR
    end
```

## Invariants

- The release workflow publishes a tag only when all of these hold:
    - The tag's commit has one parent, the Run commit, which is reachable from `main` and descends from the Previous release's Run commit.
    - The Bump commit changes nothing but the version in both manifests, the marketplace entry's `ref`, and the npx skills tag in the README.
    - Each of those equals the tag, with the manifests omitting its `v`.
- A published Release tag never moves to other content.
- The version and the marketplace entry's `ref` on `main` never move to an older release: a Back-merge PR that would move them back is not merged.

## References

- `../adr/release-by-tag-push.md` for why a tag push, not a pull request merge, triggers a release
- [The decision record](https://github.com/maro114510/skills/discussions/905#discussioncomment-19671463) for the checked premises, each route's behavior, and the decisions
- [Host and maintain a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace.md) for a marketplace entry's `ref`
