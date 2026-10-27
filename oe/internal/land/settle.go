package land

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// target is the merge an outcome belongs to: the one this pass requested, or the one an earlier run recorded.
type target struct {
	pr, issue              int
	reviewed, base, method string
}

// outcome is how a merge request ended.
type outcome struct {
	phase    string
	mergeSHA string
	detail   string
}

// classify turns GitHub's answer to the merge request into an outcome, without sending anything again.
func (f *flow) classify(ctx context.Context, t target, resp gh.Response) outcome {
	var body struct {
		SHA     string `json:"sha"`
		Merged  bool   `json:"merged"`
		Message string `json:"message"`
	}
	_ = json.Unmarshal(resp.Body, &body)
	switch {
	case resp.Status == http.StatusOK && body.Merged && body.SHA != "":
		return outcome{phase: state.PhaseMerged, mergeSHA: body.SHA, detail: body.SHA}
	case resp.Status == http.StatusConflict:
		return outcome{phase: state.PhaseHeadMoved, mergeSHA: "", detail: body.Message}
	case resp.Status >= http.StatusInternalServerError || resp.Status == http.StatusOK:
		// A server error may still have merged, and a 200 without a merge commit proves nothing, so the pull request says.
		return f.fromPull(ctx, t, false)
	}
	return outcome{phase: state.PhaseRejected, mergeSHA: "", detail: fmt.Sprintf("HTTP %d: %s", resp.Status, body.Message)}
}

// fromPull reads what GitHub did from the pull request, never from the request.
// A pull request that is still open is unknown right after a request that was never answered,
// and not merged when an earlier run's record is settled.
// The read goes through a probe, so one that fails leaves the outcome to record as unknown instead of forbidding the record.
func (f *flow) fromPull(ctx context.Context, t target, openIsNotMerged bool) outcome {
	pull, err := snapshot.ReadMergePull(ctx, f.d.Client.Probe(), f.d.In.Repo, t.pr)
	if err != nil {
		return outcome{phase: state.PhaseUnknown, mergeSHA: "", detail: "the pull request could not be read, so whether it merged is unknown"}
	}
	st := ""
	if pull.State != nil {
		st = *pull.State
	}
	switch {
	case st == "MERGED" && pull.MergeCommit != nil && pull.MergeCommit.OID != nil && *pull.MergeCommit.OID != "":
		return outcome{phase: state.PhaseMerged, mergeSHA: *pull.MergeCommit.OID, detail: *pull.MergeCommit.OID}
	case (st == "OPEN" || st == "CLOSED") && openIsNotMerged:
		return outcome{phase: state.PhaseNotMerged, mergeSHA: "", detail: "the pull request is " + st + " and was not merged"}
	}
	return outcome{phase: state.PhaseUnknown, mergeSHA: "", detail: "the request was not answered and the pull request is " + st + ", so whether it merged is unknown"}
}

// settle reconciles a post-merge record an earlier run left at intent or unknown, before anything else.
// It ends the pass, since a merge or a request is never made in the same pass that settled one.
func (f *flow) settle(ctx context.Context) (bool, error) {
	rec, err := f.d.S.LoadPostMerge(ctx)
	if err != nil || rec == nil || (rec.Phase != state.PhaseIntent && rec.Phase != state.PhaseUnknown) {
		return false, err
	}
	t := target{pr: rec.PR, issue: rec.Issue, reviewed: rec.ReviewedSHA, base: rec.VerifiedBase, method: ""}
	o, err := f.conclude(ctx, t, f.fromPull(ctx, t, true))
	if err != nil {
		return true, err
	}
	f.res.Reconciled = &Reconciled{PR: t.pr, Issue: t.issue, Result: o.phase}
	return true, f.report(ctx, t, o, true)
}

// conclude finishes a merge in the order the contract fixes: verify the base the merge landed on, freeze the Epic
// when it is not the verified one, then note the result, then record it. A merge is never requested before both are written.
func (f *flow) conclude(ctx context.Context, t target, o outcome) (outcome, error) {
	if o.phase == state.PhaseMerged {
		o = f.verifyBase(ctx, t, o)
	}
	if o.phase == state.PhaseMergedUnverifiedBase {
		if err := f.freezeUnverified(ctx, t, o); err != nil {
			return o, err
		}
	}
	key := fmt.Sprintf("merge-result:%d:%s:%s", t.pr, t.reviewed, o.phase)
	nr, err := f.d.S.PostNote(ctx, t.issue, key, MergeResultNote(t.pr, t.reviewed, t.base, t.method, o.phase, o.detail))
	if err != nil {
		return o, unrecorded(err)
	}
	f.res.Notes = append(f.res.Notes, nr)
	if _, err := f.d.S.RecordMergeResult(ctx, coord.MergeOutcome{PR: t.pr, ReviewedSHA: t.reviewed, Phase: o.phase, MergeSHA: o.mergeSHA}); err != nil {
		return o, unrecorded(err)
	}
	return o, nil
}

