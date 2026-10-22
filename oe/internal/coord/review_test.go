package coord_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/review"
	"github.com/maro114510/skills/oe/internal/state"
)

const (
	pinBase  = "fedcba9876543210fedcba9876543210fedcba98"
	nextBase = "1111111111111111111111111111111111111111"
)

func reviewText(verdict, behavior, criteria, findings string) string {
	return "VERDICT: " + verdict + "\nREPO: o/r\nISSUE: #7\nBRANCH: feat/issue-7\nREVIEWED_HEAD: " + head +
		"\nREVIEWED_BASE: " + pinBase + "\nCHECKS_REVISION: " + pinBase + "\nBEHAVIOR_CHANGE: " + behavior +
		"\nCRITERIA:\n" + criteria + "\nCHECKS:\n1. go test ./... -> exit 0\nFINDINGS:\n" + findings + "\n"
}

const goodCriterion = "1. pin merges the base -> verified [behavior] — ran TestPin, exit 0"

func cleanApprove() string {
	return reviewText("APPROVE", "yes — new subcommand", goodCriterion, "none")
}

// verdictOn is the verdict on a clean worktree at the recorded head while the pinned base is still the default branch.
func verdictOn(t *testing.T, text string) coord.Verdict {
	t.Helper()
	rep, err := review.Parse(text)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return coord.Verdict{
		Report: rep, Repo: "o/r", Head: head, Base: pinBase, Integrated: true, ChecksRevision: pinBase, Runnable: 1,
		Dirty: nil, ShipClass: nil,
	}
}

// reviewWorld is an Epic with a ledger and an Issue whose DONE head is recorded at the given cycle.
func reviewWorld(t *testing.T, cycle int) (*world, string) {
	t.Helper()
	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	st := newIssue()
	st.HeadSHA, st.Cycle = new(head), cycle
	w.put(t, child, st)
	return w, token
}

func wantReview(t *testing.T, what string, res coord.ReviewResult, route, next string) {
	t.Helper()
	if res.Route != route || res.Next != next {
		t.Fatalf("%s: route %s, next %s (%s); want %s, %s", what, res.Route, res.Next, res.Reason, route, next)
	}
}

func TestCleanApproveBindsThePinnedPairAndItsEvidence(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, cleanApprove()))
	ok(t, err)
	wantReview(t, "clean APPROVE", res, coord.RouteBound, coord.NextShip)
	a := w.current(t).Approval
	if a == nil || a.ReviewedSHA != head || a.VerifiedBase != pinBase || a.ReviewEvidence.Criteria[0].Text != "pin merges the base" ||
		a.ReviewEvidence.Criteria[0].Evidence != "ran TestPin, exit 0" || !a.ReviewEvidence.BehaviorChange {
		t.Errorf("approval = %+v", a)
	}
}

// TestUncommittedDiffApprovalDrift shows that with HEAD unchanged, uncommitted changes, untracked files, and tracked files a check modified bind nothing.
// They become a blocking finding for a fix cycle.
func TestUncommittedDiffApprovalDrift(t *testing.T) {
	t.Parallel()

	for name, dirty := range map[string][]string{
		"untracked file":          {"new.go"},
		"check-modified tracked":  {"go.sum"},
		"staged and worktree mix": {"a.go", "b.go"},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w, token := reviewWorld(t, 0)
			v := verdictOn(t, cleanApprove())
			v.Dirty = dirty
			res, err := w.session(token).Verdict(ctx(), child, v)
			ok(t, err)
			wantReview(t, name, res, coord.RouteFix, coord.NextRedispatch)
			st := w.current(t)
			if st.Approval != nil || st.Cycle != 1 || !strings.Contains(st.PendingFindings[0], dirty[0]) {
				t.Errorf("state = %+v", st)
			}
		})
	}
}

// TestApproveWithANitBindsNothing shows that an APPROVE that carries any nit starts a fix cycle.
func TestApproveWithANitBindsNothing(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, reviewText("APPROVE", "yes — x", goodCriterion, "1. [nit] a.go:1 — typo")))
	ok(t, err)
	wantReview(t, "nit", res, coord.RouteFix, coord.NextRedispatch)
	if st := w.current(t); st.Approval != nil || st.PendingFindings[0] != "[nit] a.go:1 — typo" {
		t.Errorf("state = %+v", st)
	}
	if l := w.ledger(t); l.Counters.FixCycles.Used != 1 {
		t.Errorf("fix cycles used = %d, want 1", l.Counters.FixCycles.Used)
	}
}

