package coord_test

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/state"
)

const (
	reviewed = "rev0001"
	verified = "base001"
	mergeSHA = "merge01"
)

// record is a post-merge record an earlier run left, for pull request 12 of Issue 7.
func record(phase, merge string) *state.PostMerge {
	var pm state.PostMerge
	pm.Entity, pm.Key, pm.Revision, pm.UpdatedBy = state.EntityPostMerge, state.KeyPostMerge, 1, "earlier"
	pm.PR, pm.Issue, pm.ReviewedSHA, pm.VerifiedBase = 12, child, reviewed, verified
	pm.Phase, pm.MergeSHA, pm.RequestedAt = phase, merge, "2026-10-18T23:00:00Z"
	return &pm
}

func intentFor(pr int) coord.MergeIntent {
	return coord.MergeIntent{PR: pr, Issue: child, ReviewedSHA: reviewed, VerifiedBase: verified}
}

func (w *world) postMerge(t *testing.T) (state.PostMerge, bool) {
	t.Helper()
	var pm state.PostMerge
	found := w.stateOf(t, epic, state.KeyPostMerge, &pm)
	return pm, found
}

// TestMergeIntentIsWrittenAsTheEpicsPostMergeRecord: health judges the merge this record names,
// so the record must exist, with GitHub's clock, before the request that could merge it.
func TestMergeIntentIsWrittenAsTheEpicsPostMergeRecord(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	got, err := w.session(token).RecordMergeIntent(ctx(), intentFor(12))
	ok(t, err)
	pm, found := w.postMerge(t)
	if !found || pm.PR != 12 || pm.Issue != child || pm.ReviewedSHA != reviewed || pm.VerifiedBase != verified ||
		pm.Phase != state.PhaseIntent || pm.MergeSHA != "" || pm.RequestedAt != "2026-10-19T00:05:00Z" || pm.Revision != 1 {
		t.Errorf("record = %+v, found %v", pm, found)
	}
	if got.Phase != state.PhaseIntent || got.PR != 12 {
		t.Errorf("returned %+v, want the intent that was written", got)
	}
	loaded, err := w.session(token).LoadPostMerge(ctx())
	if err != nil || loaded == nil || loaded.PR != 12 {
		t.Errorf("LoadPostMerge() = %+v, %v; want the record", loaded, err)
	}
}

func TestLoadPostMergeIsNilBeforeAnyMergeWasRecorded(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	loaded, err := w.session(w.acquire(t)).LoadPostMerge(ctx())
	if err != nil || loaded != nil {
		t.Errorf("LoadPostMerge() = %+v, %v; want nil, nil", loaded, err)
	}
}

// TestMergeIntentIsRefusedWhileTheLastRecordIsUnresolved guards §5.1 item 11: an intent or an unknown outcome
// is reconciled from the pull request first, so a second request is never recorded on top of it.
func TestMergeIntentIsRefusedWhileTheLastRecordIsUnresolved(t *testing.T) {
	t.Parallel()

	for _, phase := range []string{state.PhaseIntent, state.PhaseUnknown} {
		t.Run(phase, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			w.put(t, epic, record(phase, ""))
			token := w.acquire(t)
			before := w.writes()
			_, err := w.session(token).RecordMergeIntent(ctx(), intentFor(13))
			wantCode(t, err, exitcode.Refused)
			pm, _ := w.postMerge(t)
			if w.writes() != before || pm.PR != 12 || pm.Phase != phase {
				t.Errorf("writes %d -> %d, record %+v; want nothing written", before, w.writes(), pm)
			}
		})
	}
}

// TestMergeIntentReplacesAResolvedRecord: the record names only the latest merge, so a resolved one gives way to the next.
func TestMergeIntentReplacesAResolvedRecord(t *testing.T) {
	t.Parallel()

	resolved := map[string]string{
		state.PhaseMerged: mergeSHA, state.PhaseMergedUnverifiedBase: mergeSHA,
		state.PhaseHeadMoved: "", state.PhaseRejected: "", state.PhaseNotMerged: "",
	}
	for phase, merge := range resolved {
		t.Run(phase, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			w.put(t, epic, record(phase, merge))
			token := w.acquire(t)
			_, err := w.session(token).RecordMergeIntent(ctx(), intentFor(13))
			ok(t, err)
			pm, _ := w.postMerge(t)
			if pm.PR != 13 || pm.Phase != state.PhaseIntent || pm.MergeSHA != "" || pm.Revision != 2 {
				t.Errorf("record = %+v, want the new intent at revision 2", pm)
			}
		})
	}
}

func TestMergeIntentWithoutItsPairIsRefused(t *testing.T) {
	t.Parallel()

	for name, in := range map[string]coord.MergeIntent{
		"no pull request":  {PR: 0, Issue: child, ReviewedSHA: reviewed, VerifiedBase: verified},
		"no issue":         {PR: 12, Issue: 0, ReviewedSHA: reviewed, VerifiedBase: verified},
		"no reviewed sha":  {PR: 12, Issue: child, ReviewedSHA: "", VerifiedBase: verified},
		"no verified base": {PR: 12, Issue: child, ReviewedSHA: reviewed, VerifiedBase: ""},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			token := w.acquire(t)
			before := w.writes()
			_, err := w.session(token).RecordMergeIntent(ctx(), in)
			wantCode(t, err, exitcode.Refused)
			if w.writes() != before {
				t.Errorf("writes %d -> %d, want none", before, w.writes())
			}
		})
	}
}

