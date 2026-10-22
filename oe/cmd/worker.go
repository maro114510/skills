package cmd

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/state"
	"github.com/maro114510/skills/oe/internal/worktree"
)

// The worker subcommands hand an Issue to a worker and take its report back, contract §16. Each
// is a coordination subcommand: it refuses --snapshot, takes the Epic's lock, and confirms the
// lease, so only the session that holds the Epic can dispatch.

func newWorkerCmd(env Env, g *globals) *cobra.Command {
	return newGroup("worker", "Hand an Issue to a worker and triage its report",
		newWorktreeCmd(env, g), newBriefCmd(env, g), newReportCmd(env, g))
}

func repoDirFlag(c *cobra.Command, dir *string) {
	c.Flags().StringVar(dir, "repo-dir", ".", "the shared `checkout` of the repository; oe never switches or pulls it")
}

// sharedCheckout resolves the shared checkout to its top level and refuses one whose origin is
// another repository, since its worktrees would not be this repository's.
func sharedCheckout(ctx context.Context, ss session, dir string) (string, error) {
	top, err := ss.client.Git(ctx, "-C", dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", exitcode.Wrap(exitcode.Unreadable, err, dir+" is not a readable checkout")
	}
	url, err := ss.client.Git(ctx, "-C", dir, "remote", "get-url", "origin")
	if err != nil {
		return "", exitcode.Wrap(exitcode.Unreadable, err, "the shared checkout's origin is unreadable")
	}
	origin, err := inputs.ParseRemote(string(url))
	if err != nil || !strings.EqualFold(origin, ss.in.Repo) {
		return "", exitcode.New(exitcode.Refused, "the shared checkout's origin is not "+ss.in.Repo)
	}
	return strings.TrimSpace(string(top)), nil
}

func newWorktreeCmd(env Env, g *globals) *cobra.Command {
	var token, dir string
	var n int
	c := &cobra.Command{
		Use:   "worktree",
		Short: "Create or reuse the worktree for an Issue's recorded branch, from the pinned default branch",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if err := needIssue(n); err != nil {
				return err
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				st, err := ss.s.DispatchState(ctx, n)
				if err != nil {
					return err
				}
				shared, err := sharedCheckout(ctx, ss, dir)
				if err != nil {
					return err
				}
				res, err := worktree.Ensure(ctx, ss.client, worktree.Request{
					Dir: shared, Branch: st.Branch, DefaultBranch: ss.in.DefaultBranch, Recorded: st.HeadSHA,
				})
				if err != nil {
					return err
				}
				return printJSON(c.OutOrStdout(), res)
			})
		},
	}
	c.Flags().IntVar(&n, "issue", 0, "child Issue `number`")
	repoDirFlag(c, &dir)
	tokenFlag(c, &token)
	return c
}

// briefOut is the brief: Prompt is the worker's whole prompt, passed verbatim.
type briefOut struct {
	Issue    int    `json:"issue"`
	Branch   string `json:"branch"`
	Worktree string `json:"worktree"`
	Prompt   string `json:"prompt"`
}

type briefArgs struct {
	n                         int
	token, dir, wt, impl, set string
}

// incomplete refuses a brief with a missing field before any call, so it never spawns.
func incomplete(fields ...string) error {
	return exitcode.New(exitcode.Refused, "incomplete brief, so no worker may be spawned: missing "+strings.Join(fields, ", "))
}

func (a briefArgs) check() error {
	var missing []string
	for _, f := range []struct {
		ok   bool
		name string
	}{{a.n > 0, "--issue"}, {a.wt != "", "--worktree"}, {a.impl != "", "--implement"}, {a.set != "", "--checks-set"}} {
		if !f.ok {
			missing = append(missing, f.name)
		}
	}
	if len(missing) > 0 {
		return incomplete(missing...)
	}
	if st, err := os.Stat(a.impl); !filepath.IsAbs(a.impl) || filepath.Base(a.impl) != "SKILL.md" || err != nil || st.IsDir() {
		return exitcode.New(exitcode.Refused, "incomplete brief: --implement must be the absolute path of an existing implement SKILL.md")
	}
	return nil
}

