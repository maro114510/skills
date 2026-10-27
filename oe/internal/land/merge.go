package land

import (
	"context"
	"errors"
	"fmt"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gate"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/readiness"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// flow is one landing pass over one Issue.
type flow struct {
	d   Deps
	n   int
	res Result

	st state.Issue
	a  state.Approval
	pr int
	// method is the merge method this pass will request, and board the Epic's state as read for the health gate.
	method string
	board  *snapshot.Board
}

func newFlow(d Deps, n int) *flow {
	var st state.Issue
	var a state.Approval
	return &flow{d: d, n: n, res: NewResult(n), st: st, a: a, pr: 0, method: "", board: nil}
}

// Merge lands the Issue's pull request, contract §8.
// The order is fixed: reconcile an unresolved record, then the approval and its pull request, the freeze, the base, health,
// the grant, the merge method, readiness, the final freeze, grant, and base checks, the intent, and one request.
// Nothing is retried, and a request whose outcome is uncertain is settled from the pull request.
func Merge(ctx context.Context, d Deps, n int) (Result, error) {
	f := newFlow(d, n)
	err := f.run(ctx)
	return f.res, err
}

type stage func(ctx context.Context) (bool, error)

func always(step func(ctx context.Context) error) stage {
	return func(ctx context.Context) (bool, error) { return false, step(ctx) }
}

func (f *flow) run(ctx context.Context) error {
	for _, step := range []stage{
		f.settle, always(f.enter), always(f.freezeAndBase), always(f.health), always(f.authorizedByBoard),
		f.pickMethod, f.ready, always(f.finalGates), always(f.request),
	} {
		if done, err := step(ctx); done || err != nil {
			return err
		}
	}
	return nil
}

func (f *flow) refused(format string, args ...any) error {
	return exitcode.New(exitcode.Refused, fmt.Sprintf(format, args...))
}

// enter checks what a merge starts from: the Issue's approval, and the open pull request it was published as.
func (f *flow) enter(ctx context.Context) error {
	st, err := f.d.S.DispatchState(ctx, f.n)
	if err != nil {
		return err
	}
	f.st = st
	if st.Approval == nil {
		return f.refused("#%d has no approval, so nothing may be merged; run oe review pin and verdict first", f.n)
	}
	f.a = *st.Approval
	p := st.Publish
	switch {
	case p == nil || p.Phase != coord.PublishLinked || p.PR <= 0:
		return f.refused("#%d has no linked pull request; run oe ship publish first", f.n)
	case p.SHA != f.a.ReviewedSHA || p.Base != f.a.VerifiedBase:
		return f.refused("#%d shipped %s on %s, not the approved %s on %s; run oe ship publish again", f.n, p.SHA, p.Base, f.a.ReviewedSHA, f.a.VerifiedBase)
	}
	f.pr = p.PR
	f.res.PR, f.res.ReviewedSHA, f.res.VerifiedBase = f.pr, f.a.ReviewedSHA, f.a.VerifiedBase
	return f.openPR(ctx)
}

// openPR requires that the one open pull request of the Issue's branch is the one the state names, on the default branch.
// A person decides anything else, since merging a pull request the state does not name merges an unreviewed commit.
func (f *flow) openPR(ctx context.Context) error {
	prs, err := snapshot.ReadBranchPRs(ctx, f.d.Client, f.d.In.Repo, f.st.Branch)
	if err != nil {
		return err
	}
	var open []snapshot.BranchPR
	for _, pr := range prs {
		if pr.State == snapshot.StateOpen {
			open = append(open, pr)
		}
	}
	switch {
	case len(open) != 1:
		return f.refused("%s has %d open pull requests, not the one pull request #%d the state names; a person decides", f.st.Branch, len(open), f.pr)
	case open[0].Number != f.pr:
		return f.refused("the open pull request of %s is #%d, not #%d the state names; a person decides", f.st.Branch, open[0].Number, f.pr)
	case open[0].Base != f.d.In.DefaultBranch:
		return f.refused("pull request #%d targets %s, not the default branch %s; a person decides", f.pr, open[0].Base, f.d.In.DefaultBranch)
	}
	return nil
}

// freezeAndBase stops on a frozen Epic and on a default branch that moved since verification.
func (f *flow) freezeAndBase(ctx context.Context) error {
	if _, err := f.d.S.Check(ctx); err != nil {
		return err
	}
	return f.baseUnmoved(ctx)
}

// baseUnmoved re-reads the default branch from GitHub. A moved base routes the Issue to re-verification and never parks it.
func (f *flow) baseUnmoved(ctx context.Context) error {
	live, err := snapshot.ReadBranchHead(ctx, f.d.Client, f.d.In.Repo, f.d.In.DefaultBranch)
	if err != nil {
		return err
	}
	if live != f.a.VerifiedBase {
		return exitcode.New(exitcode.Stale, fmt.Sprintf("%s is at %s, not the verified %s; review #%d again against it", f.d.In.DefaultBranch, live, f.a.VerifiedBase, f.n))
	}
	return nil
}

// health holds every merge until the checks on the last merge's commit passed, and freezes the Epic when they failed.
func (f *flow) health(ctx context.Context) error {
	b, err := snapshot.ReadEpicState(ctx, f.d.Client, f.d.In)
	if err != nil {
		if exitcode.CodeOf(err) == exitcode.Unreadable {
			return exitcode.Wrap(exitcode.Stop, err, "post-merge health could not be read, so every merge is held")
		}
		return err
	}
	f.board = b
	h := health.FromBoard(b)
	switch h.Next {
	case health.NextProceed:
		return nil
	case health.NextWait:
		return exitcode.New(exitcode.Wait, "the default-branch checks of the last merge are still pending: "+h.Reason)
	case health.NextFreeze:
		reason := fmt.Sprintf("post-merge default-branch checks %s on %s (PR #%d): %s", h.Status, h.Merge, h.PR, h.Reason)
		lr, err := f.d.S.Freeze(ctx, reason, h.Merge, string(h.Status))
		f.res.Freeze = lr.Freeze
		if lr.Freeze != nil {
			f.res.Route, f.res.Next, f.res.Reason = RouteFrozen, NextStop, reason
		}
		return err
	case health.NextHold:
		return exitcode.New(exitcode.Stop, "post-merge health is unreadable, so every merge is held: "+h.Reason)
	}
	return exitcode.New(exitcode.Stop, "post-merge health has the unexpected next action "+string(h.Next))
}

// authorizedByBoard checks the merge grant in the Epic's comments the health gate read.
func (f *flow) authorizedByBoard(context.Context) error {
	return f.authorized(f.board.Comments[f.d.In.Epic])
}

// authorized requires an approval and a grant that no later revoke withdrew. A grant that cannot be read is no grant.
func (f *flow) authorized(comments []snapshot.Comment) error {
	sig, err := gate.Read(comments, f.d.In.Me)
	if err != nil {
		return err
	}
	switch {
	case !sig.Approved():
		return f.refused("the Epic carries no epic-approve above its Run Plan, so nothing may be merged")
	case !sig.MergeGrant.Granted:
		return f.refused("merging is not authorized: there is no epic-auto-merge above the Run Plan, or a later epic-revoke-auto-merge withdrew it")
	}
	return nil
}

// pickMethod prefers a merge commit, then a squash, and never a rebase, which replaces the reviewed commits.
// A repository that allows only rebasing is left for a person.
func (f *flow) pickMethod(ctx context.Context) (bool, error) {
	s, err := snapshot.ReadMergeSettings(ctx, f.d.Client, f.d.In.Repo)
	if err != nil {
		return false, err
	}
	switch {
	case s.MergeCommit:
		f.method = "merge"
	case s.Squash:
		f.method = "squash"
	default:
		return true, f.hold(ctx, "the repository allows only rebase merging, which replaces the reviewed commits, so the loop leaves the merge to a person")
	}
	f.res.Method = f.method
	return false, nil
}

// ready classifies the pull request and ends the pass on anything but READY on exactly the reviewed head.
func (f *flow) ready(ctx context.Context) (bool, error) {
	pr, err := snapshot.ReadPullRequest(ctx, f.d.Client, f.d.In.Repo, f.pr)
	if err != nil {
		return false, err
	}
	rd := readiness.Classify(pr)
	switch {
	case rd.Unreadable:
		return false, exitcode.New(exitcode.Unreadable, fmt.Sprintf("pull request #%d is held (status BLOCKED, next human): %s", f.pr, rd.Reason))
	case rd.Status == readiness.Merged || rd.Status == readiness.Closed:
		return false, f.refused("pull request #%d is %s; the board classifies the Issue", f.pr, rd.Reason)
	case rd.Head != f.a.ReviewedSHA:
		return false, exitcode.New(exitcode.Stale, fmt.Sprintf("pull request #%d is at %s, not the reviewed %s; review #%d again", f.pr, rd.Head, f.a.ReviewedSHA, f.n))
	}
	switch rd.Next {
	case readiness.NextMerge:
		return false, nil
	case readiness.NextWait:
		return false, exitcode.New(exitcode.Wait, fmt.Sprintf("pull request #%d is not ready yet: %s", f.pr, rd.Reason))
	case readiness.NextRepair:
		return true, f.held(NextRepair, rd.Reason, kinds(rd.Repair))
	case readiness.NextHuman, readiness.NextNone:
	}
	return true, f.hold(ctx, rd.Reason)
}

func kinds(rs []readiness.Repair) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, string(r))
	}
	return out
}

