package cmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/integrate"
	"github.com/maro114510/skills/oe/internal/review"
	"github.com/maro114510/skills/oe/internal/scan"
	"github.com/maro114510/skills/oe/internal/state"
	"github.com/maro114510/skills/oe/internal/worktree"
)

// The review subcommands integrate the base, pin the pair under review, and bind a reviewer's verdict.
// Each refuses --snapshot, takes the Epic's lock, and confirms the lease like every coordination subcommand.
// The integration merge is the only commit, and oe makes it, so the model never commits.

func newReviewCmd(env Env, g *globals) *cobra.Command {
	return newGroup("review", "Integrate the base, pin the pair under review, and bind a reviewer's verdict",
		newPinCmd(env, g), newVerdictCmd(env, g))
}

type reviewArgs struct {
	n                         int
	token, dir, wt, set, file string
	shipClass                 []string
	kinds                     []handoff.ShipClass
}

func (a *reviewArgs) flags(c *cobra.Command) {
	c.Flags().IntVar(&a.n, "issue", 0, "child Issue `number`")
	c.Flags().StringVar(&a.wt, "worktree", "", "absolute `path` of the Issue's worktree")
	c.Flags().StringVar(&a.set, "checks-set", "", "CHECKS_SET `file` from oe checks derive at origin/<default branch>")
	repoDirFlag(c, &a.dir)
	tokenFlag(c, &a.token)
}

func (a *reviewArgs) check() (checks.Set, error) {
	if err := needIssue(a.n); err != nil {
		return checks.Set{}, err
	}
	if a.wt == "" || a.set == "" {
		return checks.Set{}, exitcode.New(exitcode.Usage, "review needs --worktree and --checks-set")
	}
	for _, s := range a.shipClass {
		k, ok := handoff.ParseShipClass(s)
		if !ok {
			return checks.Set{}, exitcode.New(exitcode.Usage, "--ship-class must be secret, split, or scope, not "+s)
		}
		a.kinds = append(a.kinds, k)
	}
	set, err := checks.LoadSet(a.set)
	if err != nil {
		return checks.Set{}, exitcode.Wrap(exitcode.Refused, err, "CHECKS_SET is unreadable")
	}
	return set, nil
}

// reviewSite is the verified state and worktree of the Issue, with the default branch read once.
type reviewSite struct {
	st     state.Issue
	shared string
	e      worktree.Entry
	base   string
}

func site(ctx context.Context, ss session, a *reviewArgs) (reviewSite, error) {
	var rs reviewSite
	st, err := ss.s.DispatchState(ctx, a.n)
	if err != nil {
		return rs, err
	}
	if st.HeadSHA == nil {
		return rs, exitcode.New(exitcode.Refused, fmt.Sprintf("#%d has no recorded head; only a DONE worker report records one to review", a.n))
	}
	shared, err := sharedCheckout(ctx, ss, a.dir)
	if err != nil {
		return rs, err
	}
	e, err := dispatchedWorktree(ctx, ss, shared, a.wt, st)
	if err != nil {
		return rs, err
	}
	base, err := integrate.Rev(ctx, ss.client, shared, "refs/remotes/origin/"+ss.in.DefaultBranch)
	if err != nil {
		return rs, err
	}
	return reviewSite{st: st, shared: shared, e: e, base: base}, nil
}

// pinOut is the pinned pair, with the reviewer's whole prompt once it is ready for review.
type pinOut struct {
	coord.ReviewResult

	Branch        string            `json:"branch"`
	Worktree      string            `json:"worktree"`
	DefaultBranch string            `json:"default_branch"`
	Integration   *integrate.Result `json:"integration"`
	Prompt        string            `json:"prompt"`
}

func newPinCmd(env Env, g *globals) *cobra.Command {
	var a reviewArgs
	c := &cobra.Command{
		Use:   "pin",
		Short: "Merge the pinned default branch into an Issue's branch and pin the pair a fresh reviewer reviews",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			set, err := a.check()
			if err != nil {
				return err
			}
			return g.coordinate(c, env, a.token, false, func(ctx context.Context, ss session) error {
				out, err := pin(ctx, ss, &a, set)
				if out.Route == "" {
					return err
				}
				return emit(c, out, err)
			})
		},
	}
	a.flags(c)
	return c
}

