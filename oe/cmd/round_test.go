package cmd_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

const (
	roundPR   = 12
	roundHead = "sha12"
	roundBase = "base1"
	oldRecord = "old01"
)

// roundWorld is an Epic whose Issue 7 is shipped as pull request 12 on its reviewed head and the current base, so the board reads it
// awaiting-merge, and whose checks are pending until a test says otherwise. The lease is held by tok.
type roundWorld struct {
	*coordWorld
	tok       string
	readiness func() string
	health    func() string
}

func newRoundWorld(t *testing.T) *roundWorld {
	t.Helper()
	w := &roundWorld{coordWorld: newCoordWorld(t), tok: "", readiness: nil, health: nil}
	w.tok = w.acquire(t)
	w.readiness = func() string { return pullBody(roundPull("IN_PROGRESS", "")) }
	w.health = func() string { return mergedPullBody(11, oldRecord, "SUCCESS") }
	w.put(t, 7, awaitingState())
	w.r.On(ghfake.Pulls, func(map[string]string) string {
		return ghfake.PullPage("["+ghfake.PullNode(roundPR, "OPEN", "feat/issue-7", "2026-10-05T00:00:00Z", false)+"]", false, "")
	})
	w.r.On(ghfake.Readiness, func(map[string]string) string { return w.readiness() })
	w.r.On(ghfake.MergePull, func(map[string]string) string { return w.health() })
	return w
}

// roundPull is pull request 12 with one check at the given status; an empty status means no check at all.
func roundPull(status, conclusion string) pullOpts {
	o := readyPull(roundHead)
	o.contexts = `{"totalCount":0,"nodes":[]}`
	if status != "" {
		o.contexts = `{"totalCount":1,"nodes":[{"__typename":"CheckRun","name":"build","status":"` + status + `","conclusion":` + quoted(conclusion) + `}]}`
	}
	return o
}

func quoted(s string) string {
	if s == "" {
		return "null"
	}
	return `"` + s + `"`
}

// awaitingState is Issue 7's state: approved at the pull request's head on the current base, published as pull request 12.
func awaitingState() *state.Issue {
	head := roundHead
	var st state.Issue
	st.Entity, st.Key = state.EntityIssue, state.IssueKey(7)
	st.Branch, st.HeadSHA = "feat/issue-7", &head
	st.PendingFindings, st.UnresolvedBlockers, st.Context = []string{}, []string{}, []state.Context{}
	st.Approval = &state.Approval{ReviewedSHA: head, VerifiedBase: roundBase, ReviewEvidence: state.ReviewEvidence{
		BehaviorChange: false, Basis: "docs only",
		Criteria: []state.Criterion{{Text: "documented", Result: "verified", Kind: "static", Evidence: "README.md:3"}},
	}}
	st.Publish = &state.Publish{SHA: head, PrevSHA: "", Base: roundBase, Branch: "feat/issue-7", PR: roundPR, Phase: "linked"}
	return &st
}

// startedState is Issue 7 started and nothing else: it is in progress.
func startedState() *state.Issue {
	var st state.Issue
	st.Entity, st.Key = state.EntityIssue, state.IssueKey(7)
	st.Branch = "feat/issue-7"
	st.PendingFindings, st.UnresolvedBlockers, st.Context = []string{}, []string{}, []state.Context{}
	return &st
}

func (w *roundWorld) round(sub ...string) result {
	return w.run(append(append([]string{"--epic", "277", "round"}, sub...), "--lease-token", w.tok)...)
}

// newSession ends the lease and takes it again: a new invocation with a token of its own.
func (w *roundWorld) newSession(t *testing.T) {
	t.Helper()
	if r := w.run("--epic", "277", "lease", "end", "--lease-token", w.tok); r.code != 0 {
		t.Fatalf("lease end: exit %d, stdout %q", r.code, r.stdout)
	}
	w.tok = w.acquire(t)
}