// held ends the pass on a pull request that stays open.
func (f *flow) held(next, reason string, repair []string) error {
	f.res.Route, f.res.Next, f.res.Reason, f.res.Repair = RouteHeld, next, reason, repair
	return nil
}

// hold posts the merge hold once per pull request, head, and reason, and ends the pass with a hold only a person lifts.
func (f *flow) hold(ctx context.Context, reason string) error {
	nr, err := f.d.S.PostNote(ctx, f.n, fmt.Sprintf("merge-hold:%d:%s:%s", f.pr, f.a.ReviewedSHA, coord.DigestPlaceholder),
		MergeHoldNote(f.pr, f.a.ReviewedSHA, reason))
	if err != nil {
		return err
	}
	f.res.Notes = append(f.res.Notes, nr)
	return f.held(NextHuman, reason, []string{})
}

// finalGates read the freeze, health, grant, and base again, right before the intent, since each can change while the pass runs.
func (f *flow) finalGates(ctx context.Context) error {
	if _, err := f.d.S.Check(ctx); err != nil {
		return err
	}
	if err := f.health(ctx); err != nil {
		return err
	}
	if err := f.authorizedByBoard(ctx); err != nil {
		return err
	}
	return f.baseUnmoved(ctx)
}

// request records the intent, sends one merge request with the reviewed head as its expected SHA, and records how it ended.
func (f *flow) request(ctx context.Context) error {
	t := target{pr: f.pr, issue: f.n, reviewed: f.a.ReviewedSHA, base: f.a.VerifiedBase, method: f.method}
	if _, err := f.d.S.RecordMergeIntent(ctx, coord.MergeIntent{PR: t.pr, Issue: t.issue, ReviewedSHA: t.reviewed, VerifiedBase: t.base}); err != nil {
		return err
	}
	// The intent took several calls and the expected SHA pins only the head, so what the request depends on is read once more.
	// A request is never sent past a moved base, a retargeted pull request, or a lost lease.
	// The first two resolve the intent as not merged, since nothing was requested. A lost lease cannot write, so the next pass settles it.
	if err := f.beforeRequest(ctx); err != nil {
		if code := exitcode.CodeOf(err); code != exitcode.Stale && code != exitcode.Refused {
			return err
		}
		if _, cerr := f.conclude(ctx, t, outcome{phase: state.PhaseNotMerged, mergeSHA: "", detail: "the pair changed after the intent, so nothing was requested: " + err.Error()}); cerr != nil {
			return cerr
		}
		return err
	}
	o, err := f.send(ctx, t)
	if err != nil {
		return err
	}
	o, err = f.conclude(ctx, t, o)
	if err != nil {
		return err
	}
	return f.report(ctx, t, o, false)
}

