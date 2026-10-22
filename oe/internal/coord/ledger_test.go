package coord_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/state"
)

// The cases below port skills/orchestrate-epic/scripts/test-epic-freeze.bats to the v2 ledger:
// the same rules, read from a fenced JSON ledger instead of line-format comments, with the
// release ordered by comment ID instead of created_at.

func used(l *state.Ledger, worker, reviewer, fix int) *state.Ledger {
	l.Counters.WorkerDispatches.Used, l.Counters.ReviewerPasses.Used, l.Counters.FixCycles.Used = worker, reviewer, fix
	return l
}

func frozenLedger(n int, reason string) *state.Ledger {
	l := ledgerOf(n)
	l.FreezeSeq = 1
	l.Freeze = &state.Freeze{Seq: 1, Reason: reason, MergeSHA: "", Health: "", Released: false}
	return l
}

func TestCreateLedgerSetsTheBoundsOfN(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	res, err := w.session(token).CreateLedger(ctx(), 2)
	ok(t, err)
	l := w.ledger(t)
	c := l.Counters
	if res.Status != coord.StatusClear || l.N != 2 || c.WorkerDispatches.Bound != 10 || c.ReviewerPasses.Bound != 8 || c.FixCycles.Bound != 4 {
		t.Errorf("ledger = %+v", l)
	}
	_, err = w.session(token).CreateLedger(ctx(), 9)
	ok(t, err)
	if w.ledger(t).N != 2 {
		t.Error("an existing ledger's bounds changed without a release")
	}
	if coord.NewLedger(0).N != 1 {
		t.Error("n below 1")
	}
}

func TestReservationWithinEveryBoundIsGranted(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, used(ledgerOf(2), 3, 2, 1))
	token := w.acquire(t)
	grant, res, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 7, ReviewerPasses: 0, FixCycles: 3})
	ok(t, err)
	l := w.ledger(t)
	if !res.Granted || grant.Request().WorkerDispatches != 7 || l.Counters.WorkerDispatches.Used != 10 || l.Counters.FixCycles.Used != 4 {
		t.Errorf("result %+v, ledger %+v", res, l.Counters)
	}
}

// TestReservationThatExceedsABoundFreezesInstead: a resumed run that already used a bound cannot
// exceed it; one exceeding counter rejects the whole batch, writes the freeze, then its note.
func TestReservationThatExceedsABoundFreezesInstead(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, used(ledgerOf(2), 6, 5, 4))
	token := w.acquire(t)
	grant, res, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 1})
	wantCode(t, err, exitcode.Stop)
	l := w.ledger(t)
	if res.Granted || grant.Request().FixCycles != 0 || l.Counters.WorkerDispatches.Used != 6 || l.Freeze == nil ||
		l.Freeze.Reason != "fix_cycles 4 + 1 > 4" || l.Freeze.Seq != 1 || l.FreezeSeq != 1 {
		t.Errorf("result %+v, ledger %+v", res, l)
	}
	wantFreezeThenNote(t, w, 1)
}

// wantFreezeThenNote checks the last two writes are the ledger's freeze, then its note.
func wantFreezeThenNote(t *testing.T, w *world, seq int) {
	t.Helper()
	key := fmt.Sprintf("freeze:%d", seq)
	if w.notes(epic, key) != 1 {
		t.Errorf("notes %s = %d, want 1", key, w.notes(epic, key))
	}
	writes := w.store.Writes()
	if len(writes) < 2 || !strings.Contains(writes[len(writes)-2].Body, "state ledger") || !strings.Contains(writes[len(writes)-1].Body, "note "+key) {
		t.Error("the freeze note was not posted after the ledger write")
	}
}

func TestOneExceedingCounterReservesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, used(ledgerOf(2), 9, 2, 0))
	token := w.acquire(t)
	_, res, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 2, ReviewerPasses: 1, FixCycles: 0})
	wantCode(t, err, exitcode.Stop)
	if l := w.ledger(t); l.Counters.ReviewerPasses.Used != 2 || res.Reason != "worker_dispatches 9 + 2 > 10" {
		t.Errorf("counters %+v, reason %q", l.Counters, res.Reason)
	}
}