func (w *roundWorld) record(t *testing.T, phase, merge string) {
	t.Helper()
	var pm state.PostMerge
	pm.Entity, pm.Key = state.EntityPostMerge, state.KeyPostMerge
	pm.PR, pm.Issue, pm.ReviewedSHA, pm.VerifiedBase = 11, 6, "oldrev1", "oldbase"
	pm.Phase, pm.MergeSHA, pm.RequestedAt = phase, merge, "2026-10-18T23:00:00Z"
	for _, c := range w.store.Comments(277) {
		if strings.HasPrefix(c.Body, "<!-- oe:v2 state post-merge -->") {
			w.store.Delete(c.ID)
		}
	}
	w.put(t, 277, &pm)
}

func jsonOf(t *testing.T, r result, v any) {
	t.Helper()
	if err := json.Unmarshal([]byte(strings.SplitN(r.stdout, "\n", 2)[0]), v); err != nil {
		t.Fatalf("stdout %q is not the payload: %v", r.stdout, err)
	}
}

type held struct {
	Issue  int    `json:"issue"`
	PR     int    `json:"pr"`
	Reason string `json:"reason"`
}

type pollOut struct {
	Decision     string `json:"decision"`
	SleepSeconds int    `json:"sleep_seconds"`
	Polls        int    `json:"polls"`
	Waiting      []held `json:"waiting"`
	Human        []held `json:"human"`
}

func (w *roundWorld) poll(t *testing.T) pollOut {
	t.Helper()
	r := w.round("poll")
	var out pollOut
	if r.code != 0 {
		t.Fatalf("poll: exit %d, stdout %q", r.code, r.stdout)
	}
	jsonOf(t, r, &out)
	return out
}

func TestRoundPollSleepsThirtyTimesAndThenStopsListingTheWaitingPullRequest(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)

	for i := 1; i <= 30; i++ {
		if out := w.poll(t); out.Decision != "sleep" || out.Polls != i || out.SleepSeconds != 60 {
			t.Fatalf("poll %d = %+v, want a 60-second sleep with %d polls spent", i, out, i)
		}
	}
	out := w.poll(t)

	if out.Decision != "stop" || out.SleepSeconds != 0 || len(out.Waiting) != 1 || out.Waiting[0].PR != roundPR || out.Waiting[0].Issue != 7 {
		t.Errorf("the 31st poll = %+v, want stop listing pull request 12 as still waiting", out)
	}
}

func TestRoundPollRunsAnotherPassAtOnceAfterAMergeAndStartsItsCountOver(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)
	w.poll(t)
	w.poll(t)
	w.record(t, state.PhaseMerged, oldRecord)

	merged := w.poll(t)
	again := w.poll(t)

	if merged.Decision != "pass" || merged.Polls != 0 {
		t.Errorf("poll after a merge = %+v, want pass with the polls reset", merged)
	}
	if again.Decision != "sleep" || again.Polls != 1 {
		t.Errorf("poll after that = %+v, want sleep with 1 poll: the count started over", again)
	}
}

func TestRoundPollGivesAHeadThatReportsNoChecksFivePollsAndThenNeedsAPerson(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)
	w.readiness = func() string { return pullBody(roundPull("", "")) }

	for i := 1; i <= 5; i++ {
		if out := w.poll(t); out.Decision != "sleep" {
			t.Fatalf("poll %d = %+v, want sleep", i, out)
		}
	}
	out := w.poll(t)

	if out.Decision != "settled" || len(out.Waiting) != 0 || len(out.Human) != 1 || out.Human[0].PR != roundPR {
		t.Errorf("the 6th poll = %+v, want settled with pull request 12 left to a person", out)
	}
}

type nextOut struct {
	Decision   string `json:"decision"`
	Conditions struct {
		Outdated     bool `json:"outdated"`
		HealthPassed bool `json:"health_passed"`
		FreezeClear  bool `json:"freeze_clear"`
	} `json:"conditions"`
}

func (w *roundWorld) next(t *testing.T) nextOut {
	t.Helper()
	r := w.round("next")
	var out nextOut
	if r.code != 0 {
		t.Fatalf("next: exit %d, stdout %q", r.code, r.stdout)
	}
	jsonOf(t, r, &out)
	return out
}

func TestRoundNextRefusesASessionWhoseRoundNeverBegan(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)

	if r := w.round("next"); r.code != 8 || !strings.Contains(r.stdout, "oe round plan") {
		t.Errorf("exit %d, stdout %q; want exit 8 pointing at oe round plan", r.code, r.stdout)
	}
}

