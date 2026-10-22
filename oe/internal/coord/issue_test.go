package coord_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

func evidence(behaviorChange bool, kinds ...string) state.ReviewEvidence {
	ev := state.ReviewEvidence{BehaviorChange: behaviorChange, Basis: "reviewer", Criteria: nil}
	for _, k := range kinds {
		ev.Criteria = append(ev.Criteria, state.Criterion{Text: "it works", Result: coord.ResultVerified, Kind: k, Evidence: "go test ./... -> exit 0"})
	}
	return ev
}

func approved(head, base string) *state.Issue {
	st := newIssue()
	st.HeadSHA = &head
	st.Approval = &state.Approval{ReviewedSHA: head, VerifiedBase: base, ReviewEvidence: evidence(true, coord.KindBehavior)}
	return st
}

// TestApprovalTripleIsWrittenWhole: no state with part of the approval triple validates, and a
// stored state missing one part of it does not even decode.
func TestApprovalTripleIsWrittenWhole(t *testing.T) {
	t.Parallel()

	for name, edit := range map[string]func(*state.Approval){
		"no reviewed_sha":  func(a *state.Approval) { a.ReviewedSHA = "" },
		"no verified_base": func(a *state.Approval) { a.VerifiedBase = "" },
		"no review_evidence": func(a *state.Approval) {
			a.ReviewEvidence = state.ReviewEvidence{BehaviorChange: false, Basis: "", Criteria: nil}
		},
	} {
		st := approved("h1", "b1")
		edit(st.Approval)
		if st.Approval.ReviewedSHA == "" {
			st.HeadSHA = new("")
		}
		if err := coord.Validate(st); exitcode.CodeOf(err) != exitcode.Refused {
			t.Errorf("%s: %v, want refused", name, err)
		}
	}
	body := mustBody(approved("h1", "b1"))
	partial := strings.Replace(body, `"verified_base": "b1",`, "", 1)
	if partial == body {
		t.Fatal("fixture did not change")
	}
	_, err := protocol.DecodeState(partial, new(state.Issue))
	wantCode(t, err, exitcode.Protocol)
}

// TestForbiddenCombinationsNeverValidate covers contract §5.1 items 2 to 6 and 8.
func TestForbiddenCombinationsNeverValidate(t *testing.T) {
	t.Parallel()

	cases := map[string]func() *state.Issue{
		"approval beside pending findings": func() *state.Issue {
			st := approved("h1", "b1")
			st.PendingFindings = []string{"x"}
			return st
		},
		"approval beside blockers": func() *state.Issue {
			st := approved("h1", "b1")
			st.UnresolvedBlockers = []string{"x"}
			return st
		},
		"reviewed_sha is not head_sha": func() *state.Issue {
			st := approved("h1", "b1")
			st.HeadSHA = new("h2")
			return st
		},
		"unverified criterion": func() *state.Issue {
			st := approved("h1", "b1")
			st.Approval.ReviewEvidence.Criteria[0].Result = "unverified"
			return st
		},
		"behavior change without behavior evidence": func() *state.Issue {
			st := approved("h1", "b1")
			st.Approval.ReviewEvidence = evidence(true, coord.KindStatic)
			return st
		},
		"findings and blockers at once": func() *state.Issue {
			st := newIssue()
			st.PendingFindings, st.UnresolvedBlockers = []string{"a"}, []string{"b"}
			return st
		},
		"cycle above the cap": func() *state.Issue {
			st := newIssue()
			st.Cycle = 3
			return st
		},
		"two consecutive failures kept": func() *state.Issue {
			st := newIssue()
			st.ConsecutiveFailures = 2
			return st
		},
		"publish intent without approval": func() *state.Issue {
			st := newIssue()
			st.Publish = &state.Publish{SHA: "h1", PrevSHA: "", Base: "b1", Branch: "feat/issue-7", PR: 0, Phase: coord.PublishIntent}
			return st
		},
		"publish pushed on another sha": func() *state.Issue {
			st := approved("h1", "b1")
			st.Publish = &state.Publish{SHA: "h0", PrevSHA: "", Base: "b1", Branch: "feat/issue-7", PR: 0, Phase: coord.PublishPushed}
			return st
		},
	}
	for name, mk := range cases {
		if err := coord.Validate(mk()); exitcode.CodeOf(err) != exitcode.Refused {
			t.Errorf("%s: %v, want refused", name, err)
		}
	}
	linked := newIssue()
	linked.Publish = &state.Publish{SHA: "h0", PrevSHA: "", Base: "b1", Branch: "feat/issue-7", PR: 9, Phase: coord.PublishLinked}
	ok(t, coord.Validate(linked))
	ok(t, coord.Validate(approved("h1", "b1")))
}