// TestMergeResultResolvesAnIntentOrAnUnknownOutcome: reconciling from the pull request turns a pending record into its result,
// and only a merged one keeps the merge commit.
func TestMergeResultResolvesAnIntentOrAnUnknownOutcome(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name, from, phase, merge string
	}{
		{"an intent that merged", state.PhaseIntent, state.PhaseMerged, mergeSHA},
		{"an intent that merged on a moved base", state.PhaseIntent, state.PhaseMergedUnverifiedBase, mergeSHA},
		{"an intent whose head moved", state.PhaseIntent, state.PhaseHeadMoved, ""},
		{"an intent the repository rejected", state.PhaseIntent, state.PhaseRejected, ""},
		{"an intent that never merged", state.PhaseIntent, state.PhaseNotMerged, ""},
		{"an intent whose outcome stays unknown", state.PhaseIntent, state.PhaseUnknown, ""},
		{"an unknown outcome found merged", state.PhaseUnknown, state.PhaseMerged, mergeSHA},
		{"an unknown outcome found not merged", state.PhaseUnknown, state.PhaseNotMerged, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			w.put(t, epic, record(tc.from, ""))
			token := w.acquire(t)
			_, err := w.session(token).RecordMergeResult(ctx(), coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: tc.phase, MergeSHA: tc.merge})
			ok(t, err)
			pm, _ := w.postMerge(t)
			if pm.Phase != tc.phase || pm.MergeSHA != tc.merge || pm.PR != 12 || pm.ReviewedSHA != reviewed || pm.VerifiedBase != verified || pm.Revision != 2 {
				t.Errorf("record = %+v, want %s with merge %q at revision 2", pm, tc.phase, tc.merge)
			}
		})
	}
}

// TestMergeResultNamesTheRecordedMergeOrIsRefused: a result for another pull request, a pair nobody requested,
// or an Epic that recorded no intent resolves nothing.
func TestMergeResultNamesTheRecordedMergeOrIsRefused(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		existing *state.PostMerge
		out      coord.MergeOutcome
	}{
		"no record at all":                 {nil, coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: state.PhaseMerged, MergeSHA: mergeSHA}},
		"another pull request":             {record(state.PhaseIntent, ""), coord.MergeOutcome{PR: 13, ReviewedSHA: reviewed, Phase: state.PhaseMerged, MergeSHA: mergeSHA}},
		"another reviewed sha":             {record(state.PhaseIntent, ""), coord.MergeOutcome{PR: 12, ReviewedSHA: "other", Phase: state.PhaseMerged, MergeSHA: mergeSHA}},
		"a merged result without a commit": {record(state.PhaseIntent, ""), coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: state.PhaseMerged, MergeSHA: ""}},
		"a rejected result with a commit":  {record(state.PhaseIntent, ""), coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: state.PhaseRejected, MergeSHA: mergeSHA}},
		"intent as a result":               {record(state.PhaseIntent, ""), coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: state.PhaseIntent, MergeSHA: ""}},
		"a phase nobody defined":           {record(state.PhaseIntent, ""), coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: "landed", MergeSHA: ""}},
		"a record already resolved otherwise": {
			record(state.PhaseRejected, ""), coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: state.PhaseMerged, MergeSHA: mergeSHA},
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			if tc.existing != nil {
				w.put(t, epic, tc.existing)
			}
			token := w.acquire(t)
			before := w.writes()
			_, err := w.session(token).RecordMergeResult(ctx(), tc.out)
			wantCode(t, err, exitcode.Refused)
			if w.writes() != before {
				t.Errorf("writes %d -> %d, want none", before, w.writes())
			}
		})
	}
}

// TestMergeResultRecordedTwiceIsDoneOnce: a session that died after the record and resumes finds its result and writes nothing more.
func TestMergeResultRecordedTwiceIsDoneOnce(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, record(state.PhaseMerged, mergeSHA))
	token := w.acquire(t)
	before := w.writes()
	got, err := w.session(token).RecordMergeResult(ctx(), coord.MergeOutcome{PR: 12, ReviewedSHA: reviewed, Phase: state.PhaseMerged, MergeSHA: mergeSHA})
	ok(t, err)
	if w.writes() != before || got.Phase != state.PhaseMerged || got.Revision != 1 {
		t.Errorf("writes %d -> %d, got %+v; want the existing record and no write", before, w.writes(), got)
	}
}

// TestMergeIntentWhoseWriteLandedButFailedCountsAsRecorded: §8 takes a state write that may have landed as landed,
// since the merge request that follows needs the record to exist.
func TestMergeIntentWhoseWriteLandedButFailedCountsAsRecorded(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.store.OnWrite(func(_ *ghfake.Store, wr ghfake.Write) (int, bool) {
		if wr.Method == "POST" && wr.Issue == epic {
			return 1, true
		}
		return 0, true
	})
	_, err := w.session(token).RecordMergeIntent(ctx(), intentFor(12))
	ok(t, err)
	if pm, found := w.postMerge(t); !found || pm.Phase != state.PhaseIntent {
		t.Errorf("record = %+v, found %v; want the intent that landed", pm, found)
	}
}

// TestMergeRecordsNeedTheLease: a foreign or missing lease writes nothing, like every other state write.
func TestMergeRecordsNeedTheLease(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.acquire(t)
	before := w.writes()
	_, err := w.session("not-the-holder").RecordMergeIntent(ctx(), intentFor(12))
	wantCode(t, err, exitcode.Coordination)
	if w.writes() != before {
		t.Errorf("writes %d -> %d, want none", before, w.writes())
	}
}