func TestRoundNextDoesNotContinueAfterARoundWithNoMerge(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)
	if r := w.round("plan"); r.code != 0 {
		t.Fatalf("plan: exit %d, stdout %q", r.code, r.stdout)
	}

	out := w.next(t)

	if out.Decision != "end" || out.Conditions.Outdated {
		t.Errorf("next = %+v, want end: no merge outdated the round's reading", out)
	}
}

func TestRoundNextWaitsForTheMergesChecksAndThenContinues(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)
	if r := w.round("plan"); r.code != 0 {
		t.Fatalf("plan: exit %d, stdout %q", r.code, r.stdout)
	}
	w.record(t, state.PhaseMerged, oldRecord)
	w.health = func() string {
		return `{"data":{"repository":{"pullRequest":{"number":11,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",` +
			`"mergeCommit":{"oid":"old01","statusCheckRollup":{"state":"PENDING","contexts":{"totalCount":1,"nodes":[` +
			`{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS"}]}}}}}}}`
	}

	pending := w.next(t)
	w.health = func() string { return mergedPullBody(11, oldRecord, "SUCCESS") }
	passed := w.next(t)

	if pending.Decision != "end" || !pending.Conditions.Outdated || pending.Conditions.HealthPassed {
		t.Errorf("next while the merge's checks are pending = %+v, want end", pending)
	}
	if passed.Decision != "continue" || !passed.Conditions.HealthPassed || !passed.Conditions.FreezeClear {
		t.Errorf("next once they passed = %+v, want continue", passed)
	}
}

type planOut struct {
	MaxParallel int `json:"max_parallel"`
	Work        []struct {
		Kind  string `json:"kind"`
		Issue int    `json:"issue"`
	} `json:"work"`
	LeftOut  []int `json:"left_out"`
	Deferred []struct {
		Issue  int    `json:"issue"`
		Reason string `json:"reason"`
	} `json:"deferred"`
}

func (w *roundWorld) plan(t *testing.T, extra ...string) planOut {
	t.Helper()
	r := w.run(append(append([]string{"--epic", "277"}, extra...), "round", "plan", "--lease-token", w.tok)...)
	var out planOut
	if r.code != 0 {
		t.Fatalf("plan: exit %d, stdout %q", r.code, r.stdout)
	}
	jsonOf(t, r, &out)
	return out
}

func TestRoundPlanStartsTheIssuesInFlightFirstAndCapsTheBatchAtMaxParallel(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)
	w.r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(7, "OPEN", "", "")+","+ghfake.IssueNode(8, "OPEN", "", "")+","+ghfake.IssueNode(9, "OPEN", "", "")+"]", 3, false, "")
	})
	w.r.On(ghfake.Pulls, func(map[string]string) string { return ghfake.PullPage("[]", false, "") })
	for _, c := range w.store.Comments(7) {
		w.store.Delete(c.ID)
	}
	w.put(t, 9, startedIssue(9))

	out := w.plan(t, "--max-parallel", "2")

	if out.MaxParallel != 2 || len(out.Work) != 2 || out.Work[0].Issue != 9 || out.Work[1].Issue != 7 {
		t.Fatalf("plan = %+v, want Issue 9, in progress, then ready Issue 7", out)
	}
	if len(out.LeftOut) != 1 || out.LeftOut[0] != 8 {
		t.Errorf("left_out = %v, want [8]", out.LeftOut)
	}
}

func startedIssue(n int) *state.Issue {
	st := startedState()
	st.Key, st.Branch = state.IssueKey(n), "feat/issue-"+strconv.Itoa(n)
	return st
}

func inProgressWorld(t *testing.T) *roundWorld {
	t.Helper()
	w := newRoundWorld(t)
	for _, c := range w.store.Comments(7) {
		w.store.Delete(c.ID)
	}
	w.put(t, 7, startedState())
	w.r.On(ghfake.Pulls, func(map[string]string) string { return ghfake.PullPage("[]", false, "") })
	return w
}

