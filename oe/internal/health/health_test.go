package health_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
	"github.com/maro114510/skills/oe/internal/testfx"
)

// The cases below are the cases of the earlier test-base-health.bats, over the same merged
// pull request. The Epic's comments of those cases are now typed inputs: the post-merge record
// and the freezes the ledger holds.
const mergedPull = `{
  "number":7,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",
  "mergeCommit":{"oid":"m111","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":2,"nodes":[
    {"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T00:00:10Z","checkSuite":{"databaseId":1}},
    {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS","createdAt":"2026-10-19T00:00:10Z"}]}}}}`

const (
	failedRun  = `{"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-19T00:00:10Z","checkSuite":{"databaseId":1}}`
	pendingRun = `{"__typename":"CheckRun","name":"install","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-19T00:00:20Z","checkSuite":{"databaseId":2}}`
	rollupPath = "mergeCommit.statusCheckRollup"
)

func set(path, raw string) testfx.Edit { return testfx.Set(path, raw) }

func del(field string) testfx.Edit { return testfx.Del(field) }

// scenario is one case: the merged pull request after its edits, the clock, and the freezes.
type scenario struct {
	edits   []testfx.Edit
	now     string
	record  *health.Record
	freezes []state.Freeze
}

func recorded() *health.Record { return &health.Record{ID: 10, PR: 7, Issue: 45} }

func freeze(seq int, merge, status string) state.Freeze {
	return state.Freeze{Seq: seq, Reason: "post-merge checks failed", MergeSHA: merge, Health: status, Released: false}
}

func checks(nodes string) testfx.Edit {
	return func(t *testing.T, d testfx.Doc) {
		t.Helper()
		list, ok := testfx.Parse(t, nodes).([]any)
		if !ok {
			t.Fatalf("checks %q is not an array", nodes)
		}
		set(rollupPath+".contexts", fmt.Sprintf(`{"totalCount":%d,"nodes":%s}`, len(list), nodes))(t, d)
	}
}

func (s scenario) classify(t *testing.T) health.Result {
	t.Helper()
	now := s.now
	if now == "" {
		now = "2026-10-19T00:05:00Z"
	}
	at, err := time.Parse(time.RFC3339, now)
	if err != nil {
		t.Fatal(err)
	}
	return health.Classify(health.Input{
		Record:  s.record,
		Freezes: s.freezes,
		Pull:    testfx.Decode[snapshot.MergePull](t, mergedPull, s.edits...),
		Now:     at,
	})
}

func with(edits ...testfx.Edit) scenario {
	return scenario{edits: edits, now: "", record: recorded(), freezes: nil}
}

func (s scenario) at(now string) scenario {
	s.now = now
	return s
}

func (s scenario) frozen(f ...state.Freeze) scenario {
	s.freezes = f
	return s
}

func want(t *testing.T, r health.Result, status health.Status, next health.Next) {
	t.Helper()
	if r.Status != status || r.Next != next {
		t.Errorf("result = %s/%s (%s), want %s/%s", r.Status, r.Next, r.Reason, status, next)
	}
}

func wantReason(t *testing.T, r health.Result, part string) {
	t.Helper()
	if !strings.Contains(r.Reason, part) {
		t.Errorf("reason = %q, want it to contain %q", r.Reason, part)
	}
}

func TestAnEpicWithNoPostMergeRecordIsClear(t *testing.T) {
	t.Parallel()

	r := health.Classify(health.Input{Record: nil, Freezes: nil, Pull: nil, Now: time.Time{}})
	want(t, r, health.Clear, health.NextProceed)
	if r.RecordID != 0 || r.Merge != "" || r.PR != 0 {
		t.Errorf("result = %+v, want no record, no merge", r)
	}
}

func TestARecordedPRThatNeverMergedIsClear(t *testing.T) {
	t.Parallel()

	s := with(set("state", `"OPEN"`), set("mergedAt", `null`), set("mergeCommit", `null`))
	r := s.classify(t)
	want(t, r, health.Clear, health.NextProceed)
	wantReason(t, r, "not merged")
	if r.RecordID != 10 || r.PR != 7 || r.Issue != 45 {
		t.Errorf("result = %+v, want the record's id, pr, and issue", r)
	}
	// A closed PR never landed either.
	want(t, with(set("state", `"CLOSED"`), set("mergeCommit", `null`)).classify(t), health.Clear, health.NextProceed)
}