func TestReservationWithoutALedgerIsRefused(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	_, _, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 0})
	wantCode(t, err, exitcode.Refused)
	_, _, err = w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 0, ReviewerPasses: 0, FixCycles: 0})
	wantCode(t, err, exitcode.Usage)
}

// TestFailedLedgerWriteGrantsNoSpawn: a reservation whose write fails returns no grant, even when
// the write may have landed; it counts as spent.
func TestFailedLedgerWriteGrantsNoSpawn(t *testing.T) {
	t.Parallel()

	for name, landed := range map[string]bool{"lost": false, "landed": true} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			w.put(t, epic, ledgerOf(2))
			token := w.acquire(t)
			w.store.OnWrite(func(*ghfake.Store, ghfake.Write) (int, bool) { return 1, landed })
			grant, res, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 0})
			wantCode(t, err, exitcode.Unreadable)
			if res.Granted || grant.Request().WorkerDispatches != 0 {
				t.Errorf("a failed write granted %+v", grant.Request())
			}
			_, err = w.session(token).Update(ctx(), child, coord.BeginFix{Findings: []string{"f"}, Grant: grant, Repair: nil})
			wantCode(t, err, exitcode.Refused)
		})
	}
}

// TestFrozenEpicStaysFrozenAndReservesNothing: re-invocation keeps a freeze, a reservation is not
// evaluated, and a missing freeze note is posted on the read.
func TestFrozenEpicStaysFrozenAndReservesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, used(frozenLedger(2, "fix_cycles 4 + 1 > 4"), 6, 5, 4))
	token := w.acquire(t)
	_, res, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 0})
	wantCode(t, err, exitcode.Stop)
	if res.Status != coord.StatusFrozen || w.ledger(t).Counters.WorkerDispatches.Used != 6 {
		t.Errorf("result %+v", res)
	}
	if w.notes(epic, "freeze:1") != 1 {
		t.Error("the missing freeze note was not posted")
	}
	_, err = w.session(token).Check(ctx())
	wantCode(t, err, exitcode.Stop)
	if w.notes(epic, "freeze:1") != 1 {
		t.Error("the freeze note was posted twice")
	}
}

// TestFreezeIsWrittenOnceAndNotifiedOnce: a second freeze is never written, and its note is not
// posted again.
func TestFreezeIsWrittenOnceAndNotifiedOnce(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	res, err := w.session(token).Freeze(ctx(), "default-branch checks failed", "m1", "FAIL")
	wantCode(t, err, exitcode.Stop)
	if res.Freeze == nil || res.Freeze.MergeSHA != "m1" || res.Note == nil || !res.Note.Posted {
		t.Errorf("first freeze %+v", res)
	}
	_, err = w.session(token).Freeze(ctx(), "again", "m2", "FAIL")
	wantCode(t, err, exitcode.Stop)
	if l := w.ledger(t); l.FreezeSeq != 1 || l.Freeze.MergeSHA != "m1" || w.notes(epic, "freeze:1") != 1 {
		t.Errorf("ledger %+v, notes %d", l, w.notes(epic, "freeze:1"))
	}
}

// TestFreezeWhoseNoteWouldBeRefusedWritesNothing: the freeze note is checked before the freeze is
// written, so a freeze can never be left without a note that a release needs.
func TestFreezeWhoseNoteWouldBeRefusedWritesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	before := w.writes()
	_, err := w.session(token).Freeze(ctx(), "log says token = \"ghp_"+strings.Repeat("c", 36)+"\"", "", "")
	wantCode(t, err, exitcode.Refused)
	if w.writes() != before || w.ledger(t).Freeze != nil {
		t.Error("a freeze with an unpostable note was written")
	}
	_, err = w.session(token).Freeze(ctx(), "default-branch checks failed", "", "")
	wantCode(t, err, exitcode.Stop)
	wantFreezeThenNote(t, w, 1)
}