func TestRoundDeferKeepsAnIssueOutOfLaterRoundsOfTheInvocation(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)
	if before := w.plan(t); len(before.Work) != 1 || before.Work[0].Issue != 7 {
		t.Fatalf("plan before = %+v, want Issue 7 in progress", before)
	}

	if r := w.round("defer", "--issue", "7", "--reason", "blocked"); r.code != 0 {
		t.Fatalf("defer: exit %d, stdout %q", r.code, r.stdout)
	}
	after := w.plan(t)

	if len(after.Work) != 0 || len(after.Deferred) != 1 || after.Deferred[0].Issue != 7 || after.Deferred[0].Reason != "blocked" {
		t.Errorf("plan after = %+v, want Issue 7 deferred and not started", after)
	}
}

func TestRoundDeferOfAnotherInvocationNeverCarriesOver(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)
	w.round("defer", "--issue", "7", "--reason", "blocked")
	w.newSession(t)

	out := w.plan(t)

	if len(out.Work) != 1 || out.Work[0].Issue != 7 || len(out.Deferred) != 0 {
		t.Errorf("plan in a new invocation = %+v, want Issue 7 started again: a deferral lasts one invocation", out)
	}
}

func TestRoundDeferRefusesAnUnknownReasonAndAMissingIssue(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)

	for name, args := range map[string][]string{
		"a reason outside the closed set": {"defer", "--issue", "7", "--reason", "timeout"},
		"no reason":                       {"defer", "--issue", "7"},
		"no Issue":                        {"defer", "--reason", "blocked"},
	} {
		if r := w.round(args...); r.code != 2 {
			t.Errorf("%s: exit %d, stdout %q; want 2", name, r.code, r.stdout)
		}
	}
	if out := w.plan(t); len(out.Deferred) != 0 {
		t.Errorf("deferred = %+v after refused defers, want none", out.Deferred)
	}
}

type notifyOut struct {
	Notes []struct {
		Key    string `json:"key"`
		Posted bool   `json:"posted"`
	} `json:"notes"`
}

func (w *roundWorld) notify(t *testing.T) notifyOut {
	t.Helper()
	r := w.round("notify")
	var out notifyOut
	if r.code != 0 {
		t.Fatalf("notify: exit %d, stdout %q", r.code, r.stdout)
	}
	jsonOf(t, r, &out)
	return out
}

func noteCount(w *roundWorld, issue int, key string) int {
	return countPrefix(w.store.Comments(issue), "<!-- oe:v2 note "+key+" -->")
}

func TestRoundNotifyEscalatesARejectedIssueExactlyOnceAcrossInvocations(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)
	w.r.On(ghfake.Pulls, func(map[string]string) string {
		return ghfake.PullPage("["+ghfake.PullNode(roundPR, "CLOSED", "feat/issue-7", "2026-10-05T00:00:00Z", false)+"]", false, "")
	})
	key := "rejected:7:12"

	first := w.notify(t)
	second := w.notify(t)
	w.newSession(t)
	third := w.notify(t)

	if len(first.Notes) != 1 || first.Notes[0].Key != key || !first.Notes[0].Posted {
		t.Fatalf("first notify = %+v, want the rejected note posted", first)
	}
	if second.Notes[0].Posted || third.Notes[0].Posted {
		t.Errorf("later notifies posted again: %+v, %+v", second, third)
	}
	if n := noteCount(w, 7, key); n != 1 {
		t.Errorf("rejected escalations on Issue 7 = %d, want exactly 1", n)
	}
}

func TestRoundNotifyPostsALeftoverTokenOnTheEpicAndAStaleStartOnItsIssue(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)
	w.r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("see {{T3}} and {{T3.2}}", "["+ghfake.IssueNode(7, "OPEN", "", "")+"]", 1, false, "")
	})
	w.store.Add(7, "loop", "OWNER", "<!-- oe:v2 note start:7:feat/issue-7 -->\nstarted")

	out := w.notify(t)
	w.notify(t)

	keys := map[string]bool{}
	for _, n := range out.Notes {
		keys[n.Key] = n.Posted
	}
	if !keys["stale-start:7:feat/issue-7"] || len(out.Notes) != 2 {
		t.Fatalf("notify = %+v, want a stale-start note and a leftover-token note", out)
	}
	if n := noteCount(w, 7, "stale-start:7:feat/issue-7"); n != 1 {
		t.Errorf("stale-start notes = %d, want 1", n)
	}
	if n := countPrefix(w.store.Comments(277), "<!-- oe:v2 note leftover-placeholder:277:"); n != 1 {
		t.Errorf("leftover-token notes on the Epic = %d, want 1", n)
	}
}

