package coord

import "github.com/maro114510/skills/oe/internal/state"

// RecordPublishIntent records, before the push, the pair about to be published.
// It needs an approval bound to exactly that pair, so nothing unreviewed is ever recorded for pushing.
// An earlier publish of any phase is replaced and its pull request kept, so a repaired head or a pair
// that went stale after a crash re-publishes over it.
type RecordPublishIntent struct {
	// SHA and Base are the approval's reviewed_sha and verified_base.
	SHA  string
	Base string
	// PrevSHA is the remote head when the intent is recorded, empty when the branch is not there.
	PrevSHA string
}

// Name implements Transition.
func (RecordPublishIntent) Name() string { return "record_publish_intent" }

func (t RecordPublishIntent) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	a := in.cur.Approval
	switch {
	case a == nil:
		return nil, refused("#%d has no approval, so nothing may be published", in.n)
	case t.SHA == "" || t.SHA != a.ReviewedSHA || t.Base != a.VerifiedBase:
		return nil, refused("#%d is approved at %s on %s, not %s on %s", in.n, a.ReviewedSHA, a.VerifiedBase, t.SHA, t.Base)
	}
	st := cloneIssue(in.cur)
	pr := 0
	if in.cur.Publish != nil {
		pr = in.cur.Publish.PR
	}
	st.Publish = &state.Publish{SHA: t.SHA, PrevSHA: t.PrevSHA, Base: t.Base, Branch: in.cur.Branch, PR: pr, Phase: PublishIntent}
	return st, nil
}

// RecordPublished moves a publish forward after the push: to pushed, then to linked once the
// pull request is known.
type RecordPublished struct {
	// PR is the pull request number, or 0 to record only that the push landed.
	PR int
}

// Name implements Transition.
func (RecordPublished) Name() string { return "record_published" }

func (t RecordPublished) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	p := in.cur.Publish
	switch {
	case p == nil || p.Phase == PublishLinked:
		return nil, refused("#%d has no publish in flight to record", in.n)
	case t.PR < 0:
		return nil, refused("a pull request number is not negative")
	}
	st := cloneIssue(in.cur)
	st.Publish.Phase = PublishPushed
	if t.PR > 0 {
		st.Publish.Phase, st.Publish.PR = PublishLinked, t.PR
	}
	return st, nil
}
