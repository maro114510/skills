# AGENTS.md

Repository instructions for coding agents.
The mission and the goals of this repository are in [MISSION.md](MISSION.md).

Write here only what an agent cannot learn by reading the repository, or would otherwise rediscover every session. Anything else belongs in the file it describes, such as a script's header.

`docs/design` holds only Design Docs that describe the current target, as `manage-design-documents` defines them; work the owner decided to build is an Issue.
Ideas, experiments, and open questions go to [Discussions](https://github.com/maro114510/skills/discussions) as [Development Flow](#development-flow) describes, never to Issues. The repository is public, so a post never carries work context.

## Versions and Releases

- Update both manifests together; updating only one breaks `claude plugin install`
- Bump versions with the Makefile release targets, never by hand
- `make release RUN=<commit>` infers the next SemVer from the Conventional Commits in the Release range via `git-cliff`, adds the Bump commit on a `release/v<version>` branch from the Run commit, and pushes that branch and the tag, never `main`
- Tags carry the `v` prefix, e.g. `v0.28.0`; manifest versions omit it, e.g. `0.28.0`
- Workflow actions are commit-pinned; update them with Dependabot only

| Bump | Commit type | Skill change |
|---|---|---|
| Major | `!` or `BREAKING CHANGE` | Breaking interface change or skill removal |
| Minor | `feat:` | New skill or meaningful new capability |
| Patch | `fix:` `perf:` `refactor:` `docs:` | Fix for ambiguity or a bug in a skill body |
| None | `ci:` `test:` `chore:` | - |

## Skill Format

| Key | Rule |
|---|---|
| `description` | Matched against user requests; include phrasings users naturally say |
| `disable-model-invocation` | Optional; `true` only stops Claude from loading the skill automatically. It does not disable the agentic loop: the skill still runs through `/name` and calls its tools normally, as in `orchestrate-epic` |
| `argument-hint` | Shown on `/help` |

- The body is the full prompt; user arguments arrive as `$ARGUMENTS`
- Body language is English or the target repository's language
- Japanese stays only in `description` trigger phrases and user-facing output templates
- Convert an older Japanese body only when already editing it for another reason
- Do not declare `allowed-tools`: it only pre-approves tools in Claude Code and has no effect in OpenCode or Pi, so it cannot restrict a skill's tools on every supported harness

## Target Repository Config

Per-user or per-clone settings live in git config and are never committed.
Skills read them with `git config --get <key>`, so git decides between local and global.

| git config key | Values | Resolved by |
|---|---|---|
| `skills.lang` | `ja`, `en` | `skills/create-pr/scripts/lang.sh` only; its header holds the precedence, and skills call it instead of restating it |
| `skills.bot` | The login of the GitHub App bot the agents act as, with or without the `[bot]` suffix; unset means none | `skills/orchestrate-epic/scripts/oe-bot.sh`, whose header states what keeps an agent's worktree from acting as the person |
| `skills.bot.helper` | A command that answers `token <owner>/<repo>` with one installation token for that repository, and git's credential helper protocol with `get`; read only from the global config, so a clone cannot name it | `bot_helper` in `skills/orchestrate-epic/scripts/oe-bot.sh` only |

## Development Flow

- Discuss undecided work before filing an implementation Issue. Use an existing Discussion when it holds the question; do not open one just to restate a decision.
- When work changes a boundary such as user-visible behavior, a skill contract, a safety gate, configuration, or a data format, update the existing Design Doc and get the owner's explicit agreement on the changed boundary before delegating implementation. Merge the design before opening implementation Issues. Record the agreement once where the implementation Issue can link to it. Use a publishable summary, not a transcript.
- After the owner decides to build, file an Issue with the work and observable acceptance conditions. Use an Epic only when work needs grouping or dependency coordination. Fixes that restore an existing contract and edits that do not change behavior can go straight to an Issue without a new owner decision.
- Delegate implementation and verification within the agreed boundary. If new behavior, scope, or guarantees are needed, stop the affected work and ask the owner; do not add them to acceptance conditions. Report what was observed and what was not verified on the pull request. A change to the target or conditions that invalidates evidence requires a new check.
- Keep at most 5 active decided units. An Epic or standalone Issue counts as one, including work that starts with a Design Doc. Bug fixes and edits that do not change behavior do not count. At the cap, keep approved work waiting in its existing record without starting it.

### Discussions

| Category | Holds |
|---|---|
| Ideas | Experiments, evaluations, and research that nobody has decided to build |
| General | Open questions that need a decision |

- Search Discussions and Issues for the same topic first; comment on an existing Discussion instead of opening a duplicate, and link a related Issue, especially one that scopes the idea out
- State the evidence behind the post
- An improvement idea names what in the repository it would let us remove, or says none
- Write posts and Issues in English
- Keep general facts, such as error class and status, endpoint, counts, timing, and the skill involved
- Drop anything that identifies private work: names of private repositories, organizations, and app installations, their PR and Issue numbers, product and domain terms, code, and data
- When work from a Discussion starts, link its Issue or Design Doc pull request on the Discussion and close it when the Issue opens or the Design Doc merges.
- Close a Discussion with the reason that fits, and state that reason in the closing comment
    - Resolved when the work the owner decided to build has started: its Issue opened or its Design Doc merged
    - Outdated when the owner decided against it, with the observation that would reopen it
    - Duplicate when another Discussion already holds it, linking that one

```bash
# Search
gh api graphql -f query='query($q:String!){search(type:DISCUSSION,query:$q,first:10){nodes{... on Discussion{number title url}}}}' \
  -f q='repo:maro114510/skills <words>'
# Post. <category> is DIC_kwDOR_3Rl84DKbjP for Ideas or DIC_kwDOR_3Rl84DKbjN for General
gh api graphql -f query='mutation($r:ID!,$c:ID!,$t:String!,$b:String!){createDiscussion(input:{repositoryId:$r,categoryId:$c,title:$t,body:$b}){discussion{url}}}' \
  -f r=R_kgDOR_3Rlw -f c=<category> -f t='<title>' -F b=@<body-file>
```

## Workflow

1. Create or edit `skills/<skill-name>/SKILL.md`
2. Commit with Conventional Commits
3. Run `claude plugin validate .`
4. Open a PR; CI validates and test-installs