func TestEveryCheckPassingOnTheMergeCommitIsPass(t *testing.T) {
	t.Parallel()

	r := with().classify(t)
	want(t, r, health.Pass, health.NextProceed)
	if r.Merge != "m111" || r.Issue != 45 {
		t.Errorf("result = %+v, want merge m111, issue 45", r)
	}
}

func TestPendingCases(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		s      scenario
		reason string
	}{
		"a pending check": {with(checks("[" + pendingRun + "]")), "check pending: install"},
		"a pending commit status": {
			with(checks(`[{"__typename":"StatusContext","context":"ci/lint","state":"PENDING","createdAt":"2026-10-19T00:00:10Z"}]`)),
			"check pending: ci/lint",
		},
		"no checks reported yet within the grace period": {with(set(rollupPath, `null`)), "no checks reported"},
		"a merge checked too soon after it landed":       {with().at("2026-10-19T00:01:00Z"), "settling"},
		"a pending check is awaited before a cancelled one is judged": {
			with(checks("[" + strings.Replace(failedRun, "FAILURE", "CANCELLED", 1) + "," + pendingRun + "]")), "check pending",
		},
		"a freeze naming the merge never hides a pending check": {
			with(checks("[" + pendingRun + "]")).frozen(freeze(11, "m111", "FAIL")), "check pending",
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := tc.s.classify(t)
			want(t, r, health.Pending, health.NextWait)
			wantReason(t, r, tc.reason)
		})
	}
}

func TestFailCases(t *testing.T) {
	t.Parallel()

	tests := map[string]scenario{
		"a failed check":                      with(checks("[" + failedRun + "]")),
		"a failure wins over a pending check": with(checks("[" + failedRun + "," + pendingRun + "]")),
		"a failure wins over a cancelled run": with(checks("[" +
			strings.NewReplacer("FAILURE", "CANCELLED", `"validate"`, `"lint"`, `"databaseId":1`, `"databaseId":3`).Replace(failedRun) + "," + failedRun + "]")),
		"a failed commit status":   with(checks(`[{"__typename":"StatusContext","context":"ci/lint","state":"FAILURE","createdAt":"2026-10-19T00:00:10Z"}]`)),
		"an errored commit status": with(checks(`[{"__typename":"StatusContext","context":"ci/lint","state":"ERROR","createdAt":"2026-10-19T00:00:10Z"}]`)),
		"a freeze for UNCONFIRMED does not handle a later FAIL": with(checks("[" + failedRun + "]")).
			frozen(freeze(11, "m111", "UNCONFIRMED")),
		"a freeze without a health handles nothing": with(checks("[" + failedRun + "]")).frozen(freeze(11, "m111", "")),
		"a freeze for another commit does not handle the failure": with(checks("[" + failedRun + "]")).
			frozen(freeze(11, "m999", "FAIL")),
	}
	for _, c := range []string{"TIMED_OUT", "ACTION_REQUIRED", "STALE", "STARTUP_FAILURE"} {
		tests["a "+c+" run is a failure, never a pass"] = with(checks("[" + strings.Replace(failedRun, "FAILURE", c, 1) + "]"))
	}
	for name, s := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			want(t, s.classify(t), health.Fail, health.NextFreeze)
		})
	}

	r := with(checks("[" + failedRun + "]")).classify(t)
	if r.Merge != "m111" {
		t.Errorf("merge = %q, want m111", r.Merge)
	}
	wantReason(t, r, "check failed: validate")
}

