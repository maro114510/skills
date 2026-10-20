package readiness_test

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/readiness"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/testfx"
)

// The cases below are the cases of the earlier test-pr-readiness.bats, over the same clean
// snapshot: each edits that snapshot and classifies it.
const cleanPR = `{
  "number":7,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
  "reviewDecision":"APPROVED","isMergeQueueEnabled":false,"headRefOid":"abc123",
  "reviewRequests":{"totalCount":0,"nodes":[]},
  "latestOpinionatedReviews":{"totalCount":1,"nodes":[{"state":"APPROVED","author":{"login":"alice"}}]},
  "reviewThreads":{"totalCount":1,"nodes":[{"isResolved":true}]},
  "commits":{"nodes":[{"commit":{"oid":"abc123","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":2,"nodes":[
    {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS"}]}}}}]}}`

const rollupPath = "commits.nodes.0.commit.statusCheckRollup"

type edit = testfx.Edit

func set(path, raw string) testfx.Edit { return testfx.Set(path, raw) }

func del(field string) testfx.Edit { return testfx.Del(field) }

// checks replaces the contexts of the head commit's rollup.
func checks(nodes string) edit {
	return func(t *testing.T, d testfx.Doc) {
		t.Helper()
		list, ok := testfx.Parse(t, nodes).([]any)
		if !ok {
			t.Fatalf("checks %q is not an array", nodes)
		}
		set(rollupPath+".contexts", fmt.Sprintf(`{"totalCount":%d,"nodes":%s}`, len(list), nodes))(t, d)
	}
}

func conn(total int, nodes string) string {
	return fmt.Sprintf(`{"totalCount":%d,"nodes":%s}`, total, nodes)
}

func classify(t *testing.T, edits ...edit) readiness.Result {
	t.Helper()
	return readiness.Classify(testfx.Decode[snapshot.PullRequest](t, cleanPR, edits...))
}

func repairs(r readiness.Result) []string {
	out := make([]string, 0, len(r.Repair))
	for _, k := range r.Repair {
		out = append(out, string(k))
	}
	return out
}

func wantStatus(t *testing.T, r readiness.Result, status readiness.Status) {
	t.Helper()
	if r.Status != status {
		t.Errorf("status = %s (%s), want %s", r.Status, r.Reason, status)
	}
}

func wantNext(t *testing.T, r readiness.Result, next readiness.Next) {
	t.Helper()
	if r.Next != next {
		t.Errorf("next = %s (%s), want %s", r.Next, r.Reason, next)
	}
}

func wantReason(t *testing.T, r readiness.Result, parts ...string) {
	t.Helper()
	for _, p := range parts {
		if !strings.Contains(r.Reason, p) {
			t.Errorf("reason = %q, want it to contain %q", r.Reason, p)
		}
	}
}

func wantNoReason(t *testing.T, r readiness.Result, part string) {
	t.Helper()
	if strings.Contains(r.Reason, part) {
		t.Errorf("reason = %q, want it not to contain %q", r.Reason, part)
	}
}

func run(name, status, conclusion, started, suite string) string {
	return fmt.Sprintf(`{"__typename":"CheckRun","name":%q,"status":%q,"conclusion":%s,"startedAt":%s,`+
		`"checkSuite":{"databaseId":%s,"app":{"slug":"github-actions"},"workflowRun":{"workflow":{"name":"CI"}}}}`,
		name, status, conclusion, started, suite)
}

func TestReadyCases(t *testing.T) {
	t.Parallel()

	tests := map[string][]edit{
		"checks and reviews complete with no rejection": nil,
		"no review policy and no reviews": {
			set("reviewDecision", `null`),
			set("latestOpinionatedReviews", conn(0, `[]`)),
		},
		"HAS_HOOKS merge state": {set("mergeStateStatus", `"HAS_HOOKS"`)},
		"neutral and skipped checks do not hold a merge": {checks(`[
			{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"NEUTRAL"},
			{"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"SKIPPED"}]`)},
		"a failed check re-run to success in the same suite": {checks("[" +
			run("test", "COMPLETED", `"FAILURE"`, `"2026-10-19T01:00:00Z"`, "11") + "," +
			run("test", "COMPLETED", `"SUCCESS"`, `"2026-10-19T02:00:00Z"`, "11") + "]")},
		"a re-posted commit status supersedes the earlier one": {checks(`[
			{"__typename":"StatusContext","context":"ci/a","state":"FAILURE","createdAt":"2026-10-19T01:00:00Z"},
			{"__typename":"StatusContext","context":"ci/a","state":"SUCCESS","createdAt":"2026-10-19T02:00:00Z"}]`)},
	}
	for name, edits := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := classify(t, edits...)
			wantStatus(t, r, readiness.Ready)
			wantNext(t, r, readiness.NextMerge)
			if r.PR != 7 || r.Head != "abc123" || len(r.Repair) != 0 || r.Unreadable {
				t.Errorf("result = %+v, want pr 7, head abc123, nothing to repair", r)
			}
		})
	}
}