type completeOut struct {
	Complete      bool `json:"complete"`
	Posted        bool `json:"posted"`
	AlreadyPosted bool `json:"already_posted"`
	Unfinished    []struct {
		Issue int    `json:"issue"`
		State string `json:"state"`
	} `json:"unfinished"`
}

func (w *roundWorld) complete(t *testing.T) completeOut {
	t.Helper()
	r := w.round("complete")
	var out completeOut
	if r.code != 0 {
		t.Fatalf("complete: exit %d, stdout %q", r.code, r.stdout)
	}
	jsonOf(t, r, &out)
	return out
}

func completions(w *roundWorld) int {
	return countPrefix(w.store.Comments(277), "<!-- oe:v2 note completion -->")
}

// closedWorld is an Epic whose only Issue, 7, is closed.
func closedWorld(t *testing.T) *roundWorld {
	t.Helper()
	w := inProgressWorld(t)
	w.r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(7, "CLOSED", "", "")+"]", 1, false, "")
	})
	return w
}

func TestRoundCompleteIsNotPostedWhileAnIssueIsStillVerifying(t *testing.T) {
	t.Parallel()

	w := closedWorld(t)
	w.record(t, state.PhaseMerged, oldRecord)
	var pm state.PostMerge
	for _, c := range w.store.Comments(277) {
		if strings.HasPrefix(c.Body, "<!-- oe:v2 state post-merge -->") {
			if _, err := protocol.DecodeState(c.Body, &pm); err != nil {
				t.Fatal(err)
			}
			w.store.Delete(c.ID)
		}
	}
	pm.Issue, pm.Revision = 7, 1
	w.put(t, 277, &pm)
	w.health = func() string {
		return `{"data":{"repository":{"pullRequest":{"number":11,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",` +
			`"mergeCommit":{"oid":"old01","statusCheckRollup":{"state":"PENDING","contexts":{"totalCount":1,"nodes":[` +
			`{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS"}]}}}}}}}`
	}

	out := w.complete(t)

	if out.Complete || out.Posted || len(out.Unfinished) != 1 || out.Unfinished[0].State != "verifying" || completions(w) != 0 {
		t.Errorf("complete = %+v with %d completion comments, want nothing posted while Issue 7 is verifying", out, completions(w))
	}
}

func TestRoundCompleteIsNotPostedForAnUnfinishedIssueWithoutAnEpicDrop(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)
	for _, c := range w.store.Comments(7) {
		w.store.Delete(c.ID)
	}
	st := startedState()
	st.UnresolvedBlockers = []string{"fix cycle cap reached"}
	w.put(t, 7, st)

	out := w.complete(t)

	if out.Complete || out.Posted || completions(w) != 0 || len(out.Unfinished) != 1 || out.Unfinished[0].State != "parked" {
		t.Errorf("complete = %+v with %d completion comments, want nothing posted for a parked Issue", out, completions(w))
	}
}

// completionBody is the text of the Epic's completion comment, or "" when there is none.
func completionBody(w *roundWorld) string {
	for _, c := range w.store.Comments(277) {
		if strings.HasPrefix(c.Body, "<!-- oe:v2 note completion -->") {
			return c.Body
		}
	}
	return ""
}

func TestRoundCompletePostsOnceAndNeverPostsAgainInAnyInvocation(t *testing.T) {
	t.Parallel()

	w := closedWorld(t)

	first := w.complete(t)
	second := w.complete(t)
	w.newSession(t)
	third := w.complete(t)

	if !first.Complete || !first.Posted || first.AlreadyPosted {
		t.Fatalf("first complete = %+v, want complete and posted", first)
	}
	if !second.Complete || second.Posted || !second.AlreadyPosted || third.Posted || !third.AlreadyPosted {
		t.Errorf("later completes = %+v, %+v, want nothing posted again", second, third)
	}
	if n := completions(w); n != 1 {
		t.Errorf("completion comments = %d, want exactly 1", n)
	}
}