// beforeRequest reads the base, the pull request's target, and the lease once more, right before the request.
// The request goes out by a direct call that no per-write lease check guards, so the lease is checked here.
func (f *flow) beforeRequest(ctx context.Context) error {
	if err := f.baseUnmoved(ctx); err != nil {
		return err
	}
	if err := f.openPR(ctx); err != nil {
		return err
	}
	return f.d.S.Verify(ctx)
}

// send is the merge request, as REST and never as gh pr merge, which turns on auto-merge or enqueues the pull request when requirements are unmet.
// The expected SHA makes GitHub refuse with 409 when the head is no longer the reviewed commit.
// It checks only the head, so a base that moved meanwhile is caught on the merge commit afterwards.
func (f *flow) send(ctx context.Context, t target) (outcome, error) {
	path := fmt.Sprintf("repos/%s/pulls/%d/merge", f.d.In.Repo, t.pr)
	resp, err := f.d.Client.WriteHTTP(ctx, "api", "-X", "PUT", path, "-f", "sha="+t.reviewed, "-f", "merge_method="+t.method)
	if err != nil {
		if errors.Is(err, gh.ErrNoResponse) {
			return f.fromPull(ctx, t, false), nil
		}
		return outcome{}, err
	}
	return f.classify(ctx, t, resp), nil
}