func pin(ctx context.Context, ss session, a *reviewArgs, set checks.Set) (pinOut, error) {
	out := pinOut{ReviewResult: coord.NewReviewResult(a.n), Branch: "", Worktree: "", DefaultBranch: ss.in.DefaultBranch, Integration: nil, Prompt: ""}
	rs, err := site(ctx, ss, a)
	if err != nil {
		return out, err
	}
	out.Branch, out.Worktree = rs.st.Branch, rs.e.Path
	// A stale CHECKS_SET is refused before anything is written.
	runnable, err := runnableAt(ss, set, rs.base)
	if err != nil {
		return out, err
	}
	if done, err := boundOrStale(ctx, ss, a.n, rs, &out); done || err != nil {
		return out, err
	}
	ir, err := integrateAndRecord(ctx, ss, a.n, rs, &out)
	if err != nil {
		return out, err
	}
	if f := integrationFindings(ir, rs.st.Branch); len(f) > 0 {
		err := ss.s.RouteFindings(ctx, a.n, f, nil, ir.Head, &out.ReviewResult)
		out.Head, out.Base = ir.Head, rs.base
		return out, err
	}
	st, err := ss.s.DispatchState(ctx, a.n)
	if err != nil {
		return out, err
	}
	out.State, out.Route, out.Next = st, coord.RoutePinned, coord.NextReview
	out.Reason = "the pair is pinned; spawn a fresh reviewer with the prompt"
	out.Prompt = review.Render(review.Brief{
		Repo: ss.in.Repo, Epic: ss.in.Epic, Issue: a.n, Branch: rs.st.Branch, Worktree: rs.e.Path, DefaultBranch: ss.in.DefaultBranch,
		Base: rs.base, Head: ir.Head, ChecksRevision: set.Revision, Checks: runnable,
	})
	return out, nil
}

// runnableAt returns CHECKS_SET's runnable entries when the set was derived for the default branch at base, the commit this pass read once.
// A second read of the ref could see a fetch that the rest of the pass never saw.
func runnableAt(ss session, set checks.Set, base string) ([]checks.Entry, error) {
	if set.Base != ss.in.DefaultBranch {
		return nil, exitcode.New(exitcode.Stale, "CHECKS_SET was derived for the default branch "+set.Base+", not "+ss.in.DefaultBranch+"; derive it again")
	}
	if set.Revision != base {
		return nil, exitcode.New(exitcode.Stale, "CHECKS_SET was derived at "+set.Revision+", not origin/"+ss.in.DefaultBranch+" "+base+"; derive it again")
	}
	runnable := []checks.Entry{}
	for _, e := range set.Entries {
		if e.Runnable {
			runnable = append(runnable, e)
		}
	}
	return runnable, nil
}

// boundOrStale handles an Issue that already holds an approval and reports whether the pass ends here.
//   - On the same pair it stays bound and goes to shipping.
//   - On a moved pair it is stale, and a second staleness in the session defers it.
func boundOrStale(ctx context.Context, ss session, n int, rs reviewSite, out *pinOut) (bool, error) {
	ap, head := rs.st.Approval, *rs.st.HeadSHA
	switch {
	case ap == nil:
		return false, nil
	case rs.e.Head != head:
		// Integration would adopt or refuse this head, but an approval must never ship or go stale on a commit nobody recorded.
		return true, exitcode.New(exitcode.Refused, fmt.Sprintf("the worktree's HEAD %s is not the recorded head %s; a person must decide which is right", rs.e.Head, head))
	case ap.ReviewedSHA == head && ap.VerifiedBase == rs.base:
		out.Route, out.Next, out.Head, out.Base, out.State = coord.RouteBound, coord.NextShip, head, rs.base, rs.st
		out.Reason = "the approval is bound to this head and base"
		return true, nil
	}
	why := "the default branch moved from the verified base " + ap.VerifiedBase
	err := ss.s.Stale(ctx, n, head, rs.base, why, &out.ReviewResult)
	return err != nil || out.Next == coord.NextDefer, err
}