func TestTerminalStates(t *testing.T) {
	t.Parallel()

	r := classify(t, set("state", `"MERGED"`), set("mergeable", `"UNKNOWN"`), set("mergeStateStatus", `"UNKNOWN"`))
	wantStatus(t, r, readiness.Merged)
	wantNext(t, r, readiness.NextNone)

	r = classify(t, set("state", `"CLOSED"`))
	wantStatus(t, r, readiness.Closed)
	wantNext(t, r, readiness.NextNone)

	// A merged pull request needs no other signal to be read.
	r = classify(t, set("state", `"MERGED"`), set("reviewThreads.totalCount", `101`))
	wantStatus(t, r, readiness.Merged)
	if r.Unreadable {
		t.Error("a merged pull request must not be unreadable")
	}
}

func TestWaitingCases(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		edits   []edit
		reasons []string
		next    readiness.Next
	}{
		"a pending check run": {
			[]edit{checks(`[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null}]`)},
			[]string{"check pending: test"}, readiness.NextWait,
		},
		"a queued run and pending or expected statuses": {
			[]edit{checks(`[{"__typename":"CheckRun","name":"q","status":"QUEUED","conclusion":null},
				{"__typename":"StatusContext","context":"ci/a","state":"PENDING"},
				{"__typename":"StatusContext","context":"ci/b","state":"EXPECTED"}]`)},
			[]string{"check pending: q", "check pending: ci/a", "check pending: ci/b"}, readiness.NextWait,
		},
		"no checks reported on the head": {
			[]edit{set(rollupPath, `null`)}, []string{"no checks reported"}, readiness.NextWait,
		},
		"mergeability still being computed": {
			[]edit{set("mergeable", `"UNKNOWN"`), set("mergeStateStatus", `"UNKNOWN"`)},
			[]string{"mergeability still being computed"}, readiness.NextWait,
		},
		"a required review not yet given": {
			[]edit{set("reviewDecision", `"REVIEW_REQUIRED"`)}, []string{"review required"}, readiness.NextHuman,
		},
		"outstanding review requests from a person and a team": {
			[]edit{set("reviewRequests", conn(2, `[{"requestedReviewer":{"__typename":"User","login":"bob"}},
				{"requestedReviewer":{"__typename":"Team","slug":"core"}}]`))},
			[]string{"review requested: bob", "review requested: core"}, readiness.NextHuman,
		},
		"a review requested from a bot": {
			[]edit{set("reviewRequests", conn(1, `[{"requestedReviewer":{"__typename":"Bot","login":"coderabbitai"}}]`))},
			[]string{"review requested: coderabbitai"}, readiness.NextWait,
		},
		"a human wait outranks a pending check": {
			[]edit{checks(`[{"__typename":"CheckRun","name":"slow","status":"IN_PROGRESS","conclusion":null}]`),
				set("reviewDecision", `"REVIEW_REQUIRED"`)},
			[]string{"check pending: slow", "review required"}, readiness.NextHuman,
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := classify(t, tc.edits...)
			wantStatus(t, r, readiness.Waiting)
			wantNext(t, r, tc.next)
			wantReason(t, r, tc.reasons...)
			if len(r.Repair) != 0 {
				t.Errorf("repair = %v, want none while waiting", r.Repair)
			}
		})
	}
}