// TestBehaviorChangeWithoutBehaviorEvidenceIsAFixCycle shows that validation failures go down the fix-cycle path as blocking findings, exactly like the reviewer's own.
func TestBehaviorChangeWithoutBehaviorEvidenceIsAFixCycle(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	text := reviewText("APPROVE", "yes — x", "1. pin merges -> verified [static] — CHECKS_SET green", "none")
	res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, text))
	ok(t, err)
	wantReview(t, "static only", res, coord.RouteFix, coord.NextRedispatch)
	if st := w.current(t); st.Approval != nil || !strings.Contains(strings.Join(st.PendingFindings, "\n"), "[behavior] evidence") {
		t.Errorf("state = %+v", st)
	}
}

// TestFixCycleCapParks shows that at cycle 2 no third fix cycle starts and nothing is reserved.
// The findings park the Issue with a note, an unverifiable criterion included.
func TestFixCycleCapParks(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, coord.MaxCycle)
	text := reviewText("APPROVE", "no — docs", "1. docs exist -> unverified — missing: a rendered page", "none")
	res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, text))
	ok(t, err)
	wantReview(t, "cap", res, coord.RouteParked, coord.NextParked)
	st := w.current(t)
	if st.Cycle != coord.MaxCycle || len(st.UnresolvedBlockers) == 0 || !strings.Contains(st.UnresolvedBlockers[0], "unverified") {
		t.Errorf("state = %+v", st)
	}
	if len(w.prefixed("parked:7:cap:")) != 1 || w.ledger(t).Counters.FixCycles.Used != 0 {
		t.Error("the cap parked without its note, or reserved a fix cycle")
	}
}

// TestShipClassFindingParksImmediately shows that a finding the Publisher judged ship-class never enters a fix cycle, and a secret's text is never posted.
func TestShipClassFindingParksImmediately(t *testing.T) {
	t.Parallel()

	for _, kind := range []handoff.ShipClass{handoff.ShipScope, handoff.ShipSecret} {
		w, token := reviewWorld(t, 0)
		v := verdictOn(t, reviewText("REQUEST_CHANGES", "no — x", goodCriterion, "1. [blocking] adds an unrequested flag"))
		v.ShipClass = []handoff.ShipClass{kind}
		res, err := w.session(token).Verdict(ctx(), child, v)
		ok(t, err)
		wantReview(t, string(kind), res, coord.RouteParked, coord.NextParked)
		notes := w.prefixed("ship-class:7:" + string(kind))
		if len(notes) != 1 || w.current(t).Cycle != 0 || w.ledger(t).Counters.FixCycles.Used != 0 {
			t.Errorf("%s: notes %d, cycle %d", kind, len(notes), w.current(t).Cycle)
		}
		if quoted := strings.Contains(notes[0].Body, "unrequested flag"); quoted != (kind != handoff.ShipSecret) {
			t.Errorf("%s: finding quoted = %v", kind, quoted)
		}
	}
}

// TestReportForAnotherPairRunsAStalenessPass shows that a report for another dispatch or pair, or a pair that moved since the pin, binds nothing.
// It starts no fix cycle, since the worker has nothing to fix.
func TestReportForAnotherPairRunsAStalenessPass(t *testing.T) {
	t.Parallel()

	other := strings.Repeat("9", 40)
	cases := map[string]func(*coord.Verdict){
		"REVIEWED_HEAD differs": func(v *coord.Verdict) { v.Report.ReviewedHead = other },
		"REVIEWED_HEAD missing": func(v *coord.Verdict) { v.Report.ReviewedHead = "" },
		"base moved":            func(v *coord.Verdict) { v.Base, v.ChecksRevision = nextBase, nextBase },
		"base not integrated":   func(v *coord.Verdict) { v.Integrated = false },
		"another branch":        func(v *coord.Verdict) { v.Report.Branch = "feat/issue-8" },
		"another Issue":         func(v *coord.Verdict) { v.Report.Issue = 8 },
		"another repository":    func(v *coord.Verdict) { v.Report.Repo = "o/x" },
		"old CHECKS_SET":        func(v *coord.Verdict) { v.ChecksRevision = other },
		"CHECKS_REVISION wrong": func(v *coord.Verdict) { v.Report.ChecksRevision = other },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w, token := reviewWorld(t, 1)
			v := verdictOn(t, cleanApprove())
			mutate(&v)
			res, err := w.session(token).Verdict(ctx(), child, v)
			ok(t, err)
			wantReview(t, name, res, coord.RouteStale, coord.NextReverify)
			if st := w.current(t); st.Approval != nil || st.Cycle != 1 || len(st.PendingFindings) != 0 {
				t.Errorf("state = %+v", st)
			}
		})
	}
}

