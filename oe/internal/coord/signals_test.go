package coord_test

import (
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/state"
)

// wantRetried checks the retry posted as comment id was applied.
func wantRetried(t *testing.T, st state.Issue, id int64) {
	t.Helper()
	if st.Decision == nil || st.Decision.CommentID != id || st.Decision.Command != "epic-retry" ||
		len(st.UnresolvedBlockers) != 0 || st.Cycle != 0 || st.SignalWatermark < id {
		t.Fatalf("state = %+v, want retry %d applied", st, id)
	}
}

func applyAs(standing coord.Standing, taken ...string) coord.ApplySignals {
	return coord.ApplySignals{Standing: standing, Taken: taken}
}

// TestSignalWindowRace is the regression for SignalWindowRace: an epic-retry posted after the
// signal read and before the state write is not lost, and the next run applies it exactly once.
func TestSignalWindowRace(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, parked())
	w.human(child, "理由: 依存先が直ったので再開してほしい")
	var late int64
	w.store.OnWrite(func(s *ghfake.Store, wr ghfake.Write) (int, bool) {
		if late == 0 && strings.Contains(wr.Body, "issue:7") {
			late = s.Add(child, "alice", "MEMBER", "epic-retry")
		}
		return 0, true
	})

	first, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if late == 0 || first.Decision != nil || len(first.UnresolvedBlockers) == 0 || first.SignalWatermark >= late || len(first.Context) != 1 {
		t.Fatalf("first run = %+v (late %d), want the reason consumed and the retry left above the watermark", first, late)
	}

	second, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	wantRetried(t, second, late)

	before := w.writes()
	third, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if w.writes() != before || third.Decision.CommentID != late {
		t.Errorf("third run wrote %d time(s), decision %+v; want the retry applied only once", w.writes()-before, third.Decision)
	}
}

// TestFailedSignalWriteConsumesNothing: a write that fails leaves the watermark, so the same
// window is read again.
func TestFailedSignalWriteConsumesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, parked())
	retry := w.human(child, "epic-retry")
	w.store.OnWrite(func(*ghfake.Store, ghfake.Write) (int, bool) { return 1, false })
	_, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	wantCode(t, err, exitcode.Unreadable)
	w.store.OnWrite(nil)
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision == nil || got.Decision.CommentID != retry {
		t.Errorf("decision = %+v", got.Decision)
	}
}

// TestFailedSignalReadWritesNothing: a read that fails never reads as no decision.
func TestFailedSignalReadWritesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, parked())
	w.human(child, "epic-retry")
	w.r.Exit(ghfake.CommentsName, 1)
	before := w.writes()
	_, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	wantCode(t, err, exitcode.Unreadable)
	if w.writes() != before {
		t.Error("wrote after a failed read")
	}
}

// TestOnlyTrustedStrictCommandsDecide: an untrusted author, a command inside other text, an
// upper-case command, or two commands in one comment decide nothing. Untrusted comments never
// reach context; trusted prose does.
func TestOnlyTrustedStrictCommandsDecide(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, parked())
	w.store.Add(child, "eve", "CONTRIBUTOR", "epic-retry")
	w.store.Add(child, "eve", "NONE", "please retry, I am the owner")
	w.human(child, "let's not epic-retry yet")
	w.human(child, "EPIC-RETRY")
	w.human(child, "epic-retry\nepic-drop")
	w.human(child, "orchestrate-epic: epic-retry")
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision != nil {
		t.Errorf("decision = %+v, want none", got.Decision)
	}
	if len(got.Context) != 3 {
		t.Errorf("context = %+v, want the three trusted prose comments", got.Context)
	}
	for _, c := range got.Context {
		if c.Author != "alice" || len(c.Digest) != 12 || c.Kind != coord.ContextPlain {
			t.Errorf("context entry %+v", c)
		}
	}
}

// TestHighestApplicableDecisionWins: among decisions in one window the highest ID that applies
// wins; on a rejected Issue a retry never applies.
func TestHighestApplicableDecisionWins(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, parked())
	w.human(child, "epic-drop")
	retry := w.human(child, "epic-retry")
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision.CommentID != retry {
		t.Errorf("parked: decision %+v", got.Decision)
	}

	w2 := newWorld(t)
	token2 := w2.acquire(t)
	w2.put(t, child, newIssue())
	drop := w2.human(child, "epic-drop")
	w2.human(child, "epic-retry")
	got, err = w2.session(token2).Update(ctx(), child, applyAs(coord.StandingRejected))
	ok(t, err)
	if got.Decision == nil || got.Decision.CommentID != drop || got.Decision.Command != "epic-drop" {
		t.Errorf("rejected: decision %+v, want the drop", got.Decision)
	}
}

