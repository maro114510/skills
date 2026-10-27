package cmd_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/state"
)

// pending stores the record a session left when it died between the intent and the result, for pull request 12.
func (f *landFlow) pending(t *testing.T, phase string) {
	t.Helper()
	var pm state.PostMerge
	pm.Entity, pm.Key = state.EntityPostMerge, state.KeyPostMerge
	pm.PR, pm.Issue, pm.ReviewedSHA, pm.VerifiedBase = landPR, 7, landReviewed, landBase
	pm.Phase, pm.MergeSHA, pm.RequestedAt = phase, "", "2026-10-18T23:00:00Z"
	f.w.put(t, 277, &pm)
}

// TestLandMergeReconcilesAnUnresolvedRecordFromThePullRequestFirst guards EC-03 and PH-02: a record still at intent or unknown
// is settled from the pull request before anything else, and settling it ends the pass without a request.
func TestLandMergeReconcilesAnUnresolvedRecordFromThePullRequestFirst(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		from   string
		pull   func(string) string
		parent string
		code   int
		result string
		merge  string
		frozen bool
	}{
		"an intent whose pull request merged on the verified base": {
			state.PhaseIntent, func(string) string { return mergedPullBody(landPR, landMerge, "SUCCESS") }, landBase, 0, "merged", landMerge, false,
		},
		"an intent whose pull request merged on another base": {
			state.PhaseIntent, func(string) string { return mergedPullBody(landPR, landMerge, "SUCCESS") }, "moved01", 4, "merged-unverified-base", landMerge, true,
		},
		"an intent whose pull request never merged": {
			state.PhaseIntent, func(string) string { return openPullBody(landPR) }, landBase, 0, "not-merged", "", false,
		},
		"an unknown outcome that turns out merged": {
			state.PhaseUnknown, func(string) string { return mergedPullBody(landPR, landMerge, "SUCCESS") }, landBase, 0, "merged", landMerge, false,
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			f.pending(t, tc.from)
			f.pulls = tc.pull
			f.w.r.On(ghfake.Commit, func(map[string]string) string { return ghfake.CommitReply(landMerge, tc.parent, landReviewed) })
			r := f.merge()
			out := parseLanded(t, r)
			if r.code != tc.code || out.Route != "RECONCILED" || out.Result != tc.result || out.MergeSHA != tc.merge {
				t.Errorf("exit %d, stdout %q; want exit %d, RECONCILED as %s", r.code, r.stdout, tc.code, tc.result)
			}
			f.wantNoRequest(t)
			if pm := f.record(); pm == nil || pm.Phase != tc.result || pm.MergeSHA != tc.merge {
				t.Errorf("record = %+v, want %s", pm, tc.result)
			}
			if f.notes(7, fmt.Sprintf("merge-result:%d:%s:%s -->", landPR, landReviewed, tc.result)) != 1 {
				t.Errorf("want one merge-result note for %s", tc.result)
			}
			if l := f.ledger(t); tc.frozen != (l.Freeze != nil && !l.Freeze.Released) {
				t.Errorf("ledger freeze = %+v, want frozen = %v", l.Freeze, tc.frozen)
			}
		})
	}
}

// TestLandMergeRequestsAgainOnlyAfterANotMergedRecord: once the pull request is known not to have merged, the next pass
// merges it, and that is a new attempt on a settled record, not a blind retry of an uncertain one.
func TestLandMergeRequestsAgainOnlyAfterANotMergedRecord(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.pending(t, state.PhaseIntent)
	f.pulls = func(string) string { return openPullBody(landPR) }
	first := f.merge()
	if first.code != 0 || f.putCount() != 0 {
		t.Fatalf("first pass: exit %d, requests %d; want it to settle the record and send nothing", first.code, f.putCount())
	}
	f.pulls = func(string) string { return mergedPullBody(landPR, landMerge, "SUCCESS") }
	second := f.merge()
	if second.code != 0 || f.putCount() != 1 {
		t.Errorf("second pass: exit %d, requests %d; want one merge", second.code, f.putCount())
	}
}