func TestBlockedCases(t *testing.T) {
	t.Parallel()

	failedA := `[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"}]`
	tests := map[string]struct {
		edits   []edit
		reasons []string
		next    readiness.Next
		repair  []string
	}{
		"a conflict": {
			[]edit{set("mergeable", `"CONFLICTING"`), set("mergeStateStatus", `"DIRTY"`)},
			[]string{"conflict"}, readiness.NextRepair, []string{"conflict"},
		},
		"an unresolved review thread": {
			[]edit{set("reviewThreads", conn(2, `[{"isResolved":true},{"isResolved":false}]`))},
			[]string{"1 unresolved review thread"}, readiness.NextRepair, []string{"review"},
		},
		"changes requested by the review decision": {
			[]edit{set("reviewDecision", `"CHANGES_REQUESTED"`)},
			[]string{"changes requested"}, readiness.NextRepair, []string{"review"},
		},
		"changes requested by a bot review outside the review decision": {
			[]edit{set("latestOpinionatedReviews", conn(2, `[{"state":"APPROVED","author":{"login":"alice"}},
				{"state":"CHANGES_REQUESTED","author":{"login":"coderabbitai"}}]`))},
			[]string{"changes requested: coderabbitai"}, readiness.NextRepair, []string{"review"},
		},
		"a check asking for human action": {
			[]edit{checks(`[{"__typename":"CheckRun","name":"ai-review","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}]`)},
			[]string{"human action required: ai-review"}, readiness.NextHuman, nil,
		},
		"failed checks of every kind, a cancelled run included": {
			[]edit{checks(`[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"},
				{"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"TIMED_OUT"},
				{"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"CANCELLED"},
				{"__typename":"StatusContext","context":"d","state":"ERROR"},
				{"__typename":"StatusContext","context":"e","state":"FAILURE"}]`)},
			[]string{"check failed: a", "check failed: b", "check failed: c", "check failed: d", "check failed: e"},
			readiness.NextRepair, []string{"checks"},
		},
		"same-named checks from workflows sharing a display name stay separate": {
			[]edit{checks("[" + run("build", "COMPLETED", `"FAILURE"`, `"2026-10-19T01:00:00Z"`, "11") + "," +
				run("build", "COMPLETED", `"SUCCESS"`, `"2026-10-19T02:00:00Z"`, "22") + "]")},
			[]string{"check failed: build"}, readiness.NextRepair, []string{"checks"},
		},
		"one workflow triggered twice on the same head keeps both runs": {
			[]edit{checks("[" + run("test", "COMPLETED", `"SUCCESS"`, `"2026-10-19T02:00:00Z"`, "11") + "," +
				run("test", "COMPLETED", `"FAILURE"`, `"2026-10-19T01:00:00Z"`, "22") + "]")},
			[]string{"check failed: test"}, readiness.NextRepair, []string{"checks"},
		},
		"check runs without a check suite id are never collapsed": {
			[]edit{checks("[" + run("test", "COMPLETED", `"FAILURE"`, `"2026-10-19T01:00:00Z"`, "null") + "," +
				run("test", "COMPLETED", `"SUCCESS"`, `"2026-10-19T02:00:00Z"`, "null") + "]")},
			[]string{"check failed: test"}, readiness.NextRepair, []string{"checks"},
		},
		"a draft": {
			[]edit{set("isDraft", `true`), set("mergeStateStatus", `"DRAFT"`)},
			[]string{"draft"}, readiness.NextHuman, nil,
		},
		"a merge queue on the base branch": {
			[]edit{set("isMergeQueueEnabled", `true`)}, []string{"merge queue"}, readiness.NextHuman, nil,
		},
		"repository merge controls reject the merge": {
			[]edit{set("mergeStateStatus", `"BLOCKED"`)}, []string{"merge state BLOCKED"}, readiness.NextHuman, nil,
		},
		"a repairable block outranks a pending check": {
			[]edit{checks(`[{"__typename":"CheckRun","name":"slow","status":"IN_PROGRESS","conclusion":null}]`),
				set("mergeable", `"CONFLICTING"`)},
			[]string{"conflict"}, readiness.NextRepair, []string{"conflict"},
		},
		"a repairable block is still repaired while a person's review is outstanding": {
			[]edit{checks(failedA), set("reviewDecision", `"REVIEW_REQUIRED"`)},
			[]string{"check failed: a"}, readiness.NextRepair, []string{"checks"},
		},
		"every repairable kind is listed in a fixed order": {
			[]edit{checks(failedA), set("reviewThreads.nodes.0.isResolved", `false`), set("mergeable", `"CONFLICTING"`)},
			[]string{"check failed: a", "conflict", "unresolved review thread"}, readiness.NextRepair,
			[]string{"checks", "conflict", "review"},
		},
		"requested changes and unresolved threads say repair review once": {
			[]edit{set("reviewDecision", `"CHANGES_REQUESTED"`), set("reviewThreads.nodes.0.isResolved", `false`),
				set("latestOpinionatedReviews.nodes.0.state", `"CHANGES_REQUESTED"`)},
			[]string{"changes requested"}, readiness.NextRepair, []string{"review"},
		},
		"a block no worker can lift wins even beside a repairable one": {
			[]edit{checks(failedA), set("isDraft", `true`)},
			[]string{"check failed: a", "draft"}, readiness.NextHuman, nil,
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := classify(t, tc.edits...)
			wantStatus(t, r, readiness.Blocked)
			wantNext(t, r, tc.next)
			wantReason(t, r, tc.reasons...)
			if got := repairs(r); !slices.Equal(got, tc.repair) && (len(got) != 0 || len(tc.repair) != 0) {
				t.Errorf("repair = %v, want %v", got, tc.repair)
			}
			if r.Unreadable {
				t.Error("a block is not an unreadable signal")
			}
		})
	}
}