// integrateAndRecord merges the base in and records any head that oe made or adopted before anything else reads the state.
func integrateAndRecord(ctx context.Context, ss session, n int, rs reviewSite, out *pinOut) (integrate.Result, error) {
	head := *rs.st.HeadSHA
	ir, err := integrate.Integrate(ctx, ss.client, integrate.Request{Worktree: rs.e.Path, Branch: rs.st.Branch, Recorded: head, Base: rs.base})
	out.Integration = &ir
	if err != nil {
		return ir, err
	}
	out.Head, out.Base = ir.Head, rs.base
	if ir.Head != head {
		next, err := ss.s.Update(ctx, n, coord.RecordHead{SHA: ir.Head})
		out.State = next
		return ir, err
	}
	return ir, nil
}

// integrationFindings turns a dirty worktree or a conflicting merge into a blocking finding for a fresh worker.
func integrationFindings(ir integrate.Result, branch string) []string {
	switch {
	case len(ir.Dirty) > 0:
		return []string{"[blocking] the worktree holds uncommitted changes in " + strings.Join(ir.Dirty, ", ") +
			"; commit or discard them, since review covers committed content only"}
	case len(ir.Conflicts) > 0:
		return []string{"[blocking] merge " + ir.Base + " into " + branch + " with a plain merge commit, never a rebase, and resolve the conflicts in " +
			strings.Join(ir.Conflicts, ", ")}
	}
	return nil
}

func newVerdictCmd(env Env, g *globals) *cobra.Command {
	var a reviewArgs
	c := &cobra.Command{
		Use:   "verdict",
		Short: "Validate a reviewer report and bind its approval, or route it to a fix cycle, a park, or a staleness pass",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			set, err := a.check()
			if err != nil {
				return err
			}
			text, err := readText(c, a.file)
			if err != nil {
				return err
			}
			rep, parseErr := review.Parse(text)
			return g.coordinate(c, env, a.token, false, func(ctx context.Context, ss session) error {
				if parseErr != nil {
					// A missing lease or --snapshot is reported before a malformed report, and neither writes anything.
					msg := parseErr.Error()
					// The error may quote the report, which the verdict line would print.
					if report := scan.Text("reviewer-report-error", []byte(msg)); !report.Clean {
						msg = "malformed reviewer report; its text holds a suspected secret and is withheld"
					}
					return exitcode.New(exitcode.Refused, msg+": the reviewer report binds nothing; spawn a fresh reviewer")
				}
				res, err := verdict(ctx, ss, &a, set, rep)
				if res.Route == "" {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	a.flags(c)
	c.Flags().StringVar(&a.file, "file", "", "`file` holding the reviewer's final message; default or -: stdin")
	c.Flags().StringArrayVar(&a.shipClass, "ship-class", nil, "a finding is ship-class of this `kind`: secret, split, or scope")
	return c
}

func verdict(ctx context.Context, ss session, a *reviewArgs, set checks.Set, rep review.Report) (coord.ReviewResult, error) {
	rs, err := site(ctx, ss, a)
	if err != nil {
		return coord.NewReviewResult(a.n), err
	}
	// A CHECKS_SET from another base exits 3 for the caller to derive again, so only the report itself can start a staleness pass.
	if _, err := runnableAt(ss, set, rs.base); err != nil {
		return coord.NewReviewResult(a.n), err
	}
	integrated, err := integrate.Ancestor(ctx, ss.client, rs.e.Path, rs.base, rs.e.Head)
	if err != nil {
		return coord.NewReviewResult(a.n), err
	}
	dirty, err := integrate.DirtyPaths(ctx, ss.client, rs.e.Path)
	if err != nil {
		return coord.NewReviewResult(a.n), err
	}
	runnable := 0
	for _, e := range set.Entries {
		if e.Runnable {
			runnable++
		}
	}
	return ss.s.Verdict(ctx, a.n, coord.Verdict{
		Report: rep, Repo: ss.in.Repo, Head: rs.e.Head, Base: rs.base, Integrated: integrated,
		ChecksRevision: set.Revision, Runnable: runnable, Dirty: dirty, ShipClass: a.kinds,
	})
}