// unrecorded stops landing: a result that was not written leaves the record at intent, and the next pass settles it from the pull request.
func unrecorded(err error) error {
	return exitcode.Wrap(exitcode.Stop, err, "the merge result was not recorded, so every further merge is stopped")
}

// verifyBase checks that the merge commit's first parent is the verified base, which both merge methods give the base a merge landed on.
// Anything else means the base moved after the last read, so the merged combination was never reviewed.
// A parent that cannot be read counts the same, since it is not proof.
func (f *flow) verifyBase(ctx context.Context, t target, o outcome) outcome {
	parent, err := snapshot.ReadFirstParent(ctx, f.d.Client.Probe(), f.d.In.Repo, o.mergeSHA)
	if err == nil && parent == t.base {
		return o
	}
	if err != nil {
		parent = "unreadable"
	}
	o.phase = state.PhaseMergedUnverifiedBase
	o.detail = fmt.Sprintf("%s (first parent %s, verified_base %s)", o.mergeSHA, parent, t.base)
	return o
}

// freezeUnverified freezes the Epic so nothing else lands on an unverified default branch. It never reverts.
// A frozen Epic is the stop that succeeded, whether this pass froze it or it was frozen already.
func (f *flow) freezeUnverified(ctx context.Context, t target, o outcome) error {
	lr, err := f.d.S.Freeze(ctx, fmt.Sprintf("PR #%d merged on an unverified base: %s", t.pr, o.detail), "", "")
	f.res.Freeze = lr.Freeze
	if exitcode.CodeOf(err) == exitcode.Stop {
		return nil
	}
	return err
}

// report fills the result for a concluded merge and returns the exit the route calls for.
func (f *flow) report(ctx context.Context, t target, o outcome, reconciled bool) error {
	f.res.PR, f.res.ReviewedSHA, f.res.VerifiedBase, f.res.Method = t.pr, t.reviewed, t.base, t.method
	f.res.MergeSHA, f.res.Result, f.res.Reason = o.mergeSHA, o.phase, o.detail
	route := func(inline, settled string) string {
		if reconciled {
			return settled
		}
		return inline
	}
	switch o.phase {
	case state.PhaseMerged:
		f.res.Route, f.res.Next = route(RouteMerged, RouteReconciled), NextRescan
	case state.PhaseNotMerged:
		f.res.Route, f.res.Next = RouteReconciled, NextLand
	case state.PhaseMergedUnverifiedBase:
		f.res.Route, f.res.Next = route(RouteUnverifiedBase, RouteReconciled), NextStop
		return exitcode.New(exitcode.Stop, "PR #"+fmt.Sprint(t.pr)+" merged on an unverified base; the Epic is frozen and nothing else may land")
	case state.PhaseHeadMoved:
		f.res.Route, f.res.Next = RouteHeadMoved, NextReverify
		return exitcode.New(exitcode.Stale, fmt.Sprintf("the head of pull request #%d moved after review, so GitHub refused the merge; review #%d again", t.pr, t.issue))
	case state.PhaseRejected:
		f.res.Route, f.res.Next = RouteRejected, NextHuman
		return f.holdRejected(ctx, t, o)
	default:
		f.res.Route, f.res.Next = RouteUnknown, NextStop
		return exitcode.New(exitcode.Stop, fmt.Sprintf("whether pull request #%d merged is unknown, so landing stops and nothing is requested again", t.pr))
	}
	return nil
}

// holdRejected holds a pull request whose merge request the repository refused. The loop never bypasses a repository control.
func (f *flow) holdRejected(ctx context.Context, t target, o outcome) error {
	nr, err := f.d.S.PostNote(ctx, t.issue, fmt.Sprintf("merge-hold:%d:%s:%s", t.pr, t.reviewed, coord.DigestPlaceholder),
		MergeHoldNote(t.pr, t.reviewed, "マージ要求の拒否: "+o.detail))
	if err != nil {
		return err
	}
	f.res.Notes = append(f.res.Notes, nr)
	return nil
}
