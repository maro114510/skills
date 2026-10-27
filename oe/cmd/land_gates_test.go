package cmd_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

// putRecord stores the post-merge record an earlier merge of pull request 11 left.
func (f *landFlow) putRecord(t *testing.T, phase, merge string) {
	t.Helper()
	var pm state.PostMerge
	pm.Entity, pm.Key = state.EntityPostMerge, state.KeyPostMerge
	pm.PR, pm.Issue, pm.ReviewedSHA, pm.VerifiedBase = 11, 6, "oldrev1", "oldbase"
	pm.Phase, pm.MergeSHA, pm.RequestedAt = phase, merge, "2026-10-18T23:00:00Z"
	f.w.put(t, 277, &pm)
}

// TestLandMergeWaitsForTheLastMergesDefaultBranchChecks guards GL-10 and PH-01: nothing merges until every check on the previous
// merge commit passed, a failure freezes the Epic with the merge it names, and a health that cannot be read stops landing.
func TestLandMergeWaitsForTheLastMergesDefaultBranchChecks(t *testing.T) {
	t.Parallel()

	pending := `{"data":{"repository":{"pullRequest":{"number":11,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",` +
		`"mergeCommit":{"oid":"old01","statusCheckRollup":{"state":"PENDING","contexts":{"totalCount":1,"nodes":[` +
		`{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS"}]}}}}}}}`
	tests := map[string]struct {
		body   string
		code   int
		frozen bool
	}{
		"a check is still pending":  {pending, 5, false},
		"a check failed":            {mergedPullBody(11, "old01", "FAILURE"), 4, true},
		"the checks cannot be read": {unreadableBody, 4, false},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			f.putRecord(t, state.PhaseMerged, "old01")
			f.pulls = func(string) string { return tc.body }
			r := f.merge()
			if r.code != tc.code {
				t.Errorf("exit %d, stdout %q; want exit %d", r.code, r.stdout, tc.code)
			}
			f.wantNoRequest(t)
			l := f.ledger(t)
			if tc.frozen != (l.Freeze != nil && !l.Freeze.Released) {
				t.Errorf("ledger freeze = %+v, want frozen = %v", l.Freeze, tc.frozen)
			}
			if tc.frozen && l.Freeze != nil && (l.Freeze.MergeSHA != "old01" || l.Freeze.Health != "FAIL") {
				t.Errorf("freeze = %+v, want it to name merge old01 and status FAIL, so a release is not frozen again by the same result", l.Freeze)
			}
		})
	}
}

// TestLandMergeProceedsOnceThePreviousMergePassed: a merge whose default-branch checks passed no longer holds the next one.
func TestLandMergeProceedsOnceThePreviousMergePassed(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.putRecord(t, state.PhaseMerged, "old01")
	f.pulls = func(num string) string {
		if num == "11" {
			return mergedPullBody(11, "old01", "SUCCESS")
		}
		return mergedPullBody(landPR, landMerge, "SUCCESS")
	}
	r := f.merge()
	if r.code != 0 || f.putCount() != 1 {
		t.Errorf("exit %d, stdout %q, requests %d; want the merge to land", r.code, r.stdout, f.putCount())
	}
	if pm := f.record(); pm == nil || pm.PR != landPR || pm.Phase != state.PhaseMerged {
		t.Errorf("record = %+v, want it to name the new merge", pm)
	}
}