func TestStartCreatesStateOnceWithTheWatermarkAtTheRead(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	before := w.human(child, "earlier context")
	st, err := w.session(token).Update(ctx(), child, coord.Start{Branch: ""})
	ok(t, err)
	if st.Branch != "feat/issue-7" || st.Cycle != 0 || st.HeadSHA != nil || st.Approval != nil || st.SignalWatermark != before {
		t.Errorf("state = %+v", st)
	}
	_, err = w.session(token).Update(ctx(), child, coord.Start{Branch: ""})
	wantCode(t, err, exitcode.Refused)
}

// TestTransitionsNeedAState: only start creates state; a decision never does.
func TestTransitionsNeedAState(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.human(child, "epic-retry")
	before := w.writes()
	for _, tr := range []coord.Transition{
		coord.ApplySignals{Standing: coord.StandingParked, Taken: nil},
		coord.Park{Blockers: []string{"x"}, Head: ""},
		coord.RecordHead{SHA: "h1"},
		coord.InvalidateApproval{},
	} {
		_, err := w.session(token).Update(ctx(), child, tr)
		wantCode(t, err, exitcode.Refused)
	}
	if w.writes() != before {
		t.Error("a transition created state")
	}
}

func report(status, head string) coord.Report {
	return coord.Report{Status: status, Issue: child, Branch: "feat/issue-7", Worktree: "/wt/7", HeadSHA: head, Error: "boom"}
}

func TestWorkerResults(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	st := approved("h0", "b0")
	st.ConsecutiveFailures = 1
	w.put(t, child, st)
	s := w.session(token)

	_, err := s.Update(ctx(), child, coord.WorkerResult{Report: report(coord.StatusDone, "h1"), Worktree: "/wt/other", QuestionKey: ""})
	wantCode(t, err, exitcode.Refused)

	got, err := w.session(token).Update(ctx(), child, coord.WorkerResult{Report: report(coord.StatusDone, "h1"), Worktree: "/wt/7", QuestionKey: ""})
	ok(t, err)
	if *got.HeadSHA != "h1" || got.Approval != nil || got.ConsecutiveFailures != 0 {
		t.Errorf("DONE = %+v", got)
	}

	_, err = w.session(token).Update(ctx(), child, coord.WorkerResult{Report: report(coord.StatusBlocked, ""), Worktree: "/wt/7", QuestionKey: "blocked:7:h1:abc"})
	wantCode(t, err, exitcode.Refused)
	_, err = w.session(token).PostNote(ctx(), child, "blocked:7:h1:abc", "質問")
	ok(t, err)
	_, err = w.session(token).Update(ctx(), child, coord.WorkerResult{Report: report(coord.StatusBlocked, ""), Worktree: "/wt/7", QuestionKey: "blocked:7:h1:abc"})
	ok(t, err)

	got, err = w.session(token).Update(ctx(), child, coord.WorkerResult{Report: report(coord.StatusFailed, ""), Worktree: "/wt/7", QuestionKey: ""})
	ok(t, err)
	if got.ConsecutiveFailures != 1 || len(got.UnresolvedBlockers) != 0 {
		t.Errorf("first FAILED = %+v", got)
	}
	got, err = w.session(token).Update(ctx(), child, coord.WorkerResult{Report: report(coord.StatusFailed, ""), Worktree: "/wt/7", QuestionKey: ""})
	ok(t, err)
	if got.ConsecutiveFailures != 0 || len(got.UnresolvedBlockers) != 1 || got.Cycle != 0 || *got.HeadSHA != "h1" {
		t.Errorf("second FAILED = %+v, want parked with cycle and head unchanged", got)
	}
}

