package board_test

import (
	"slices"
	"testing"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/state"
)

const handMade = "feat/issue-1-hand-made"

// The loop names its branches feat/issue-<n>, but a person working an Issue by hand names them
// feat/issue-<n>-<slug>. With no branch recorded in the Issue's state, that work is the Issue's:
// dispatching a worker beside it would put two writers on one Issue.

func TestAHandMadeOpenPRKeepsTheIssueFromBeingDispatched(t *testing.T) {
	t.Parallel()

	res := classify(t, newFx().with(leaf(1, "OPEN")).pr(9, handMade, "OPEN", headSHA))
	i := find(t, res, 1)
	if i.State != board.Reverify || i.PR != 9 || i.Branch != handMade {
		t.Fatalf("Issue = %+v, want reverify of PR 9 on %s", i, handMade)
	}
	if got := actionsOf(res, board.ActionDispatch); len(got) != 0 {
		t.Errorf("dispatch = %v, want none beside a person's open PR", got)
	}
}

func TestAHandMadeBranchWithoutAPRIsInProgress(t *testing.T) {
	t.Parallel()

	res := classify(t, newFx().with(leaf(1, "OPEN")).branch(handMade))
	i := find(t, res, 1)
	if i.State != board.InProgress || i.Branch != handMade {
		t.Fatalf("Issue = %+v, want in-progress on %s", i, handMade)
	}
	if len(res.Actions) != 1 || !res.Actions[0].Resume || res.Actions[0].Branch != handMade {
		t.Errorf("actions = %+v, want one resume on %s", res.Actions, handMade)
	}
}

func TestAHandMadeMergedPRParksTheIssue(t *testing.T) {
	t.Parallel()

	res := classify(t, newFx().with(leaf(1, "OPEN")).pr(9, handMade, "MERGED", headSHA))
	if i := find(t, res, 1); i.State != board.Parked || i.MergedPR != 9 {
		t.Fatalf("Issue = %+v, want parked with merged PR 9", i)
	}
	if keys := noteKeys(res); !slices.Equal(keys, []string{"merged-open:1:9"}) {
		t.Errorf("notes = %v, want merged-open:1:9", keys)
	}
}

func TestAHandMadeClosedPRRejectsTheIssue(t *testing.T) {
	t.Parallel()

	if got := stateOf(t, newFx().with(leaf(1, "OPEN")).pr(9, handMade, "CLOSED", headSHA), 1); got != board.Rejected {
		t.Errorf("state = %s, want rejected", got)
	}
}

// TestARecordedBranchIsMatchedExactly: once the state records a branch, as an applied redo does,
// only that branch is the Issue's, so the old hand-made one is left behind.
func TestARecordedBranchIsMatchedExactly(t *testing.T) {
	t.Parallel()

	st := newState(1)
	st.Branch = "feat/issue-1-2"
	f := newFx().with(leaf(1, "OPEN")).state(1, st).pr(7, handMade, "CLOSED", headSHA).branch(handMade)
	i := find(t, classify(t, f), 1)
	if i.State != board.InProgress || i.Branch != "feat/issue-1-2" {
		t.Errorf("Issue = %+v, want in-progress on the recorded feat/issue-1-2", i)
	}
}

// TestAnotherIssuesBranchIsNotMatched: #12 and #123 are not #1.
func TestAnotherIssuesBranchIsNotMatched(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN")).pr(9, "feat/issue-12-x", "OPEN", headSHA).pr(10, "feat/issue-123", "OPEN", headSHA).
		branch("feat/issue-12-x", "feat/issue-123")
	if got := stateOf(t, f, 1); got != board.Ready {
		t.Errorf("state = %s, want ready: no branch of #1 exists", got)
	}
}

// A dependency cycle holds the work an Issue would start or land. It does not hide what waits
// on a person: a rejected or parked Issue keeps its state, and its note.

func TestACycleKeepsRejectedAndParkedIssuesAsTheyAre(t *testing.T) {
	t.Parallel()

	f := newFx().with(
		leaf(1, "OPEN", blocker(2, "OPEN")), leaf(2, "OPEN", blocker(1, "OPEN")),
		leaf(3, "OPEN", blocker(4, "OPEN")), leaf(4, "OPEN", blocker(3, "OPEN")),
	).pr(7, "feat/issue-1", "CLOSED", headSHA).pr(9, "feat/issue-3", "MERGED", headSHA)
	res := classify(t, f)
	if got := find(t, res, 1).State; got != board.Rejected {
		t.Errorf("#1 = %s, want rejected", got)
	}
	if got := find(t, res, 3).State; got != board.Parked {
		t.Errorf("#3 = %s, want parked", got)
	}
	want := []string{"dep-cycle:1,2", "dep-cycle:3,4", "merged-open:3:9", "rejected:1:7"}
	if keys := noteKeys(res); !slices.Equal(keys, want) {
		t.Errorf("notes = %v, want %v", keys, want)
	}
}

// --observe: a person may read the board while another session holds the lease, but the board
// then proposes nothing, so it cannot be used to drive a second Publisher.

func foreignLeaseFx() *fx {
	env := envelope("lease")
	env.Entity = state.EntityLease
	f := newFx().with(leaf(1, "OPEN"))
	f.b.Lease = &state.Lease{Envelope: env, Token: "a", Host: "h", PID: 42, StartedAt: "", RenewedAt: "now"}
	f.b.IssueStates[1] = newState(1)
	return f
}

func TestObserveReadsTheBoardBesideAForeignLeaseAndProposesNothing(t *testing.T) {
	t.Parallel()

	res, err := board.Classify(foreignLeaseFx().b, board.Options{LeaseToken: "", Observe: true})
	if err != nil {
		t.Fatalf("Classify() error = %v", err)
	}
	if find(t, res, 1).State != board.InProgress {
		t.Errorf("Issue = %+v, want the classification itself", find(t, res, 1))
	}
	if len(res.Actions) != 0 || len(res.Notifications) != 0 {
		t.Errorf("actions = %+v, notifications = %+v, want none while another session holds the lease", res.Actions, res.Notifications)
	}
	if res.Lease == nil || res.Lease.Host != "h" || res.Lease.PID != 42 {
		t.Errorf("lease = %+v, want the holder named", res.Lease)
	}
}

func TestObserveDoesNotChangeTheDefault(t *testing.T) {
	t.Parallel()

	_, err := board.Classify(foreignLeaseFx().b, board.Options{LeaseToken: "", Observe: false})
	if exitcode.CodeOf(err) != exitcode.Coordination {
		t.Errorf("exit = %d (%v), want %d", exitcode.CodeOf(err), err, exitcode.Coordination)
	}
}

func TestObserveBesideNoLeaseOrYourOwnProposesAsUsual(t *testing.T) {
	t.Parallel()

	own := foreignLeaseFx()
	for name, f := range map[string]*fx{"own lease": own, "no lease": newFx().with(leaf(1, "OPEN"))} {
		res, err := board.Classify(f.b, board.Options{LeaseToken: "a", Observe: true})
		if err != nil || len(res.Actions) == 0 {
			t.Errorf("%s: err = %v, actions = %+v, want the usual proposals", name, err, res.Actions)
		}
		if res.Lease != nil {
			t.Errorf("%s: lease = %+v, want none reported", name, res.Lease)
		}
	}
}