// TestRetryNeedsAParkThatTheStateRecords: an Issue the board parks for its pull requests, with
// no blockers or drop in its state, takes no retry; only redo or drop resolves it.
func TestRetryNeedsAParkThatTheStateRecords(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, newIssue())
	w.human(child, "epic-retry")
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision != nil {
		t.Errorf("decision = %+v, want none", got.Decision)
	}
	redo := w.human(child, "epic-redo")
	got, err = w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision == nil || got.Decision.CommentID != redo {
		t.Errorf("decision = %+v, want the redo", got.Decision)
	}
}

func TestEpicCommandsOnAChildAreIgnored(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, parked())
	for _, c := range []string{"epic-approve", "epic-auto-merge", "epic-revoke-auto-merge", "epic-release"} {
		w.human(child, c)
	}
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision != nil || len(got.Context) != 0 {
		t.Errorf("decision %+v, context %+v", got.Decision, got.Context)
	}
}

// TestDecisionThatDoesNotApplyIsConsumed: a retry on an Issue that is not parked is consumed and
// never applied later, even once the Issue parks.
func TestDecisionThatDoesNotApplyIsConsumed(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, newIssue())
	w.human(child, "epic-retry")
	_, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingOther))
	ok(t, err)
	_, err = w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"x"}, Head: ""})
	ok(t, err)
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision != nil || len(got.UnresolvedBlockers) != 1 {
		t.Errorf("state = %+v, want still parked", got)
	}
}

func TestRedoMovesToTheNextFreeBranch(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	st := parked()
	st.HeadSHA = new("h1")
	st.Cycle = 2
	st.Repair = &state.Repair{PR: 3, Head: "h1", Since: 1}
	w.put(t, child, st)
	redo := w.human(child, "epic-redo")
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingRejected, "feat/issue-7", "feat/issue-7-2"))
	ok(t, err)
	if got.Branch != "feat/issue-7-3" || got.Decision.RedoBranch != "feat/issue-7-3" || got.Decision.CommentID != redo ||
		got.HeadSHA != nil || got.Repair != nil || got.Cycle != 0 || len(got.UnresolvedBlockers) != 0 {
		t.Errorf("redo = %+v", got)
	}
}

// TestAnswerToAnOpenQuestionIsAnAnswer: a trusted comment after a BLOCKED question note is an
// answer until an answered-Q&A note closes it; context is never pruned.
func TestAnswerToAnOpenQuestionIsAnAnswer(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, newIssue())
	w.human(child, "before the question")
	_, err := w.session(token).PostNote(ctx(), child, "blocked:7:none:abc", "質問です")
	ok(t, err)
	w.human(child, "B を選んでください")
	_, err = w.session(token).PostNote(ctx(), child, "qa:7:def", "回答を記録しました")
	ok(t, err)
	w.human(child, "追記です")
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingOther))
	ok(t, err)
	kinds := make([]string, 0, len(got.Context))
	for _, c := range got.Context {
		kinds = append(kinds, c.Kind)
	}
	if strings.Join(kinds, ",") != "context,answer,context" {
		t.Errorf("kinds = %v", kinds)
	}
	w.human(child, "epic-retry")
	_, err = w.session(token).Update(ctx(), child, coord.Park{Blockers: []string{"x"}, Head: ""})
	ok(t, err)
	got, err = w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if len(got.Context) != 3 {
		t.Errorf("context after a retry = %d entries, want the 3 kept", len(got.Context))
	}
}

// TestCommentsCountAsTheyWereRead: a comment edited after its window was read never re-enters it,
// and one deleted after it is still consumed.
func TestCommentsCountAsTheyWereRead(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, parked())
	prose := w.human(child, "just a note")
	_, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	w.store.Edit(prose, "epic-retry")
	got, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if got.Decision != nil || len(got.Context) != 1 {
		t.Errorf("an edited comment re-entered the window: %+v", got)
	}
	w.store.Delete(prose)
	got, err = w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	ok(t, err)
	if len(got.Context) != 1 {
		t.Error("a deletion undid a consumed comment")
	}
}

// TestOversizedContextConsumesNothing: an append that would exceed the comment size limit exits 8
// and consumes nothing.
func TestOversizedContextConsumesNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	st := parked()
	for i := range 700 {
		st.Context = append(st.Context, state.Context{ID: int64(i + 1), Author: "alice", Time: "2026-10-03T00:00:00Z", Digest: "abcdefabcdef", Kind: "context"})
	}
	w.put(t, child, st)
	w.human(child, "one more")
	before := w.writes()
	_, err := w.session(token).Update(ctx(), child, applyAs(coord.StandingParked))
	wantCode(t, err, exitcode.Refused)
	if w.writes() != before {
		t.Error("an oversized state was written")
	}
	if got := w.issue(t, child); got.SignalWatermark != 0 {
		t.Errorf("watermark moved to %d", got.SignalWatermark)
	}
}