// TestStaleVerdictIsCommentedOncePerPairAndDefersTheSecondTime shows that a published Issue gets one stale note per pair however often the pair is seen.
//   - The first staleness in a session re-verifies.
//   - A second one defers the Issue, which stays in progress.
//   - The next session re-verifies it afresh.
func TestStaleVerdictIsCommentedOncePerPairAndDefersTheSecondTime(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	st := newIssue()
	st.HeadSHA = new(head)
	st.Publish = &state.Publish{SHA: head, PrevSHA: "", Base: pinBase, Branch: "feat/issue-7", PR: 12, Phase: coord.PublishLinked}
	w.put(t, child, st)
	stale := func(token string) coord.ReviewResult {
		v := verdictOn(t, cleanApprove())
		v.Base, v.ChecksRevision = nextBase, nextBase
		res, err := w.session(token).Verdict(ctx(), child, v)
		ok(t, err)
		return res
	}
	if res := stale(token); res.Next != coord.NextReverify {
		t.Fatalf("first: %+v", res)
	}
	if res := stale(token); res.Next != coord.NextDefer {
		t.Fatalf("second in the session: %+v", res)
	}
	got := w.current(t)
	if len(got.UnresolvedBlockers) != 0 || len(got.PendingFindings) != 0 || got.Approval != nil {
		t.Errorf("a deferred Issue must stay in progress: %+v", got)
	}
	if n := len(w.prefixed("stale:7:" + head + ":" + nextBase)); n != 1 {
		t.Errorf("stale notes for the pair = %d, want 1", n)
	}
	next := w.acquireAfterEnd(t, token)
	if res := stale(next); res.Next != coord.NextReverify {
		t.Errorf("a new session: %+v", res)
	}
	if n := len(w.prefixed("stale:7:")); n != 1 {
		t.Errorf("stale notes = %d, want 1", n)
	}
}

// acquireAfterEnd ends the session holding token and starts a new one.
func (w *world) acquireAfterEnd(t *testing.T, token string) string {
	t.Helper()
	if _, err := w.session(token).End(ctx()); err != nil {
		t.Fatalf("end: %v", err)
	}
	return w.acquire(t)
}

// TestSecretInTheEvidenceParksWithoutStoringIt shows that evidence is scanned before it is stored, and a suspected secret parks the Issue without being published.
func TestSecretInTheEvidenceParksWithoutStoringIt(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	secret := "AKIA" + strings.Repeat("C", 16)
	text := reviewText("APPROVE", "yes — x", "1. pin merges -> verified [behavior] — token "+secret, "none")
	res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, text))
	ok(t, err)
	wantReview(t, "secret", res, coord.RouteParked, coord.NextParked)
	for _, c := range w.store.Comments(child) {
		if strings.Contains(c.Body, secret) {
			t.Fatal("the secret was published")
		}
	}
}

// TestVerdictOnADivergedHeadWritesNothing shows that a worktree HEAD other than the recorded head is a divergence for a person and never a review.
func TestVerdictOnADivergedHeadWritesNothing(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	v := verdictOn(t, cleanApprove())
	v.Head = strings.Repeat("8", 40)
	before := w.writes()
	_, err := w.session(token).Verdict(ctx(), child, v)
	wantCode(t, err, exitcode.Refused)
	if w.writes() != before {
		t.Error("a diverged head wrote")
	}
}

// TestFixCycleIsReservedFirst shows that a frozen Epic starts no fix cycle and writes no findings.
func TestFixCycleIsReservedFirst(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	_, err := w.session(token).Freeze(ctx(), "test", "", "")
	wantCode(t, err, exitcode.Stop)
	_, err = w.session(token).Verdict(ctx(), child, verdictOn(t, reviewText("APPROVE", "yes — x", goodCriterion, "1. [nit] typo")))
	wantCode(t, err, exitcode.Stop)
	if st := w.current(t); st.Cycle != 0 || len(st.PendingFindings) != 0 {
		t.Errorf("state = %+v", st)
	}
}

// current is the Issue's state as the store holds it.
func (w *world) current(t *testing.T) state.Issue {
	t.Helper()
	var st state.Issue
	if !w.stateOf(t, child, state.IssueKey(child), &st) {
		t.Fatal("#7 has no state")
	}
	return st
}

