# Repository rulesets

`main.json` is the "Protect main" ruleset for the `main` branch. A ruleset is a repository setting, so a pull request cannot create it: the repository admin applies it.

## Apply

```bash
bash .github/rulesets/apply.sh maro114510/skills
```

The script creates the ruleset, or updates the one named "Protect main" so that rerunning it after an edit to `main.json` is safe. It needs `gh` authenticated as a repository admin.

## What it enforces

| Rule | Effect |
|---|---|
| `pull_request` | A change reaches `main` only through a pull request with 1 approval, and a code owner's approval when `.github/CODEOWNERS` names one |
| `required_status_checks` | The checks below must pass before merge |
| `deletion`, `non_fast_forward` | `main` cannot be deleted or force-pushed |
| Bypass | The Repository admin role bypasses every rule, so `make release` can push its release commit |

Required checks are only jobs of workflows that run on every pull request. A job of a path-filtered workflow, such as lint-shell, never starts for a pull request that misses its paths, and a required check that never starts stays pending forever. Add a check here only after confirming its workflow has no `paths:` under `on:`.

## Limits

- The admin bypass also lets the admin merge a pull request whose checks failed, through GitHub's explicit bypass prompt. Nobody else can.
- A push ruleset's "Restrict file paths" rule would block pushes that change `.github/workflows/**`, but GitHub offers push rulesets only for private and internal repositories. This repository is public, so `.github/CODEOWNERS` is the only layer over workflow changes, and it acts at merge: a workflow changed on a pull request branch still runs there before the owner reviews it.

## Verify

```bash
gh api repos/maro114510/skills/rules/branches/main
```

The output lists the rules and the required checks above.