func TestRepositoryMergeControlsRejectingTheMerge(t *testing.T) {
	t.Parallel()

	for _, s := range []string{"BLOCKED", "BEHIND", "UNSTABLE", "SOMETHING_NEW"} {
		r := classify(t, set("mergeStateStatus", strconv.Quote(s)))
		wantStatus(t, r, readiness.Blocked)
		wantReason(t, r, "merge state "+s)
		wantNext(t, r, readiness.NextHuman)
	}
}

func TestARerunThatHasNotStartedSupersedesTheEarlierResult(t *testing.T) {
	t.Parallel()

	r := classify(t, checks("["+
		run("test", "QUEUED", `null`, `null`, "11")+","+
		run("test", "COMPLETED", `"FAILURE"`, `"2026-10-19T01:00:00Z"`, "11")+"]"))
	wantStatus(t, r, readiness.Waiting)
	wantReason(t, r, "check pending: test")
}

func TestABlockedSignalOutranksAWaitingOneAndEveryReasonIsListed(t *testing.T) {
	t.Parallel()

	r := classify(t,
		checks(`[{"__typename":"CheckRun","name":"slow","status":"IN_PROGRESS","conclusion":null}]`),
		set("mergeable", `"CONFLICTING"`),
		set("reviewThreads.nodes.0.isResolved", `false`))
	wantStatus(t, r, readiness.Blocked)
	wantReason(t, r, "conflict", "unresolved review thread")
	wantNoReason(t, r, "check pending")
}

// TestUnreadableSignalsHoldTheMerge covers every way a signal can be missing: the merge is held
// with status BLOCKED, next human, and an unreadable flag.
func TestUnreadableSignalsHoldTheMerge(t *testing.T) {
	t.Parallel()

	for _, f := range []string{"state", "isDraft", "mergeable", "mergeStateStatus", "isMergeQueueEnabled",
		"reviewRequests", "latestOpinionatedReviews", "reviewThreads", "commits"} {
		t.Run("missing "+f, func(t *testing.T) {
			t.Parallel()
			r := classify(t, del(f))
			wantStatus(t, r, readiness.Blocked)
			wantNext(t, r, readiness.NextHuman)
			wantReason(t, r, "unreadable")
			if !r.Unreadable {
				t.Error("Unreadable = false, want true")
			}
		})
	}

	tests := map[string][]edit{
		"a null thread state":            {set("reviewThreads.nodes.0.isResolved", `null`)},
		"no head commit":                 {set("commits.nodes", `[]`)},
		"a completed run with no result": {checks(`[{"__typename":"CheckRun","name":"x","status":"COMPLETED","conclusion":null}]`)},
		"a check of an unknown kind":     {checks(`[{"__typename":"SomethingElse"}]`)},
		"a review with no state":         {set("latestOpinionatedReviews.nodes.0.state", `null`)},
		"a truncated reviewThreads":      {set("reviewThreads.totalCount", `101`)},
		"a truncated latestOpinionated":  {set("latestOpinionatedReviews.totalCount", `101`)},
		"a truncated reviewRequests":     {set("reviewRequests.totalCount", `101`)},
		"a truncated check list":         {set(rollupPath+".contexts.totalCount", `101`)},
		"an unknown pull request state":  {set("state", `"DRAFT"`)},
	}
	for name, edits := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := classify(t, edits...)
			wantStatus(t, r, readiness.Blocked)
			wantNext(t, r, readiness.NextHuman)
			if !r.Unreadable || !strings.HasPrefix(r.Reason, "unreadable: ") {
				t.Errorf("result = %+v, want an unreadable hold", r)
			}
		})
	}
}

func TestEachUnreadableSignalIsNamedExactlyOnce(t *testing.T) {
	t.Parallel()

	r := classify(t, set("reviewThreads.totalCount", `101`), set(rollupPath+".contexts.nodes.0", `null`))
	want := "unreadable: reviewThreads truncated (101 > 1); check state missing: unnamed check"
	if r.Reason != want {
		t.Errorf("reason = %q, want %q", r.Reason, want)
	}
}

func TestTruncatedConnectionsAreNamed(t *testing.T) {
	t.Parallel()

	for _, c := range []string{"reviewThreads", "latestOpinionatedReviews", "reviewRequests"} {
		r := classify(t, set(c+".totalCount", `101`))
		wantReason(t, r, "unreadable: "+c+" truncated")
	}
}

func TestAMissingPullRequestIsUnreadable(t *testing.T) {
	t.Parallel()

	r := readiness.Classify(nil)
	wantStatus(t, r, readiness.Blocked)
	wantNext(t, r, readiness.NextHuman)
	if !r.Unreadable {
		t.Error("Unreadable = false, want true")
	}
}
