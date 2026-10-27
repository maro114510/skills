package coord

import (
	"context"
	"time"

	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

// MergeIntent names the merge the loop is about to request, contract §4.3.
type MergeIntent struct {
	PR           int
	Issue        int
	ReviewedSHA  string
	VerifiedBase string
}

// MergeOutcome is how a requested merge ended, or what reconciling it from the pull request found.
type MergeOutcome struct {
	PR          int
	ReviewedSHA string
	// Phase is one of the result phases of contract §4.3, never intent.
	Phase string
	// MergeSHA is the merge commit, and only a merged phase carries one.
	MergeSHA string
}

func decodePostMerge() protocol.State { return new(state.PostMerge) }

// pending reports whether a record still needs its outcome reconciled from the pull request.
func pending(phase string) bool { return phase == state.PhaseIntent || phase == state.PhaseUnknown }

// carriesMerge reports whether a phase has a merge commit to name.
func carriesMerge(phase string) bool {
	return phase == state.PhaseMerged || phase == state.PhaseMergedUnverifiedBase
}

// ValidatePostMerge rejects a record no transition may write: a merge without its pair, an unknown phase,
// or a merge commit on a phase that has none, or a merged phase without one.
func ValidatePostMerge(pm *state.PostMerge) error {
	switch {
	case pm.PR <= 0 || pm.Issue <= 0:
		return refused("post-merge record needs the pull request and the Issue it merges")
	case pm.ReviewedSHA == "" || pm.VerifiedBase == "":
		return refused("post-merge record needs the reviewed head and the verified base")
	case pm.RequestedAt == "":
		return refused("post-merge record needs the time of the request")
	}
	switch pm.Phase {
	case state.PhaseIntent, state.PhaseMerged, state.PhaseMergedUnverifiedBase, state.PhaseHeadMoved,
		state.PhaseRejected, state.PhaseUnknown, state.PhaseNotMerged:
	default:
		return refused("post-merge record has the unknown phase %q", pm.Phase)
	}
	if carriesMerge(pm.Phase) != (pm.MergeSHA != "") {
		return refused("post-merge phase %q and merge commit %q do not belong together", pm.Phase, pm.MergeSHA)
	}
	return nil
}

type postMergeRead struct {
	pm   *state.PostMerge
	prev stored
}

func (s *Session) readPostMerge(ctx context.Context) (postMergeRead, error) {
	r, err := s.read(ctx, s.in.Epic)
	if err != nil {
		return postMergeRead{}, err
	}
	var pm state.PostMerge
	id, err := r.decode(state.KeyPostMerge, state.EntityPostMerge, &pm)
	if err != nil {
		return postMergeRead{}, err
	}
	out := postMergeRead{pm: nil, prev: stored{id: id, revision: pm.Revision}}
	if id != 0 {
		out.pm = &pm
	}
	return out, nil
}

// LoadPostMerge reads the post-merge record, or nil when the loop recorded no merge.
func (s *Session) LoadPostMerge(ctx context.Context) (*state.PostMerge, error) {
	pr, err := s.readPostMerge(ctx)
	return pr.pm, err
}

func (s *Session) savePostMerge(ctx context.Context, prev stored, pm *state.PostMerge) error {
	if err := ValidatePostMerge(pm); err != nil {
		return err
	}
	return s.saveState(ctx, s.in.Epic, prev, pm, decodePostMerge, confirmLanded)
}

// RecordMergeIntent writes the record before the merge request, so a session that dies right after the merge still finds it.
// A record still at intent or unknown is reconciled from its pull request first, §5.1, so it is never replaced.
func (s *Session) RecordMergeIntent(ctx context.Context, in MergeIntent) (state.PostMerge, error) {
	now, err := s.now(ctx)
	if err != nil {
		return state.PostMerge{}, err
	}
	next := state.PostMerge{
		Envelope: protocol.Envelope{ProtocolVersion: protocol.Version, Entity: state.EntityPostMerge, Key: state.KeyPostMerge, Revision: 0, UpdatedBy: ""},
		PR:       in.PR, Issue: in.Issue, ReviewedSHA: in.ReviewedSHA, VerifiedBase: in.VerifiedBase,
		Phase: state.PhaseIntent, MergeSHA: "", RequestedAt: now.UTC().Format(time.RFC3339),
	}
	if err := ValidatePostMerge(&next); err != nil {
		return state.PostMerge{}, err
	}
	cur, err := s.readPostMerge(ctx)
	if err != nil {
		return state.PostMerge{}, err
	}
	if cur.pm != nil && pending(cur.pm.Phase) {
		return state.PostMerge{}, refused("the merge of #%d is still %s; reconcile it from its pull request before recording another merge", cur.pm.PR, cur.pm.Phase)
	}
	if err := s.savePostMerge(ctx, cur.prev, &next); err != nil {
		return state.PostMerge{}, err
	}
	return next, nil
}

// RecordMergeResult records how the merge ended, resolving an intent or an unknown outcome.
// A result already recorded for the same merge is done and writes nothing.
func (s *Session) RecordMergeResult(ctx context.Context, out MergeOutcome) (state.PostMerge, error) {
	cur, err := s.readPostMerge(ctx)
	if err != nil {
		return state.PostMerge{}, err
	}
	pm := cur.pm
	switch {
	case pm == nil:
		return state.PostMerge{}, refused("no merge was recorded, so there is no outcome to record for #%d", out.PR)
	case pm.PR != out.PR || pm.ReviewedSHA != out.ReviewedSHA:
		return state.PostMerge{}, refused("the recorded merge is #%d at %s, not #%d at %s", pm.PR, pm.ReviewedSHA, out.PR, out.ReviewedSHA)
	case out.Phase == state.PhaseIntent:
		return state.PostMerge{}, refused("intent is a request, not a result")
	case pm.Phase == out.Phase && pm.MergeSHA == out.MergeSHA:
		return *pm, nil
	case !pending(pm.Phase):
		return state.PostMerge{}, refused("the merge of #%d is already recorded as %s; a result resolves only an intent or an unknown outcome", pm.PR, pm.Phase)
	}
	next := *pm
	next.Phase, next.MergeSHA = out.Phase, out.MergeSHA
	if err := s.savePostMerge(ctx, cur.prev, &next); err != nil {
		return state.PostMerge{}, err
	}
	return next, nil
}