// TestLandMergeNeedsTheShippedPairAsItsApprovalAndPullRequest guards MR-02 and BV-08: only the approved head, shipped as the open
// pull request the state names, is merged, and a head that moved after review routes to re-verification.
func TestLandMergeNeedsTheShippedPairAsItsApprovalAndPullRequest(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		setup func(f *landFlow)
		code  int
	}{
		"the pull request head moved after review": {func(f *landFlow) {
			f.w.r.On(ghfake.Readiness, func(map[string]string) string { return pullBody(readyPull("somebodys-push")) })
		}, 3},
		"the default branch moved since verification": {func(f *landFlow) { f.base = func(int) string { return "moved01" } }, 3},
		"the default branch moves before the request": {func(f *landFlow) {
			f.base = func(n int) string {
				if n == 1 {
					return landBase
				}
				return "moved01"
			}
		}, 3},
		"the Issue has no approval": {func(f *landFlow) {
			st := f.issue()
			st.Approval = nil
			f.replaceIssue(st)
		}, 8},
		"the pair shipped is not the pair approved": {func(f *landFlow) {
			st := f.issue()
			st.Publish.SHA = "olderhead"
			f.replaceIssue(st)
		}, 8},
		"the shipped pull request is not linked yet": {func(f *landFlow) {
			st := f.issue()
			st.Publish.Phase, st.Publish.PR = "pushed", 0
			f.replaceIssue(st)
		}, 8},
		"the Issue is parked": {func(f *landFlow) {
			st := f.issue()
			st.Approval, st.UnresolvedBlockers = nil, []string{"cap"}
			f.replaceIssue(st)
		}, 8},
		"another pull request is the one open": {func(f *landFlow) {
			f.w.r.On(ghfake.PullsByHead, func(map[string]string) string {
				return ghfake.PullPage("["+ghfake.PullNodeOnBase(99, "OPEN", "feat/issue-7", "main", "Closes #7", "2026-10-05T00:00:00Z", false)+"]", false, "")
			})
		}, 8},
		"the pull request targets another branch": {func(f *landFlow) {
			f.w.r.On(ghfake.PullsByHead, func(map[string]string) string {
				return ghfake.PullPage("["+ghfake.PullNodeOnBase(landPR, "OPEN", "feat/issue-7", "release", "Closes #7", "2026-10-05T00:00:00Z", false)+"]", false, "")
			})
		}, 8},
		"the pull request is already merged": {func(f *landFlow) {
			f.w.r.On(ghfake.PullsByHead, func(map[string]string) string {
				return ghfake.PullPage("["+ghfake.PullNodeOnBase(landPR, "MERGED", "feat/issue-7", "main", "Closes #7", "2026-10-05T00:00:00Z", true)+"]", false, "")
			})
		}, 8},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			tc.setup(f)
			r := f.merge()
			if r.code != tc.code {
				t.Errorf("exit %d, stdout %q; want %d", r.code, r.stdout, tc.code)
			}
			f.wantNoRequest(t)
			if f.record() != nil {
				t.Errorf("a post-merge record exists: %+v", f.record())
			}
		})
	}
}

// replaceIssue overwrites Issue 7's state comment, as the state the test needs.
func (f *landFlow) replaceIssue(st *state.Issue) {
	for _, c := range f.w.store.Comments(7) {
		if strings.HasPrefix(c.Body, "<!-- oe:v2 state issue:7 -->") {
			f.w.store.Delete(c.ID)
		}
	}
	st.Revision, st.UpdatedBy = 1, "earlier"
	body, err := protocol.EncodeState(st)
	if err != nil {
		panic(err)
	}
	f.w.store.Add(7, "loop", "OWNER", body)
}

// TestLandMergeHoldsWhatTheRepositoryHoldsAndNeverBypassesIt guards GL-09, MA-04, and LD-04: a pull request that is not ready is
// not merged, a wait is a wait, a repairable block goes to repair, and one a person must lift gets a merge hold once per head and reason.
func TestLandMergeHoldsWhatTheRepositoryHoldsAndNeverBypassesIt(t *testing.T) {
	t.Parallel()

	failing := func() pullOpts {
		o := readyPull(landReviewed)
		o.contexts = `{"totalCount":1,"nodes":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE"}]}`
		return o
	}
	pendingChecks := func() pullOpts {
		o := readyPull(landReviewed)
		o.contexts = `{"totalCount":1,"nodes":[{"__typename":"CheckRun","name":"build","status":"IN_PROGRESS"}]}`
		return o
	}
	draft := func() pullOpts { o := readyPull(landReviewed); o.draft = true; return o }
	protectedBase := func() pullOpts { o := readyPull(landReviewed); o.mergeState = "BLOCKED"; return o }
	tests := map[string]struct {
		pull  pullOpts
		code  int
		route string
		next  string
		hold  int
	}{
		"a check is pending":             {pendingChecks(), 5, "", "", 0},
		"a check failed":                 {failing(), 0, "HELD", "repair", 0},
		"the pull request is a draft":    {draft(), 0, "HELD", "human", 1},
		"the repository's rules hold it": {protectedBase(), 0, "HELD", "human", 1},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			f.w.r.On(ghfake.Readiness, func(map[string]string) string { return pullBody(tc.pull) })
			r := f.merge()
			if r.code != tc.code {
				t.Fatalf("exit %d, stdout %q; want %d", r.code, r.stdout, tc.code)
			}
			if tc.route != "" {
				out := parseLanded(t, r)
				if out.Route != tc.route || out.Next != tc.next {
					t.Errorf("stdout %q; want %s with next %s", r.stdout, tc.route, tc.next)
				}
			}
			f.wantNoRequest(t)
			if f.record() != nil || f.notes("merge-hold:") != tc.hold {
				t.Errorf("record %+v, merge holds %d; want no record and %d holds", f.record(), f.notes("merge-hold:"), tc.hold)
			}
			// Asking again changes nothing: the hold is posted once per head and reason.
			f.merge()
			if got := f.notes("merge-hold:"); got != tc.hold {
				t.Errorf("merge holds after a second pass = %d, want %d", got, tc.hold)
			}
		})
	}
}