func newBriefCmd(env Env, g *globals) *cobra.Command {
	var a briefArgs
	c := &cobra.Command{
		Use:   "brief",
		Short: "Render a worker's whole prompt; any missing field refuses, so no worker is spawned",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if err := a.check(); err != nil {
				return err
			}
			set, err := checks.LoadSet(a.set)
			if err != nil {
				return exitcode.Wrap(exitcode.Refused, err, "incomplete brief: CHECKS_SET is unreadable")
			}
			return g.coordinate(c, env, a.token, false, func(ctx context.Context, ss session) error {
				out, err := buildBrief(ctx, ss, a, set)
				if err != nil {
					return err
				}
				return printJSON(c.OutOrStdout(), out)
			})
		},
	}
	c.Flags().IntVar(&a.n, "issue", 0, "child Issue `number`")
	c.Flags().StringVar(&a.wt, "worktree", "", "absolute `path` of the worktree oe worker worktree printed")
	c.Flags().StringVar(&a.impl, "implement", "", "absolute `path` of the implement skill's SKILL.md")
	c.Flags().StringVar(&a.set, "checks-set", "", "CHECKS_SET `file` from oe checks derive")
	repoDirFlag(c, &a.dir)
	tokenFlag(c, &a.token)
	return c
}

func buildBrief(ctx context.Context, ss session, a briefArgs, set checks.Set) (briefOut, error) {
	bc, err := ss.s.BriefContext(ctx, a.n)
	if err != nil {
		return briefOut{}, err
	}
	shared, err := sharedCheckout(ctx, ss, a.dir)
	if err != nil {
		return briefOut{}, err
	}
	e, err := dispatchedWorktree(ctx, ss, shared, a.wt, bc.State)
	if err != nil {
		return briefOut{}, err
	}
	if e.Head != "" && bc.State.HeadSHA != nil && *bc.State.HeadSHA != e.Head {
		return briefOut{}, exitcode.New(exitcode.Refused, "the worktree's HEAD "+e.Head+" diverged from the recorded head "+
			*bc.State.HeadSHA+"; a person must decide which is right")
	}
	runnable, err := currentRunnable(ctx, ss, shared, set)
	if err != nil {
		return briefOut{}, err
	}
	b := handoff.Brief{
		Repo: ss.in.Repo, Epic: ss.in.Epic, Issue: a.n, RepoRoot: shared, Branch: bc.State.Branch, Worktree: e.Path,
		ImplementPath: a.impl, Checks: runnable, PendingFindings: bc.State.PendingFindings, Decision: bc.State.Decision,
		Context: bc.Context, Notes: bc.Notes, PriorFailure: bc.PriorFailure,
	}
	if m := b.Missing(); len(m) > 0 {
		return briefOut{}, incomplete(m...)
	}
	return briefOut{Issue: a.n, Branch: b.Branch, Worktree: b.Worktree, Prompt: handoff.Render(b)}, nil
}

// currentRunnable returns CHECKS_SET's runnable entries, refusing a set derived at any commit
// but the current origin/<default>.
func currentRunnable(ctx context.Context, ss session, shared string, set checks.Set) ([]checks.Entry, error) {
	base, err := ss.client.Git(ctx, "-C", shared, "rev-parse", "--verify", "refs/remotes/origin/"+ss.in.DefaultBranch+"^{commit}")
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(string(base)) != set.Revision {
		return nil, exitcode.New(exitcode.Stale, "CHECKS_SET was derived at "+set.Revision+", not origin/"+ss.in.DefaultBranch+
			"; derive it again")
	}
	runnable := []checks.Entry{}
	for _, entry := range set.Entries {
		if entry.Runnable {
			runnable = append(runnable, entry)
		}
	}
	return runnable, nil
}

// dispatchedWorktree checks the worktree a worker was or will be given: registered, not the
// shared checkout, and on the branch the Issue state records.
func dispatchedWorktree(ctx context.Context, ss session, shared, path string, st state.Issue) (worktree.Entry, error) {
	return worktree.Verify(ctx, ss.client, shared, path, st.Branch)
}

type reportArgs struct {
	n                                int
	token, dir, wt, file, answerFile string
	shipClass                        []string
	commitApproval                   bool
	kinds                            []handoff.ShipClass
	report                           handoff.Report
	parseErr                         error
	answer                           string
}