func TestRoundCompleteCarriesTheAssumptionsAnEarlierInvocationRecorded(t *testing.T) {
	t.Parallel()

	w := closedWorld(t)
	w.store.Add(7, "loop", "OWNER", "<!-- oe:v2 note report:7:abc1234:aaaaaaaaaaaa -->\n"+handoff.DoneReportNote("abc1234", handoff.Report{
		Status: handoff.StatusDone, Issue: 7, Branch: "feat/issue-7", Worktree: "/w", HeadSHA: "abc1234", ChangedFiles: "", Checks: "", Criteria: "",
		Skipped: "criterion 2 -> deferred in an earlier invocation", Summary: "", Found: "", Questions: "", Error: "",
	}))
	w.newSession(t)

	if out := w.complete(t); !out.Posted {
		t.Fatalf("complete = %+v, want posted", out)
	}

	if body := completionBody(w); !strings.Contains(body, "criterion 2 -> deferred in an earlier invocation") {
		t.Errorf("the completion lacks the assumption an earlier invocation recorded:\n%s", body)
	}
}

func TestRoundCompleteAcceptsAnIssueAPersonDroppedAndSaysWhy(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)
	for _, c := range w.store.Comments(7) {
		w.store.Delete(c.ID)
	}
	st := startedState()
	st.UnresolvedBlockers = []string{"fix cycle cap reached"}
	st.Decision = &state.Decision{Command: "epic-drop", CommentID: 99, RedoBranch: ""}
	w.put(t, 7, st)

	out := w.complete(t)

	if !out.Complete || !out.Posted {
		t.Fatalf("complete = %+v, want a terminal report for a dropped Issue", out)
	}
	for _, c := range w.store.Comments(277) {
		if strings.HasPrefix(c.Body, "<!-- oe:v2 note completion -->") && !strings.Contains(c.Body, "fix cycle cap reached") {
			t.Errorf("the completion does not say why #7 never shipped:\n%s", c.Body)
		}
	}
}

type cleanupOut struct {
	Removed []struct {
		Issue         int    `json:"issue"`
		Worktree      string `json:"worktree"`
		BranchDeleted bool   `json:"branch_deleted"`
	} `json:"removed"`
	Kept []struct {
		Issue    int    `json:"issue"`
		Worktree string `json:"worktree"`
		Reason   string `json:"reason"`
	} `json:"kept"`
}

// cleanupFixture is Issue 7, closed with its pull request merged, and a worktree on its merged branch holding an uncommitted file.
type cleanupFixture struct {
	w       *roundWorld
	shared  string
	wt      string
	scratch string
}

func newCleanupFixture(t *testing.T) *cleanupFixture {
	t.Helper()
	w := closedWorld(t)
	w.r.On(ghfake.Pulls, func(map[string]string) string {
		return ghfake.PullPage("["+ghfake.PullNode(roundPR, "MERGED", "feat/issue-7", "2026-10-05T00:00:00Z", true)+"]", false, "")
	})
	shared := sharedRepo(t)
	wt := filepath.Join(filepath.Dir(shared), "r-wt", "feat", "issue-7")
	gitIn(t, shared, "worktree", "add", "-q", "-b", "feat/issue-7", wt)
	commitIn(t, wt, "w.txt", "work")
	gitIn(t, shared, "merge", "-q", "--no-ff", "-m", "merge", "feat/issue-7")
	scratch := filepath.Join(wt, "scratch.txt")
	if err := os.WriteFile(scratch, []byte("not committed"), 0o600); err != nil {
		t.Fatal(err)
	}
	return &cleanupFixture{w: w, shared: shared, wt: wt, scratch: scratch}
}

func (f *cleanupFixture) cleanup(t *testing.T) cleanupOut {
	t.Helper()
	r := runEnv(mixed{fake: f.w.r}, f.w.dir, "", "--epic", "277", "round", "cleanup", "--repo-dir", f.shared, "--lease-token", f.w.tok)
	var out cleanupOut
	if r.code != 0 {
		t.Fatalf("cleanup: exit %d, stdout %q", r.code, r.stdout)
	}
	jsonOf(t, r, &out)
	return out
}