// TestLandMergeHoldIsPostedAgainForANewReasonOnTheSameHead guards LC-05: the key holds the reason, so a new one is news.
func TestLandMergeHoldIsPostedAgainForANewReasonOnTheSameHead(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	draft := readyPull(landReviewed)
	draft.draft = true
	f.w.r.On(ghfake.Readiness, func(map[string]string) string { return pullBody(draft) })
	f.merge()
	blocked := readyPull(landReviewed)
	blocked.mergeState = "BLOCKED"
	f.w.r.On(ghfake.Readiness, func(map[string]string) string { return pullBody(blocked) })
	f.merge()
	if got := f.notes(fmt.Sprintf("merge-hold:%d:%s:", landPR, landReviewed)); got != 2 {
		t.Errorf("merge holds = %d, want one per reason", got)
	}
}

// TestLandMergeHoldsOnAnUnreadableReadiness guards MA-03 in spirit: a signal that cannot be read is never permission.
func TestLandMergeHoldsOnAnUnreadableReadiness(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.w.r.On(ghfake.Readiness, func(map[string]string) string { return `{"data":{"repository":{"pullRequest":null}}}` })
	r := f.merge()
	if r.code != 1 {
		t.Errorf("exit %d, stdout %q; want 1", r.code, r.stdout)
	}
	f.wantNoRequest(t)
}

// TestLandMergeNeverRequestsWhenTheIntentCannotBeRecorded guards LC-07: a failed write of the record merges nothing.
func TestLandMergeNeverRequestsWhenTheIntentCannotBeRecorded(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.w.store.OnWrite(func(_ *ghfake.Store, w ghfake.Write) (int, bool) {
		if strings.Contains(w.Body, "<!-- oe:v2 state post-merge -->") {
			return 1, false
		}
		return 0, true
	})
	r := f.merge()
	if r.code == 0 {
		t.Errorf("exit 0, stdout %q; want a failure", r.stdout)
	}
	f.wantNoRequest(t)
}

// TestLandMergeReadsTheGrantAgainRightBeforeTheRequest guards MA-02: a revoke that lands while the pull request is being
// classified stops the merge, since the grant read at the start of the pass is not permission for the request at its end.
func TestLandMergeReadsTheGrantAgainRightBeforeTheRequest(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.w.r.On(ghfake.Readiness, func(map[string]string) string {
		f.w.store.Add(277, "alice", "MEMBER", "epic-revoke-auto-merge")
		return pullBody(readyPull(landReviewed))
	})
	r := f.merge()
	if r.code != 8 {
		t.Errorf("exit %d, stdout %q; want 8, the grant withdrawn", r.code, r.stdout)
	}
	f.wantNoRequest(t)
	if f.record() != nil {
		t.Errorf("a post-merge record exists: %+v", f.record())
	}
}

// TestLandMergeChecksTheFreezeAgainRightBeforeTheRequest guards FZ-01: a freeze posted while the pull request is being
// classified, by this session or another, stops every merge not yet requested.
func TestLandMergeChecksTheFreezeAgainRightBeforeTheRequest(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.w.r.On(ghfake.Readiness, func(map[string]string) string {
		f.freezeEpic(t)
		return pullBody(readyPull(landReviewed))
	})
	r := f.merge()
	if r.code != 4 {
		t.Errorf("exit %d, stdout %q; want 4, the Epic frozen", r.code, r.stdout)
	}
	f.wantNoRequest(t)
	if f.record() != nil {
		t.Errorf("a post-merge record exists: %+v", f.record())
	}
}