// TestBeginFixNeedsAConfirmedReservationAndRespectsTheCap: no reservation, no fix; the third fix
// cycle is refused.
func TestBeginFixNeedsAConfirmedReservationAndRespectsTheCap(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	w.put(t, child, approved("h1", "b1"))

	_, err := w.session(token).Update(ctx(), child, coord.BeginFix{Findings: []string{"f"}, Grant: coord.Grant{}, Repair: nil})
	wantCode(t, err, exitcode.Refused)

	for cycle := 1; cycle <= 2; cycle++ {
		grant, _, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 1})
		ok(t, err)
		got, err := w.session(token).Update(ctx(), child, coord.BeginFix{Findings: []string{"f"}, Grant: grant, Repair: &state.Repair{PR: 3, Head: "h1", Since: 10}})
		ok(t, err)
		if got.Cycle != cycle || got.Approval != nil || len(got.PendingFindings) != 1 || got.Repair == nil {
			t.Errorf("cycle %d: %+v", cycle, got)
		}
	}
	grant, _, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 0, ReviewerPasses: 1, FixCycles: 0})
	ok(t, err)
	_, err = w.session(token).Update(ctx(), child, coord.BeginFix{Findings: []string{"f"}, Grant: grant, Repair: nil})
	wantCode(t, err, exitcode.Refused)
}

func TestBindApproval(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	st := newIssue()
	st.HeadSHA = new("h1")
	st.PendingFindings = []string{"old"}
	w.put(t, child, st)
	good := state.Approval{ReviewedSHA: "h1", VerifiedBase: "b1", ReviewEvidence: evidence(true, coord.KindBehavior, coord.KindStatic)}

	refusals := map[string]struct {
		t    coord.BindApproval
		code exitcode.Code
	}{
		"head moved":     {coord.BindApproval{Approval: good, Head: "h2", Base: "b1", Findings: nil}, exitcode.Stale},
		"base moved":     {coord.BindApproval{Approval: good, Head: "h1", Base: "b2", Findings: nil}, exitcode.Stale},
		"nit left":       {coord.BindApproval{Approval: good, Head: "h1", Base: "b1", Findings: []string{"nit"}}, exitcode.Refused},
		"no behavior":    {coord.BindApproval{Approval: state.Approval{ReviewedSHA: "h1", VerifiedBase: "b1", ReviewEvidence: evidence(true, coord.KindStatic)}, Head: "h1", Base: "b1", Findings: nil}, exitcode.Refused},
		"no criterion":   {coord.BindApproval{Approval: state.Approval{ReviewedSHA: "h1", VerifiedBase: "b1", ReviewEvidence: evidence(false)}, Head: "h1", Base: "b1", Findings: nil}, exitcode.Refused},
		"secret in text": {coord.BindApproval{Approval: secretApproval(), Head: "h1", Base: "b1", Findings: nil}, exitcode.Refused},
	}
	before := w.writes()
	for name, c := range refusals {
		_, err := w.session(token).Update(ctx(), child, c.t)
		if exitcode.CodeOf(err) != c.code {
			t.Errorf("%s: %v, want %d", name, err, c.code)
		}
	}
	if w.writes() != before {
		t.Error("a refused binding was written")
	}
	got, err := w.session(token).Update(ctx(), child, coord.BindApproval{Approval: good, Head: "h1", Base: "b1", Findings: nil})
	ok(t, err)
	if got.Approval == nil || got.Approval.ReviewedSHA != "h1" || len(got.PendingFindings) != 0 {
		t.Errorf("bound = %+v", got)
	}
	got, err = w.session(token).Update(ctx(), child, coord.InvalidateApproval{})
	ok(t, err)
	if got.Approval != nil {
		t.Error("approval kept")
	}
	_, err = w.session(token).Update(ctx(), child, coord.InvalidateApproval{})
	wantCode(t, err, exitcode.Refused)
}

func secretApproval() state.Approval {
	ev := evidence(false, coord.KindStatic)
	ev.Criteria[0].Evidence = "AKIA" + strings.Repeat("A", 16)
	return state.Approval{ReviewedSHA: "h1", VerifiedBase: "b1", ReviewEvidence: ev}
}

