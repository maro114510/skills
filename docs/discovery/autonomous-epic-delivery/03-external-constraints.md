# External constraints

Status Fact. Verified on 2026-10-14 against official documentation, OpenCode 1.19.0 source, and local command help. The last column names the decision point in 05.

## GitHub

| Constraint | Point |
|---|---|
| Events raised with the default workflow token start no workflow, except manual and external triggers. A pull request opened with it starts its workflow awaiting approval | 7 |
| Check suite and check run completion events do not fire for suites GitHub Actions creates. React to workflow run completion instead | 8 |
| Schedules run at most every 5 minutes, may be delayed or dropped, and stop after 60 idle days on public repositories | 8 |
| Webhooks fail without a reply within 10 seconds. Failed deliveries are not retried. Manual redelivery covers 3 days | 8 |
| Conditional REST requests returning 304 cost no primary rate limit | 8 |
| A pull request author cannot approve their own pull request | 7 |
| Whether a GitHub App approval counts toward required approvals is undocumented | 5 |
| The overall review decision may be empty where reviews are not required. Per-reviewer latest reviews can be filtered to write-access people | 5 |
| Branch protection can dismiss stale approvals and require approval from someone other than the last pusher. Admins bypass by default | 5 |
| Auto-merge is a repository setting and still needs a per-pull-request request | 5 |
| Fork pull requests receive no secrets beyond the default token | 7 |
| Anyone can comment on public Issues and pull requests, so comments are an injection path | 7 |

## OpenCode

| Constraint | Point |
|---|---|
| `opencode run` auto-denies operations that need permission and does not block. Explicit allow and deny rules make it unattended | 8 |
| `--agent` with a subagent name silently falls back to the default. Roles must be primary agents | 8 |
| JSON output includes per-step tokens and cost | 6 |
| No time or money limit. The step limit ends softly with a summary. The caller must impose a timeout | 6 |
| Headless runs still load user configuration and repository skills | 8 |
| Sessions live in a local database and do not move between machines | 2 |
| `opencode serve` with the SDK creates, prompts, and interrupts sessions on a resident server | 8 |
| The official GitHub action ignores workflow run completion and may stall on permission prompts. The stall is inferred from source, not tested | 8 |

## Claude Code for comparison

| Stronger side | Capability |
|---|---|
| Claude Code | Money limit, hard stop at the step limit, blanket denial of permission prompts |
| OpenCode | Per-role model choice, resident server control |

## Unverified

- GitHub App approvals counting toward required approvals
- The official action stalling on permission prompts
- Webhook delivery order

## Sources

- GitHub events that trigger workflows <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>
- GitHub workflow token <https://docs.github.com/en/actions/concepts/security/github_token>
- GitHub REST best practices <https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api>
- GitHub webhook best practices <https://docs.github.com/en/webhooks/using-webhooks/best-practices-for-using-webhooks>
- GitHub failed webhook deliveries <https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries>
- GitHub approving with required reviews <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews>
- GitHub protected branches <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches>
- GitHub GraphQL pull requests <https://docs.github.com/en/graphql/reference/pulls>
- GitHub auto-merge <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request>
- GitHub pull_request_target safety <https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target>
- OpenCode CLI <https://opencode.ai/docs/cli/>
- OpenCode permissions <https://opencode.ai/docs/permissions/>
- OpenCode agents <https://opencode.ai/docs/agents/>
- OpenCode server <https://opencode.ai/docs/server/>
- OpenCode SDK <https://opencode.ai/docs/sdk/>
- OpenCode 1.19.0 run command <https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/cli/cmd/run.ts>
- Claude Code CLI reference <https://code.claude.com/docs/en/cli-reference>
