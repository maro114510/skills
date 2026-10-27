package round_test

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/round"
	"github.com/maro114510/skills/oe/internal/scan"
)

type posted struct {
	on   int
	key  string
	text string
}

// recorder is a comment writer that remembers what it was asked and posts a key once, as the real one does.
type recorder struct {
	calls  []posted
	seen   map[string]bool
	failAt int
}

func newRecorder() *recorder { return &recorder{calls: nil, seen: map[string]bool{}, failAt: 0} }

func (r *recorder) PostNote(_ context.Context, on int, key, text string) (coord.NoteResult, error) {
	res := coord.NoteResult{On: on, Key: key, Posted: false, CommentID: 0, Findings: []scan.Finding{}}
	if r.failAt > 0 && len(r.calls)+1 == r.failAt {
		return res, errors.New("scan finding")
	}
	r.calls = append(r.calls, posted{on: on, key: key, text: text})
	res.Posted = !r.seen[key]
	r.seen[key] = true
	return res, nil
}

func note(kind, key string, on int) board.Notification {
	return board.Notification{Key: key, Kind: kind, On: on, Issues: nil, Tokens: nil}
}

func TestEachProposedNoteIsPostedOnItsTargetWithItsKeyAndTheFactsItIsAbout(t *testing.T) {
	t.Parallel()

	cycle := note(board.NoteDepCycle, "dep-cycle:4,9", 277)
	cycle.Issues = []int{4, 9}
	token := note(board.NoteLeftoverToken, "leftover-placeholder:280:abc123def456", 280)
	token.Tokens = []string{"{{T3}}", "{{T3.2}}"}
	rec := newRecorder()

	res, err := round.Notify(context.Background(), rec, []board.Notification{
		cycle, token,
		note(board.NoteRejected, "rejected:7:31", 7),
		note(board.NoteMergedOpen, "merged-open:8:32", 8),
		note(board.NoteStaleStart, "stale-start:9:feat/issue-9", 9),
	})

	if err != nil || len(res.Notes) != 5 {
		t.Fatalf("Notify = %+v, %v; want 5 notes", res, err)
	}
	for i, want := range []struct {
		on    int
		key   string
		texts []string
	}{
		{277, "dep-cycle:4,9", []string{"#4", "#9", "循環"}},
		{280, "leftover-placeholder:280:abc123def456", []string{"#280", "{{T3}}", "{{T3.2}}"}},
		{7, "rejected:7:31", []string{"#7", "PR #31", "epic-redo", "epic-drop"}},
		{8, "merged-open:8:32", []string{"#8", "PR #32", "閉じて"}},
		{9, "stale-start:9:feat/issue-9", []string{"#9", "feat/issue-9"}},
	} {
		got := rec.calls[i]
		if got.on != want.on || got.key != want.key {
			t.Errorf("note %d went to #%d with key %q, want #%d with %q", i, got.on, got.key, want.on, want.key)
		}
		for _, text := range want.texts {
			if !strings.Contains(got.text, text) {
				t.Errorf("note %q lacks %q in %q", want.key, text, got.text)
			}
		}
	}
}

func TestTheStaleVerdictAndFreezeNotesAreLeftToTheCommandsThatWriteTheirState(t *testing.T) {
	t.Parallel()

	rec := newRecorder()

	res, err := round.Notify(context.Background(), rec, []board.Notification{
		note(board.NoteStale, "stale:5:head:base", 5),
		note(board.NoteRejected, "rejected:7:31", 7),
		note(board.NoteFreeze, "freeze:2", 277),
	})

	if err != nil {
		t.Fatal(err)
	}
	if len(rec.calls) != 1 || rec.calls[0].key != "rejected:7:31" {
		t.Errorf("posted %+v, want only the rejected note", rec.calls)
	}
	if want := []string{"stale:5:head:base", "freeze:2"}; !reflect.DeepEqual(res.Skipped, want) {
		t.Errorf("skipped = %v, want %v", res.Skipped, want)
	}
}

func TestProposingTheSameNoteAgainPostsNothingNew(t *testing.T) {
	t.Parallel()

	rec := newRecorder()
	proposed := []board.Notification{note(board.NoteRejected, "rejected:7:31", 7)}

	first, err1 := round.Notify(context.Background(), rec, proposed)
	second, err2 := round.Notify(context.Background(), rec, proposed)

	if err1 != nil || err2 != nil || len(first.Notes) != 1 || len(second.Notes) != 1 {
		t.Fatalf("Notify = %+v, %v / %+v, %v", first, err1, second, err2)
	}
	if !first.Notes[0].Posted || second.Notes[0].Posted {
		t.Errorf("posted flags = %v then %v, want true then false: the writer posts a key once", first.Notes[0].Posted, second.Notes[0].Posted)
	}
}

func TestANoteTheWriterRefusesStopsTheRestAndReportsWhatWasPosted(t *testing.T) {
	t.Parallel()

	rec := newRecorder()
	rec.failAt = 2

	res, err := round.Notify(context.Background(), rec, []board.Notification{
		note(board.NoteRejected, "rejected:7:31", 7),
		note(board.NoteMergedOpen, "merged-open:8:32", 8),
		note(board.NoteStaleStart, "stale-start:9:feat/issue-9", 9),
	})

	if err == nil {
		t.Fatal("Notify = nil error, want the writer's refusal")
	}
	if len(res.Notes) != 1 || res.Notes[0].Key != "rejected:7:31" || len(rec.calls) != 1 {
		t.Errorf("notes %+v after %d posts, want only the first note posted and the rest not tried", res.Notes, len(rec.calls))
	}
}

func TestNothingProposedIsAnEmptyResultThatPrintsEmptyLists(t *testing.T) {
	t.Parallel()

	res, err := round.Notify(context.Background(), newRecorder(), nil)

	if err != nil || res.Notes == nil || res.Skipped == nil || len(res.Notes) != 0 || len(res.Skipped) != 0 {
		t.Errorf("Notify = %+v, %v; want empty non-nil lists", res, err)
	}
}
