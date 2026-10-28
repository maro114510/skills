# Ship

For each Issue whose `next` is `ship`:

```bash
oe ship publish --issue <N> --worktree <WORKTREE> --checks-set <CHECKS_FILE> --repo-dir <REPO_DIR> --title <TITLE> --report-file <REPORT_FILE> --create-pr-scripts <CREATE_PR_SCRIPTS> --lease-token <TOKEN>
```

- `--title` is a Conventional Commits title, `type(scope): subject`, under 70 characters and specific to the Issue. The type and scope stay English, and the subject is in the repository's usual language.
- `--report-file` is the worker's DONE report file that step 6 of `dispatch.md` kept at its fixed path.
- Add `--nits-file <NITS_FILE>` only when the reviewer raised nits that a fix cycle resolved: a file saying how each was resolved, written the way a report file is. Otherwise leave it out.

`oe` scans for secrets, checks freshness, runs CHECKS_SET, checks the freeze again, pushes, and opens or links the pull request. It prints a route, and one Issue's failure never stops the others.

- `PUBLISHED` with `next` `land`: add the pull request to Ship Report.
- Read the exit code first, with the router's table. `INTERRUPTED` carries the exit code of what interrupted it, and it never overrides a stop.
- Exit 3: the pair went stale. Pin again with `review.md`.
- Exit 4: the Epic froze. Render Frozen Epic and stop.
- Exits 6, 7, and 8: stop, and report the verdict line.
- `INTERRUPTED` with exit 1 or 5: do not run it again in this pass. The publish stays recorded, and the same command in the next round resumes from the recorded phase.
- Anything else is an Issue `oe` parked, for a secret or red checks: nothing more. Report its `reason` with Escalation.
