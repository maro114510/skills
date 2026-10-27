package round_test

import (
	"encoding/json"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/round"
)

func action(kind string, issue int) board.Action {
	return board.Action{Kind: kind, Issue: issue, Branch: "", PR: 0, Head: "", Resume: false, Merge: "", Health: "", Reason: ""}
}

func dispatch(issue int, resume bool) board.Action {
	a := action(board.ActionDispatch, issue)
	a.Branch, a.Resume = branchOf(issue), resume
	return a
}

func land(issue int) board.Action {
	a := action(board.ActionLand, issue)
	a.PR, a.Branch, a.Head = issue+100, branchOf(issue), "head"+branchOf(issue)
	return a
}

func reverify(issue int) board.Action {
	a := action(board.ActionReverify, issue)
	a.PR, a.Branch = issue+100, branchOf(issue)
	return a
}

func branchOf(issue int) string { return "feat/issue-" + strconv.Itoa(issue) }

func schedule(maxParallel int, deferred map[int]round.Reason, fix map[int]bool, actions ...board.Action) round.Plan {
	var res board.Result
	res.Actions = actions
	return round.Schedule(round.Input{
		Board:       res,
		FixInFlight: fix,
		MaxParallel: maxParallel,
		Deferred:    deferred,
	})
}

func issues(items []round.Item) []int {
	out := make([]int, 0, len(items))
	for _, it := range items {
		out = append(out, it.Issue)
	}
	return out
}

func TestIssuesInFlightStartBeforeReadyOnesAndTheCapLeavesTheRestOut(t *testing.T) {
	t.Parallel()

	plan := schedule(3, nil, nil, dispatch(9, false), dispatch(6, true), dispatch(2, false), dispatch(4, true))

	if got, want := issues(plan.Work), []int{4, 6, 2}; !reflect.DeepEqual(got, want) {
		t.Fatalf("work = %v, want %v: in-progress 4 and 6 first, then the lowest ready Issue 2", got, want)
	}
	if want := []int{9}; !reflect.DeepEqual(plan.LeftOut, want) {
		t.Errorf("left_out = %v, want %v", plan.LeftOut, want)
	}
	if !plan.Work[0].Resume || plan.Work[2].Resume {
		t.Errorf("resume flags = %v, %v, %v; want true for in-progress and false for ready", plan.Work[0].Resume, plan.Work[1].Resume, plan.Work[2].Resume)
	}
	if plan.MaxParallel != 3 {
		t.Errorf("max_parallel = %d, want 3", plan.MaxParallel)
	}
}

func TestAnInFlightIssueBeyondTheCapIsLeftOutToo(t *testing.T) {
	t.Parallel()

	plan := schedule(1, nil, nil, dispatch(6, true), dispatch(4, true), dispatch(2, false))

	if got, want := issues(plan.Work), []int{4}; !reflect.DeepEqual(got, want) {
		t.Errorf("work = %v, want %v", got, want)
	}
	if want := []int{6, 2}; !reflect.DeepEqual(plan.LeftOut, want) {
		t.Errorf("left_out = %v, want %v: every Issue the cap left out is reported", plan.LeftOut, want)
	}
}

func TestAReviewerTakesOneSlotAndLeadsTheBatch(t *testing.T) {
	t.Parallel()

	plan := schedule(2, nil, nil, dispatch(4, true), dispatch(2, false), reverify(5))

	want := []round.Item{
		{Kind: round.KindReverify, Issue: 5, Branch: "feat/issue-5", PR: 105, Resume: false, FixInFlight: false},
		{Kind: round.KindDispatch, Issue: 4, Branch: "feat/issue-4", PR: 0, Resume: true, FixInFlight: false},
	}
	if !reflect.DeepEqual(plan.Work, want) {
		t.Errorf("work = %+v, want %+v", plan.Work, want)
	}
	if want := []int{2}; !reflect.DeepEqual(plan.LeftOut, want) {
		t.Errorf("left_out = %v, want %v", plan.LeftOut, want)
	}
}

func TestOnlyTheFirstStaleCandidateHasItsTurn(t *testing.T) {
	t.Parallel()

	plan := schedule(5, nil, nil, reverify(8), reverify(5), reverify(6))

	if got, want := issues(plan.Work), []int{5}; !reflect.DeepEqual(got, want) {
		t.Errorf("work = %v, want %v: one stale candidate is re-verified at a time", got, want)
	}
	if want := []int{6, 8}; !reflect.DeepEqual(plan.StaleWaiting, want) {
		t.Errorf("stale_waiting = %v, want %v", plan.StaleWaiting, want)
	}
	if want := []round.Candidate{{Issue: 5, PR: 105, Head: "", Stale: true}}; !reflect.DeepEqual(plan.Landing, want) {
		t.Errorf("landing = %+v, want %+v", plan.Landing, want)
	}
}

func TestACandidateThatGaveUpItsTurnYieldsToTheNextStaleOne(t *testing.T) {
	t.Parallel()

	plan := schedule(5, map[int]round.Reason{5: round.ReasonTurn}, nil, reverify(5), reverify(6), reverify(8))

	if got, want := issues(plan.Work), []int{6}; !reflect.DeepEqual(got, want) {
		t.Errorf("work = %v, want %v", got, want)
	}
	if want := []int{8}; !reflect.DeepEqual(plan.StaleWaiting, want) {
		t.Errorf("stale_waiting = %v, want %v", plan.StaleWaiting, want)
	}
	if want := []round.Deferral{{Issue: 5, Reason: round.ReasonTurn}}; !reflect.DeepEqual(plan.Deferred, want) {
		t.Errorf("deferred = %+v, want %+v", plan.Deferred, want)
	}
}