// TestLandMergeStopsWhileTheOutcomeStaysUnknown guards MQ-07: an unreadable pull request leaves the record unknown,
// writes nothing more, and stops landing instead of retrying.
func TestLandMergeStopsWhileTheOutcomeStaysUnknown(t *testing.T) {
	t.Parallel()

	for _, from := range []string{state.PhaseIntent, state.PhaseUnknown} {
		t.Run(from, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			f.pending(t, from)
			f.pulls = func(string) string { return unreadableBody }
			r := f.merge()
			out := parseLanded(t, r)
			if r.code != 4 || out.Route != "UNKNOWN" || out.Result != "unknown" {
				t.Errorf("exit %d, stdout %q; want exit 4, UNKNOWN", r.code, r.stdout)
			}
			f.wantNoRequest(t)
			if pm := f.record(); pm == nil || pm.Phase != state.PhaseUnknown {
				t.Errorf("record = %+v, want unknown", pm)
			}
		})
	}
}

// TestLandMergeResultIsNotedOncePerPullRequestHeadAndResult guards LC-09 and TP-10: a session that died after the note
// and before the record posts no second note, and finishes the record.
func TestLandMergeResultIsNotedOncePerPullRequestHeadAndResult(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.pending(t, state.PhaseIntent)
	f.w.store.Add(7, "loop", "OWNER", fmt.Sprintf("<!-- oe:v2 note merge-result:%d:%s:merged -->\nearlier note", landPR, landReviewed))
	r := f.merge()
	if r.code != 0 {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	if n := f.notes(7, fmt.Sprintf("merge-result:%d:%s:merged -->", landPR, landReviewed)); n != 1 {
		t.Errorf("merge-result notes = %d, want the earlier one only", n)
	}
	if pm := f.record(); pm == nil || pm.Phase != state.PhaseMerged {
		t.Errorf("record = %+v, want merged", pm)
	}
}

// TestLandMergeStopsEveryFurtherMergeWhenTheResultCannotBeRecorded guards LD-05 and TP-11: a result whose note or record
// cannot be written is reported as a stop, the next pass settles it from the pull request, and nothing merges meanwhile.
func TestLandMergeStopsEveryFurtherMergeWhenTheResultCannotBeRecorded(t *testing.T) {
	t.Parallel()

	for name, failing := range map[string]string{
		"the result note":   "<!-- oe:v2 note merge-result:",
		"the result record": `"phase": "merged"`,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			f.w.store.OnWrite(func(_ *ghfake.Store, w ghfake.Write) (int, bool) {
				if strings.Contains(w.Body, failing) {
					return 1, false
				}
				return 0, true
			})
			r := f.merge()
			if r.code != 4 {
				t.Errorf("exit %d, stdout %q; want exit 4, stop landing", r.code, r.stdout)
			}
			if f.putCount() != 1 {
				t.Errorf("merge requests = %d, want the one that merged", f.putCount())
			}
			// The next pass finds the record at intent and settles it instead of merging again.
			f.w.store.OnWrite(nil)
			again := f.merge()
			if again.code != 0 || f.putCount() != 1 {
				t.Errorf("next pass: exit %d, requests %d; want it to reconcile and send nothing", again.code, f.putCount())
			}
			if pm := f.record(); pm == nil || pm.Phase != state.PhaseMerged {
				t.Errorf("record = %+v, want merged once the next pass settled it", pm)
			}
		})
	}
}

// TestLandMergeNeverWritesWhenTheRecordIsUnreadable: a protocol error in what the loop wrote stops it before any request.
func TestLandMergeNeverWritesWhenTheRecordIsUnreadable(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.w.store.Add(277, "loop", "OWNER", "<!-- orchestrate-epic:post-merge -->\nlegacy")
	r := f.merge()
	if r.code != 6 {
		t.Errorf("exit %d, stdout %q; want 6", r.code, r.stdout)
	}
	f.wantNoRequest(t)
}