// TestALedgerOrFreezePlantedBySomeoneElseIsIgnored: only the loop identity's state counts.
func TestALedgerOrFreezePlantedBySomeoneElseIsIgnored(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.store.Add(epic, "mallory", "OWNER", mustBody(frozenLedger(99, "fake")))
	_, _, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 0})
	wantCode(t, err, exitcode.Refused)
	w.put(t, epic, ledgerOf(1))
	_, _, err = w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 0})
	ok(t, err)
}

func TestALedgerMissingACounterStops(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	body := strings.Replace(mustBody(ledgerOf(1)), `"reviewer_passes": {`, `"other": {`, 1)
	w.store.Add(epic, "loop", "OWNER", body)
	before := w.writes()
	_, _, err := w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 0})
	wantCode(t, err, exitcode.Protocol)
	_, err = w.session(token).Freeze(ctx(), "x", "", "")
	wantCode(t, err, exitcode.Protocol)
	if w.writes() != before {
		t.Error("an unreadable ledger was written over or notified")
	}
}

// TestDeletingTheLedgerResetsTheBudget: deleting the ledger is the person's budget reset; the
// next create starts every counter at 0.
func TestDeletingTheLedgerResetsTheBudget(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	id := w.put(t, epic, used(ledgerOf(1), 5, 4, 2))
	token := w.acquire(t)
	w.store.Delete(id)
	_, err := w.session(token).CreateLedger(ctx(), 1)
	ok(t, err)
	if l := w.ledger(t); l.Counters.WorkerDispatches.Used != 0 || l.Counters.FixCycles.Used != 0 {
		t.Errorf("counters = %+v", l.Counters)
	}
}

// TestResultsAreRecordedWhileFrozen: a freeze stops new work, not the recording of agents that
// were already running.
func TestResultsAreRecordedWhileFrozen(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, frozenLedger(1, "x"))
	token := w.acquire(t)
	w.put(t, child, newIssue())
	got, err := w.session(token).Update(ctx(), child, coord.WorkerResult{Report: report(coord.StatusDone, "h1"), Worktree: "/wt/7", QuestionKey: ""})
	ok(t, err)
	if got.HeadSHA == nil || *got.HeadSHA != "h1" {
		t.Errorf("state = %+v", got)
	}
}

// frozenWithNote is an Epic frozen with its note posted, so releases can be placed around it.
func frozenWithNote(t *testing.T) (*world, string) {
	t.Helper()
	w := newWorld(t)
	w.put(t, epic, used(frozenLedger(2, "fix_cycles 4 + 1 > 4"), 6, 5, 4))
	token := w.acquire(t)
	_, err := w.session(token).Check(ctx())
	wantCode(t, err, exitcode.Stop)
	return w, token
}

// TestReleaseResetsTheBudgetOnce: a trusted epic-release after the freeze note lifts the freeze,
// keeps the record as released, and resets the budget; reading the same release again resets
// nothing.
func TestReleaseResetsTheBudgetOnce(t *testing.T) {
	t.Parallel()

	w, token := frozenWithNote(t)
	release := w.human(epic, "epic-release")
	res, err := w.session(token).Release(ctx(), 3)
	ok(t, err)
	l := w.ledger(t)
	if !res.Released || res.Release != release || l.Freeze == nil || !l.Freeze.Released || l.ReleaseWatermark != release ||
		l.N != 3 || l.Counters.WorkerDispatches != (state.Counter{Used: 0, Bound: 15}) {
		t.Fatalf("result %+v, ledger %+v", res, l)
	}
	_, _, err = w.session(token).Reserve(ctx(), coord.Request{WorkerDispatches: 2, ReviewerPasses: 0, FixCycles: 0})
	ok(t, err)
	res, err = w.session(token).Release(ctx(), 3)
	ok(t, err)
	if res.Released || w.ledger(t).Counters.WorkerDispatches.Used != 2 {
		t.Errorf("the same release reset the budget twice: %+v", res)
	}
}