func TestDeferredIssuesAreSkippedInEveryGroup(t *testing.T) {
	t.Parallel()

	deferred := map[int]round.Reason{3: round.ReasonBlocked, 4: round.ReasonStale}
	plan := schedule(5, deferred, nil, dispatch(3, true), land(4), dispatch(7, false), land(9))

	if got, want := issues(plan.Work), []int{7}; !reflect.DeepEqual(got, want) {
		t.Errorf("work = %v, want %v", got, want)
	}
	if want := []round.Candidate{{Issue: 9, PR: 109, Head: "headfeat/issue-9", Stale: false}}; !reflect.DeepEqual(plan.Landing, want) {
		t.Errorf("landing = %+v, want %+v", plan.Landing, want)
	}
	if want := []round.Deferral{{Issue: 3, Reason: round.ReasonBlocked}, {Issue: 4, Reason: round.ReasonStale}}; !reflect.DeepEqual(plan.Deferred, want) {
		t.Errorf("deferred = %+v, want %+v", plan.Deferred, want)
	}
}

func TestADeferralOfAnIssueTheBoardDoesNotProposeIsNotReported(t *testing.T) {
	t.Parallel()

	plan := schedule(5, map[int]round.Reason{3: round.ReasonBlocked}, nil, dispatch(7, false))

	if got, want := issues(plan.Work), []int{7}; !reflect.DeepEqual(got, want) {
		t.Fatalf("work = %v, want %v", got, want)
	}
	if len(plan.Deferred) != 0 {
		t.Errorf("deferred = %+v, want none: Issue 3 was not proposed", plan.Deferred)
	}
}

func TestLandingIsInAscendingIssueNumberWithTheStaleCandidateAmongTheFreshOnes(t *testing.T) {
	t.Parallel()

	plan := schedule(5, nil, nil, land(9), land(3), reverify(6))

	got := make([]int, 0, len(plan.Landing))
	for _, c := range plan.Landing {
		got = append(got, c.Issue)
	}
	if want := []int{3, 6, 9}; !reflect.DeepEqual(got, want) {
		t.Fatalf("landing order = %v, want %v", got, want)
	}
	if !plan.Landing[1].Stale || plan.Landing[0].Stale || plan.Landing[2].Stale {
		t.Errorf("stale flags = %v %v %v, want only Issue 6", plan.Landing[0].Stale, plan.Landing[1].Stale, plan.Landing[2].Stale)
	}
}

func TestAFixCutOffByARestartIsADispatchAndNotAReverification(t *testing.T) {
	t.Parallel()

	plan := schedule(5, nil, map[int]bool{5: true}, reverify(5), dispatch(2, false), dispatch(4, true))

	want := []round.Item{
		{Kind: round.KindDispatch, Issue: 4, Branch: "feat/issue-4", PR: 0, Resume: true, FixInFlight: false},
		{Kind: round.KindDispatch, Issue: 5, Branch: "feat/issue-5", PR: 105, Resume: true, FixInFlight: true},
		{Kind: round.KindDispatch, Issue: 2, Branch: "feat/issue-2", PR: 0, Resume: false, FixInFlight: false},
	}
	if !reflect.DeepEqual(plan.Work, want) {
		t.Errorf("work = %+v, want %+v", plan.Work, want)
	}
	if len(plan.Landing) != 0 || len(plan.StaleWaiting) != 0 {
		t.Errorf("landing %+v and stale_waiting %v, want none while a fix is in flight", plan.Landing, plan.StaleWaiting)
	}
}

func TestSignalsAndAFreezePassThrough(t *testing.T) {
	t.Parallel()

	freeze := action(board.ActionFreeze, 0)
	freeze.Merge, freeze.Health, freeze.Reason = "mergesha", "FAIL", "a check failed"
	plan := schedule(3, nil, nil, action(board.ActionApplySignals, 3), action(board.ActionApplySignals, 1), freeze)

	if want := []int{1, 3}; !reflect.DeepEqual(plan.Signals, want) {
		t.Errorf("signals = %v, want %v", plan.Signals, want)
	}
	if plan.Freeze == nil || plan.Freeze.Merge != "mergesha" {
		t.Errorf("freeze = %+v, want the proposed freeze", plan.Freeze)
	}
	if len(plan.Work) != 0 || len(plan.Landing) != 0 {
		t.Errorf("work %+v and landing %+v, want none: the board proposed no work", plan.Work, plan.Landing)
	}
}

func TestEveryListIsAnEmptyListWhenThereIsNothingSoItNeverPrintsAsNull(t *testing.T) {
	t.Parallel()

	plan := schedule(3, nil, nil)

	data, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"signals", "work", "landing", "stale_waiting", "left_out", "deferred"} {
		if want := `"` + field + `":[]`; !strings.Contains(string(data), want) {
			t.Errorf("%s: plan %s has no %s", field, data, want)
		}
	}
	if !strings.Contains(string(data), `"freeze":null`) {
		t.Errorf("plan %s should print a missing freeze as null", data)
	}
}