func TestUnconfirmedCases(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		s      scenario
		reason string
	}{
		"no checks reported after the grace period":     {with(set(rollupPath, `null`)).at("2026-10-19T00:10:00Z"), "no checks reported"},
		"an empty check list is treated like no checks": {with(checks(`[]`)).at("2026-10-19T01:00:00Z"), "no checks reported"},
		"a cancelled run": {
			with(checks("[" + strings.Replace(failedRun, "FAILURE", "CANCELLED", 1) + "]")), "check cancelled",
		},
		"a check still pending an hour after the merge": {with(checks("[" + pendingRun + "]")).at("2026-10-19T01:00:00Z"), "still pending"},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := tc.s.classify(t)
			want(t, r, health.Unconfirmed, health.NextFreeze)
			wantReason(t, r, tc.reason)
			if r.Merge != "m111" {
				t.Errorf("merge = %q, want m111", r.Merge)
			}
		})
	}
}

func TestARerunThatPassedSupersedesTheFailedRun(t *testing.T) {
	t.Parallel()

	rerun := strings.NewReplacer("FAILURE", "SUCCESS", "00:00:10Z", "00:03:00Z").Replace(failedRun)
	want(t, with(checks("["+failedRun+","+rerun+"]")).classify(t), health.Pass, health.NextProceed)
}

func TestAFreezeAlreadyNamingTheResultHandlesIt(t *testing.T) {
	t.Parallel()

	r := with(checks("[" + failedRun + "]")).frozen(freeze(11, "m111", "FAIL")).classify(t)
	want(t, r, health.Handled, health.NextProceed)
	wantReason(t, r, "freeze 11")

	r = with(set(rollupPath, `null`)).at("2026-10-19T02:00:00Z").frozen(freeze(11, "m111", "UNCONFIRMED")).classify(t)
	want(t, r, health.Handled, health.NextProceed)

	// The earliest of several matching freezes owns it.
	r = with(checks("["+failedRun+"]")).frozen(freeze(14, "m111", "FAIL"), freeze(12, "m111", "FAIL")).classify(t)
	wantReason(t, r, "freeze 12")
}

// TestAReleasedFreezeStillHandlesItsResult: after epic-release the same result reads HANDLED,
// and a different result freezes again.
func TestAReleasedFreezeStillHandlesItsResult(t *testing.T) {
	t.Parallel()

	released := freeze(3, "m111", "FAIL")
	want(t, with(checks("["+failedRun+"]")).frozen(released).classify(t), health.Handled, health.NextProceed)
	want(t, with(set(rollupPath, `null`)).at("2026-10-19T02:00:00Z").frozen(released).classify(t), health.Unconfirmed, health.NextFreeze)
}

func TestUnreadableCases(t *testing.T) {
	t.Parallel()

	noPR := with()
	noPR.record = &health.Record{ID: 10, PR: 0, Issue: 45}
	noIssue := with()
	noIssue.record = &health.Record{ID: 10, PR: 7, Issue: 0}
	otherPR := with()
	otherPR.record = &health.Record{ID: 10, PR: 8, Issue: 45}
	tests := map[string]scenario{
		"a record without a readable pr":     noPR,
		"a record without a readable issue":  noIssue,
		"a snapshot for a different PR":      otherPR,
		"a merged PR without a merge commit": with(set("mergeCommit", `null`)),
		"a merge commit with no oid":         with(set("mergeCommit.oid", `null`)),
		"a truncated check list":             with(set(rollupPath+".contexts.totalCount", `101`)),
		"a missing check list":               with(set(rollupPath+".contexts", `null`)),
		"an unknown check state":             with(checks(`[{"__typename":"CheckRun","name":"validate","status":null,"conclusion":null}]`)),
		"a merge time that cannot be read":   with(set("mergedAt", `"yesterday"`)),
		"no merge time":                      with(del("mergedAt")),
		"an unknown pull request state":      with(set("state", `"DRAFT"`)),
	}
	for name, s := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			want(t, s.classify(t), health.Unreadable, health.NextHold)
		})
	}

	r := health.Classify(health.Input{Record: recorded(), Freezes: nil, Pull: nil, Now: time.Time{}})
	want(t, r, health.Unreadable, health.NextHold)
	wantReason(t, r, "no pull request read")

	wantReason(t, with(set(rollupPath+".contexts.totalCount", `101`)).classify(t), "checks truncated on m111 (101 > 2)")
}