// TestRenewedVerdictNeverInheritsTheOldEvidence shows that a staleness pass clears the bound approval with its evidence, and a later verdict binds its own evidence for the new pair.
func TestRenewedVerdictNeverInheritsTheOldEvidence(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	w.put(t, child, approved(head, pinBase))
	res := coord.NewReviewResult(child)
	ok(t, w.session(token).Stale(ctx(), child, head, nextBase, "the default branch moved", &res))
	if st := w.current(t); st.Approval != nil || res.Next != coord.NextReverify {
		t.Fatalf("after the staleness pass: %+v, next %s", st.Approval, res.Next)
	}
	v := verdictOn(t, strings.ReplaceAll(cleanApprove(), pinBase, nextBase))
	v.Base, v.ChecksRevision = nextBase, nextBase
	got, err := w.session(token).Verdict(ctx(), child, v)
	ok(t, err)
	if a := got.State.Approval; a == nil || a.VerifiedBase != nextBase || a.ReviewEvidence.Criteria[0].Text != "pin merges the base" {
		t.Errorf("renewed approval = %+v", a)
	}
}

// TestReplayedFindingsStartNoSecondFixCycle shows that running the same verdict again, as a resumed session does after begin_fix landed, charges no second fix cycle.
func TestReplayedFindingsStartNoSecondFixCycle(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	text := reviewText("APPROVE", "yes — x", goodCriterion, "1. [nit] a.go:1 — typo")
	for range 2 {
		res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, text))
		ok(t, err)
		wantReview(t, "replay", res, coord.RouteFix, coord.NextRedispatch)
	}
	if st, l := w.current(t), w.ledger(t); st.Cycle != 1 || l.Counters.FixCycles.Used != 1 {
		t.Errorf("cycle %d, fix cycles used %d; want 1 and 1", st.Cycle, l.Counters.FixCycles.Used)
	}
}

// TestStaleNoteNeverQuotesASecretFromTheReport shows that when the scan refuses a stale reason that quotes the report, the note goes without it and the pass goes on.
func TestStaleNoteNeverQuotesASecretFromTheReport(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	st := newIssue()
	st.HeadSHA = new(head)
	st.Publish = &state.Publish{SHA: head, PrevSHA: "", Base: pinBase, Branch: "feat/issue-7", PR: 12, Phase: coord.PublishLinked}
	w.put(t, child, st)
	secret := "AKIA" + strings.Repeat("D", 16)
	v := verdictOn(t, cleanApprove())
	v.Report.ReviewedHead = secret
	res, err := w.session(token).Verdict(ctx(), child, v)
	ok(t, err)
	wantReview(t, "secret head", res, coord.RouteStale, coord.NextReverify)
	if len(w.prefixed("stale:7:")) != 1 || w.current(t).StalePass == "" {
		t.Error("the staleness pass did not run")
	}
	for _, c := range w.store.Comments(child) {
		if strings.Contains(c.Body, secret) {
			t.Fatal("the secret was published")
		}
	}
}

// TestSameFindingsAfterAWorkerResultCountAgainstTheCap shows that a DONE report ends the fix cycle in flight even when nothing changed.
// The same findings on the same head then start the next cycle and park the Issue at the cap.
func TestSameFindingsAfterAWorkerResultCountAgainstTheCap(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	text := reviewText("APPROVE", "yes — x", goodCriterion, "1. [nit] a.go:1 — typo")
	done := coord.Report{Status: coord.StatusDone, Issue: child, Branch: "feat/issue-7", Worktree: wt, HeadSHA: head, Error: ""}
	want := []string{coord.RouteFix, coord.RouteFix, coord.RouteParked}
	for i, route := range want {
		res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, text))
		ok(t, err)
		if res.Route != route {
			t.Fatalf("review %d: route %s, want %s", i+1, res.Route, route)
		}
		if route == coord.RouteFix {
			_, err = w.session(token).Update(ctx(), child, coord.WorkerResult{Report: done, Worktree: wt, QuestionKey: ""})
			ok(t, err)
		}
	}
	if st := w.current(t); st.Cycle != coord.MaxCycle || len(st.UnresolvedBlockers) == 0 {
		t.Errorf("state = %+v", st)
	}
}

// TestSecretFindingsNeverReachThePayload shows that findings holding a suspected secret are withheld from the result the command prints, as from the note and the state.
func TestSecretFindingsNeverReachThePayload(t *testing.T) {
	t.Parallel()

	w, token := reviewWorld(t, 0)
	secret := "AKIA" + strings.Repeat("E", 16)
	res, err := w.session(token).Verdict(ctx(), child, verdictOn(t, reviewText("REQUEST_CHANGES", "no — x", goodCriterion, "1. [blocking] key "+secret)))
	ok(t, err)
	wantReview(t, "secret finding", res, coord.RouteParked, coord.NextParked)
	raw, err := json.Marshal(res)
	ok(t, err)
	if strings.Contains(string(raw), secret) {
		t.Errorf("payload holds the secret: %s", raw)
	}
}