// check parses the report and refuses flags it cannot take before any call: a ship-class kind
// outside the closed set, a judgment on anything but a BLOCKED report, or an answer to a
// question the loop never answers.
func (a *reportArgs) check(c *cobra.Command) error {
	if err := needIssue(a.n); err != nil {
		return err
	}
	if a.wt == "" {
		return exitcode.New(exitcode.Usage, "report needs --worktree, the worktree the worker was dispatched to")
	}
	text, err := readText(c, a.file)
	if err != nil {
		return err
	}
	a.report, a.parseErr = handoff.Parse(text)
	return a.checkJudgments()
}

func (a *reportArgs) parseKinds() error {
	for _, s := range a.shipClass {
		k, ok := handoff.ParseShipClass(s)
		if !ok {
			return exitcode.New(exitcode.Usage, "--ship-class must be secret, split, or scope, not "+s)
		}
		a.kinds = append(a.kinds, k)
	}
	return nil
}

// judged reports whether the Publisher passed any judgment on the report's questions.
func (a *reportArgs) judged() bool { return len(a.kinds) > 0 || a.commitApproval || a.answerFile != "" }

func (a *reportArgs) blocked() bool {
	return a.parseErr == nil && a.report.Status == handoff.StatusBlocked
}

func (a *reportArgs) checkJudgments() error {
	if err := a.parseKinds(); err != nil {
		return err
	}
	switch {
	case a.judged() && !a.blocked():
		return exitcode.New(exitcode.Usage, "--ship-class, --commit-approval, and --answer-file apply only to a well-formed BLOCKED report")
	case a.answerFile != "" && (len(a.kinds) > 0 || a.commitApproval):
		return exitcode.New(exitcode.Usage, "a ship-class or commit-approval question is never auto-answered; drop --answer-file")
	case a.answerFile != "":
		data, err := os.ReadFile(a.answerFile)
		a.answer = string(data)
		if err != nil {
			return exitcode.New(exitcode.Usage, "cannot read --answer-file")
		}
	}
	return nil
}

func newReportCmd(env Env, g *globals) *cobra.Command {
	var a reportArgs
	c := &cobra.Command{
		Use:   "report",
		Short: "Route a worker report: DONE to review, BLOCKED to a question, FAILED to a retry or a park",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if err := a.check(c); err != nil {
				return err
			}
			return g.coordinate(c, env, a.token, false, func(ctx context.Context, ss session) error {
				t, err := a.triage(ctx, ss)
				if err != nil {
					return err
				}
				res, err := ss.s.Triage(ctx, a.n, t)
				if res.Route == "" {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	c.Flags().IntVar(&a.n, "issue", 0, "child Issue `number`")
	c.Flags().StringVar(&a.wt, "worktree", "", "absolute `path` of the worktree the worker was dispatched to")
	c.Flags().StringVar(&a.file, "file", "", "`file` holding the worker's final message; default or -: stdin")
	c.Flags().StringArrayVar(&a.shipClass, "ship-class", nil, "the BLOCKED question is ship-class of this `kind`: secret, split, or scope")
	c.Flags().BoolVar(&a.commitApproval, "commit-approval", false, "the BLOCKED question asks to approve a commit; never auto-answered")
	c.Flags().StringVar(&a.answerFile, "answer-file", "", "`file` with the answer from written sources to a BLOCKED question")
	repoDirFlag(c, &a.dir)
	tokenFlag(c, &a.token)
	return c
}

func (a *reportArgs) triage(ctx context.Context, ss session) (coord.Triage, error) {
	st, err := ss.s.DispatchState(ctx, a.n)
	if err != nil {
		return coord.Triage{}, err
	}
	shared, err := sharedCheckout(ctx, ss, a.dir)
	if err != nil {
		return coord.Triage{}, err
	}
	e, err := dispatchedWorktree(ctx, ss, shared, a.wt, st)
	if err != nil {
		return coord.Triage{}, err
	}
	dirty, err := worktree.Dirty(ctx, ss.client, e.Path)
	if err != nil {
		return coord.Triage{}, err
	}
	return coord.Triage{
		Report: a.report, ParseErr: a.parseErr, Worktree: e.Path, Head: e.Head, Dirty: dirty,
		ShipClass: a.kinds, CommitApproval: a.commitApproval, Answer: a.answer,
	}, nil
}