// TestStateWithASuspectedSecretIsNeverWritten: a state body is scanned before any request, so a
// blocker that quotes a secret is refused and nothing is published.
func TestStateWithASuspectedSecretIsNeverWritten(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, newIssue())
	before := w.writes()
	_, err := w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"CI log: AKIA" + strings.Repeat("B", 16)}, Head: ""})
	wantCode(t, err, exitcode.Refused)
	if w.writes() != before || strings.Contains(err.Error(), "AKIA") {
		t.Errorf("writes %d, err %v", w.writes()-before, err)
	}
}

func TestParkAndRecordHead(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, approved("h1", "b1"))
	got, err := w.session(token).Update(ctx(), child, coord.RecordHead{SHA: "h2"})
	ok(t, err)
	if *got.HeadSHA != "h2" || got.Approval != nil {
		t.Errorf("record_head = %+v", got)
	}
	got, err = w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"ship-class question"}, Head: ""})
	ok(t, err)
	if len(got.UnresolvedBlockers) != 1 || len(got.PendingFindings) != 0 {
		t.Errorf("park = %+v", got)
	}
	_, err = w.session(token).Update(ctx(), child, coord.Park{Blockers: nil, Head: ""})
	wantCode(t, err, exitcode.Refused)
}

// TestStateEditStopsWhenTheRevisionMoved: a write after another writer moved the revision since
// the read exits 7 and writes nothing.
func TestStateEditStopsWhenTheRevisionMoved(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	id := w.put(t, child, newIssue())
	reads := 0
	w.r.On(ghfake.CommentsName, func(v map[string]string) string {
		out := w.storeComments(v)
		if strings.Contains(v["query"], "i7:") {
			reads++
			if reads == 1 {
				moved := newIssue()
				moved.Revision = 2
				moved.UpdatedBy = "another"
				w.store.Edit(id, mustBody(moved))
			}
		}
		return out
	})
	before := w.writes()
	_, err := w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"x"}, Head: ""})
	wantCode(t, err, exitcode.Coordination)
	if w.writes() != before {
		t.Error("a write ran over a moved revision")
	}
}

// TestStateEditWhoseResponseWasLostCountsAsDone: an edit that landed but failed is confirmed by
// re-reading, contract §8.
func TestStateEditWhoseResponseWasLostCountsAsDone(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, newIssue())
	w.store.OnWrite(func(_ *ghfake.Store, wr ghfake.Write) (int, bool) {
		if wr.Method == http.MethodPatch && strings.Contains(wr.Body, "issue:7") {
			return 1, true
		}
		return 0, true
	})
	_, err := w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"x"}, Head: ""})
	ok(t, err)
	if got := w.issue(t, child); len(got.UnresolvedBlockers) != 1 || got.Revision != 2 {
		t.Errorf("state = %+v", got)
	}
}

func TestStateEditThatDidNotLandFails(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, newIssue())
	w.store.OnWrite(func(_ *ghfake.Store, wr ghfake.Write) (int, bool) {
		if strings.Contains(wr.Body, "issue:7") {
			return 1, false
		}
		return 0, true
	})
	_, err := w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"x"}, Head: ""})
	wantCode(t, err, exitcode.Unreadable)
	if got := w.issue(t, child); len(got.UnresolvedBlockers) != 0 {
		t.Error("the failed write is visible")
	}
}

// TestDuplicateStateStops: two state comments for one key stop every transition with exit 6.
func TestDuplicateStateStops(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, newIssue())
	w.put(t, child, newIssue())
	_, err := w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"x"}, Head: ""})
	wantCode(t, err, exitcode.Protocol)
}

// TestTransitionThatChangesNothingWritesNothing keeps re-runs idempotent.
func TestTransitionThatChangesNothingWritesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	st := newIssue()
	st.HeadSHA = new("h1")
	w.put(t, child, st)
	before := w.writes()
	_, err := w.session(token).Update(ctx(), child, coord.RecordHead{SHA: "h1"})
	ok(t, err)
	if w.writes() != before {
		t.Error("an unchanged state was written")
	}
}