func TestRoundCleanupReportsADirtyWorktreeAndKeepsIt(t *testing.T) {
	t.Parallel()

	f := newCleanupFixture(t)

	out := f.cleanup(t)

	if len(out.Kept) != 1 || out.Kept[0].Issue != 7 || out.Kept[0].Worktree != f.wt || len(out.Removed) != 0 {
		t.Fatalf("cleanup of a dirty worktree = %+v, want it reported and kept", out)
	}
	if _, err := os.Stat(f.wt); err != nil {
		t.Errorf("the dirty worktree is gone: %v", err)
	}
}

func TestRoundCleanupRemovesTheWorktreeAndMergedBranchOnceItIsClean(t *testing.T) {
	t.Parallel()

	f := newCleanupFixture(t)
	if err := os.Remove(f.scratch); err != nil {
		t.Fatal(err)
	}

	out := f.cleanup(t)

	if len(out.Removed) != 1 || out.Removed[0].Issue != 7 || !out.Removed[0].BranchDeleted || len(out.Kept) != 0 {
		t.Errorf("cleanup of a clean worktree = %+v, want it removed with its merged branch", out)
	}
	if _, err := os.Stat(f.wt); err == nil {
		t.Error("the clean worktree is still there")
	}
}

func TestRoundPlanNeverStartsAParkedIssue(t *testing.T) {
	t.Parallel()

	w := inProgressWorld(t)
	for _, c := range w.store.Comments(7) {
		w.store.Delete(c.ID)
	}
	st := startedState()
	st.UnresolvedBlockers = []string{"fix cycle cap reached"}
	w.put(t, 7, st)

	out := w.plan(t)

	if len(out.Work) != 0 || len(out.LeftOut) != 0 {
		t.Errorf("plan = %+v, want nothing started for a parked Issue", out)
	}
}

func TestRoundCompleteNeverClosesTheEpicOrAnIssue(t *testing.T) {
	t.Parallel()

	w := closedWorld(t)

	if out := w.complete(t); !out.Posted {
		t.Fatalf("complete = %+v, want posted", out)
	}

	for _, call := range w.r.Calls() {
		if joined := strings.ToLower(strings.Join(call, " ")); strings.Contains(joined, "close") || strings.Contains(joined, "state=") {
			t.Errorf("call %q closes or changes the state of an Issue", call)
		}
	}
}

func TestRoundCompletePostsNothingWhenTheLookupFails(t *testing.T) {
	t.Parallel()

	w := closedWorld(t)
	w.r.Exit(ghfake.CommentsName, 1)

	r := w.round("complete")

	if r.code != 1 || completions(w) != 0 {
		t.Errorf("exit %d, stdout %q, %d completion comments; want exit 1 and nothing posted", r.code, r.stdout, completions(w))
	}
}

func TestRoundPollExitsWith1WhenAReadinessSignalIsMissingAndNeverCountsThePoll(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)
	w.readiness = func() string {
		return strings.Replace(pullBody(roundPull("IN_PROGRESS", "")), `"mergeable":"MERGEABLE",`, "", 1)
	}

	r := w.round("poll")

	if r.code != 1 {
		t.Fatalf("exit %d, stdout %q; want 1: a pull request whose readiness cannot be read is a failed read, not a settled one", r.code, r.stdout)
	}
	w.readiness = func() string { return pullBody(roundPull("IN_PROGRESS", "")) }
	if out := w.poll(t); out.Polls != 1 {
		t.Errorf("the next poll = %+v, want 1 poll spent: the failed read must not have been counted", out)
	}
}

func TestRoundNextRefusesASessionWithNoRoundEvenWhenTheBoardCannotBeRead(t *testing.T) {
	t.Parallel()

	w := newRoundWorld(t)
	w.r.On(ghfake.Tree, func(map[string]string) string { return unreadableBody })

	r := w.round("next")

	if r.code != 8 || !strings.Contains(r.stdout, "oe round plan") {
		t.Errorf("exit %d, stdout %q; want exit 8 pointing at oe round plan, since the session alone shows no round began", r.code, r.stdout)
	}
}
