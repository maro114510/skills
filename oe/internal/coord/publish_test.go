package coord_test

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/state"
)

func publishOf(sha, prev, base string, pr int, phase string) *state.Publish {
	return &state.Publish{SHA: sha, PrevSHA: prev, Base: base, Branch: "feat/issue-7", PR: pr, Phase: phase}
}

// TestRecordPublishIntentNeedsTheBoundPair shows that an intent is recorded only for the exact pair an approval binds.
// A refused intent writes nothing, so no push can follow it.
func TestRecordPublishIntentNeedsTheBoundPair(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		st *state.Issue
		t  coord.RecordPublishIntent
	}{
		"no approval":  {func() *state.Issue { s := newIssue(); s.HeadSHA = new("h1"); return s }(), coord.RecordPublishIntent{SHA: "h1", Base: "b1", PrevSHA: ""}},
		"another sha":  {approved("h1", "b1"), coord.RecordPublishIntent{SHA: "h2", Base: "b1", PrevSHA: ""}},
		"another base": {approved("h1", "b1"), coord.RecordPublishIntent{SHA: "h1", Base: "b2", PrevSHA: ""}},
		"no sha":       {approved("h1", "b1"), coord.RecordPublishIntent{SHA: "", Base: "b1", PrevSHA: ""}},
	}
	for name, c := range cases {
		w := newWorld(t)
		token := w.acquire(t)
		w.put(t, child, c.st)
		before := w.writes()
		_, err := w.session(token).Update(ctx(), child, c.t)
		wantCode(t, err, exitcode.Refused)
		if w.writes() != before {
			t.Errorf("%s: a refused intent was written", name)
		}
	}

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, approved("h1", "b1"))
	got, err := w.session(token).Update(ctx(), child, coord.RecordPublishIntent{SHA: "h1", Base: "b1", PrevSHA: ""})
	ok(t, err)
	want := state.Publish{SHA: "h1", PrevSHA: "", Base: "b1", Branch: "feat/issue-7", PR: 0, Phase: "intent"}
	if got.Publish == nil || *got.Publish != want {
		t.Errorf("publish = %+v, want %+v", got.Publish, want)
	}
}

func withPublish(st *state.Issue, p *state.Publish) *state.Issue {
	st.Publish = p
	return st
}

// TestRecordPublishIntentKeepsTheEarlierPR shows that a repaired head re-publishes over a linked publish and keeps its pull request.
// The intent names the remote head it was recorded against, so a resumed run can tell its own push from another.
func TestRecordPublishIntentKeepsTheEarlierPR(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, withPublish(approved("h2", "b2"), publishOf("h1", "", "b1", 12, coord.PublishLinked)))
	got, err := w.session(token).Update(ctx(), child, coord.RecordPublishIntent{SHA: "h2", Base: "b2", PrevSHA: "h1"})
	ok(t, err)
	want := state.Publish{SHA: "h2", PrevSHA: "h1", Base: "b2", Branch: "feat/issue-7", PR: 12, Phase: "intent"}
	if got.Publish == nil || *got.Publish != want {
		t.Errorf("publish = %+v, want %+v", got.Publish, want)
	}
}

// TestRecordPublishIntentReplacesAnInFlightPublishOfAnOlderPair shows that after a crash and a staleness pass the new pair is published over the old pair's in-flight record.
func TestRecordPublishIntentReplacesAnInFlightPublishOfAnOlderPair(t *testing.T) {
	t.Parallel()

	for _, phase := range []string{coord.PublishIntent, coord.PublishPushed} {
		w := newWorld(t)
		token := w.acquire(t)
		w.put(t, child, withPublish(approved("h2", "b2"), publishOf("h1", "", "b1", 0, phase)))
		got, err := w.session(token).Update(ctx(), child, coord.RecordPublishIntent{SHA: "h2", Base: "b2", PrevSHA: "h1"})
		ok(t, err)
		want := state.Publish{SHA: "h2", PrevSHA: "h1", Base: "b2", Branch: "feat/issue-7", PR: 0, Phase: "intent"}
		if got.Publish == nil || *got.Publish != want {
			t.Errorf("over %s: publish = %+v, want %+v", phase, got.Publish, want)
		}
	}
}

// TestRecordPublishedMovesTheIntentToPushedThenLinked shows the two steps after the push.
// The first records only that the push landed, the second records the pull request, and a linked publish moves no further.
func TestRecordPublishedMovesTheIntentToPushedThenLinked(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, withPublish(approved("h1", "b1"), publishOf("h1", "", "b1", 0, coord.PublishIntent)))

	got, err := w.session(token).Update(ctx(), child, coord.RecordPublished{PR: 0})
	ok(t, err)
	if got.Publish == nil || got.Publish.Phase != "pushed" || got.Publish.PR != 0 {
		t.Fatalf("after the push: %+v", got.Publish)
	}
	again, err := w.session(token).Update(ctx(), child, coord.RecordPublished{PR: 0})
	ok(t, err)
	if again.Revision != got.Revision {
		t.Errorf("recording the push twice wrote again: revision %d, then %d", got.Revision, again.Revision)
	}
	got, err = w.session(token).Update(ctx(), child, coord.RecordPublished{PR: 31})
	ok(t, err)
	if got.Publish == nil || got.Publish.Phase != "linked" || got.Publish.PR != 31 {
		t.Fatalf("after the pull request: %+v", got.Publish)
	}
	for _, pr := range []int{0, 32} {
		_, err = w.session(token).Update(ctx(), child, coord.RecordPublished{PR: pr})
		wantCode(t, err, exitcode.Refused)
	}
}

// TestRecordPublishedNeedsAPublishInFlight shows that nothing is recorded as published when no intent was ever recorded.
func TestRecordPublishedNeedsAPublishInFlight(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.put(t, child, approved("h1", "b1"))
	before := w.writes()
	_, err := w.session(token).Update(ctx(), child, coord.RecordPublished{PR: 0})
	wantCode(t, err, exitcode.Refused)
	if w.writes() != before {
		t.Error("a refused record was written")
	}
}