func TestTheEarliestReleaseAfterTheNoteLiftsTheFreeze(t *testing.T) {
	t.Parallel()

	w, token := frozenWithNote(t)
	first := w.human(epic, "epic-release")
	w.store.Add(epic, "bob", "OWNER", "epic-release")
	res, err := w.session(token).Release(ctx(), 2)
	ok(t, err)
	if res.Release != first {
		t.Errorf("released by %d, want %d", res.Release, first)
	}
}

// TestANewFreezeAfterAReleaseIsFrozenAgain: an old release, below the new freeze note, does not
// lift a new freeze.
func TestANewFreezeAfterAReleaseIsFrozenAgain(t *testing.T) {
	t.Parallel()

	w, token := frozenWithNote(t)
	w.human(epic, "epic-release")
	_, err := w.session(token).Release(ctx(), 2)
	ok(t, err)
	w.human(epic, "epic-release")
	_, err = w.session(token).Freeze(ctx(), "health failed", "m2", "FAIL")
	wantCode(t, err, exitcode.Stop)
	res, err := w.session(token).Release(ctx(), 2)
	wantCode(t, err, exitcode.Stop)
	if l := w.ledger(t); res.Released || l.Freeze.Seq != 2 || l.Freeze.Released {
		t.Errorf("result %+v, freeze %+v", res, l.Freeze)
	}
}

// TestAReleaseBeforeTheFreezeNoteDoesNotLiftIt: the window starts at the note, so a release the
// human posted before being told of the freeze does not count.
func TestAReleaseBeforeTheFreezeNoteDoesNotLiftIt(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, frozenLedger(2, "x"))
	w.human(epic, "epic-release")
	token := w.acquire(t)
	res, err := w.session(token).Release(ctx(), 2)
	wantCode(t, err, exitcode.Stop)
	if res.Released || res.Note == nil || !res.Note.Posted {
		t.Errorf("result %+v", res)
	}
}

func TestOnlyATrustedExactReleaseLifts(t *testing.T) {
	t.Parallel()

	w, token := frozenWithNote(t)
	w.store.Add(epic, "eve", "CONTRIBUTOR", "epic-release")
	w.store.Add(epic, "eve", "NONE", "epic-release")
	w.human(epic, "let's not epic-release yet")
	w.human(epic, "EPIC-RELEASE")
	w.human(epic, "epic-release\nepic-approve")
	w.human(epic, "orchestrate-epic: epic-release")
	_, err := w.session(token).Release(ctx(), 2)
	wantCode(t, err, exitcode.Stop)
	id := w.human(epic, "  epic-release  \n\nepic-release\n")
	res, err := w.session(token).Release(ctx(), 2)
	ok(t, err)
	if res.Release != id {
		t.Errorf("released by %d, want %d", res.Release, id)
	}
}

func TestTheLoopIdentitysOwnTrustedReleaseCounts(t *testing.T) {
	t.Parallel()

	w, token := frozenWithNote(t)
	id := w.store.Add(epic, "loop", "OWNER", "epic-release")
	res, err := w.session(token).Release(ctx(), 2)
	ok(t, err)
	if res.Release != id {
		t.Errorf("released by %d, want %d", res.Release, id)
	}
}

func TestReleaseOnAClearEpicDoesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, ledgerOf(1))
	token := w.acquire(t)
	w.human(epic, "epic-release")
	before := w.writes()
	res, err := w.session(token).Release(ctx(), 5)
	ok(t, err)
	if res.Released || w.writes() != before {
		t.Errorf("result %+v", res)
	}
}

func TestValidateLedger(t *testing.T) {
	t.Parallel()

	over := used(ledgerOf(1), 6, 0, 0)
	wantCode(t, coord.ValidateLedger(over), exitcode.Refused)
	bounds := ledgerOf(1)
	bounds.Counters.FixCycles.Bound = 99
	wantCode(t, coord.ValidateLedger(bounds), exitcode.Refused)
	stale := frozenLedger(1, "x")
	stale.FreezeSeq = 2
	wantCode(t, coord.ValidateLedger(stale), exitcode.Refused)
	ok(t, coord.ValidateLedger(ledgerOf(1)))
}
