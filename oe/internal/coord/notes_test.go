package coord_test

import (
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/ghfake"
)

// TestNoteIsPostedOncePerKey: the same notification posted twice with the same dedup key leaves
// exactly one comment.
func TestNoteIsPostedOncePerKey(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	first, err := w.session(token).PostNote(ctx(), child, "start:7:feat/issue-7", "着手しました。")
	ok(t, err)
	second, err := w.session(token).PostNote(ctx(), child, "start:7:feat/issue-7", "着手しました。")
	ok(t, err)
	if !first.Posted || second.Posted || second.CommentID != first.CommentID {
		t.Errorf("first %+v, second %+v", first, second)
	}
	if n := w.notes(child, "start:7:feat/issue-7"); n != 1 {
		t.Errorf("notes = %d, want 1", n)
	}
}

// TestNoteWithAScanFindingPostsNothing: a scan finding in the text posts nothing, before the
// lease or the comments are even read.
func TestNoteWithAScanFindingPostsNothing(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	calls := len(w.r.Calls())
	res, err := w.session(token).PostNote(ctx(), child, "qa:7:{digest}", "token: ghp_"+strings.Repeat("a", 36))
	wantCode(t, err, exitcode.Refused)
	if _, isScan := errors.AsType[*coord.ScanError](err); !isScan || len(res.Findings) == 0 {
		t.Errorf("err %v, findings %+v", err, res.Findings)
	}
	if len(w.r.Calls()) != calls || len(w.store.Comments(child)) != 0 {
		t.Error("a note with a finding reached GitHub")
	}
	if strings.Contains(err.Error(), "ghp_") {
		t.Error("the refusal names the matched value")
	}
}

// TestNoteWhosePostResponseWasLostIsNotPostedAgain: a post that landed but failed is found by
// its key on the re-read, so the run neither fails nor posts twice.
func TestNoteWhosePostResponseWasLostIsNotPostedAgain(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.store.OnWrite(func(_ *ghfake.Store, wr ghfake.Write) (int, bool) {
		if wr.Method == http.MethodPost {
			return 1, true
		}
		return 0, true
	})
	res, err := w.session(token).PostNote(ctx(), child, "rejected:7:30", "却下されました。")
	ok(t, err)
	if !res.Posted || w.notes(child, "rejected:7:30") != 1 {
		t.Errorf("result %+v, notes %d", res, w.notes(child, "rejected:7:30"))
	}
}

func TestNoteThatFailedToPostIsAnError(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.store.OnWrite(func(*ghfake.Store, ghfake.Write) (int, bool) { return 1, false })
	_, err := w.session(token).PostNote(ctx(), child, "rejected:7:30", "却下されました。")
	wantCode(t, err, exitcode.Unreadable)
}

func TestNoteKeyDigestAndValidation(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	res, err := w.session(token).PostNote(ctx(), child, "qa:7:{digest}", "答え")
	ok(t, err)
	if res.Key != "qa:7:"+coord.Digest("答え") || len(coord.Digest("答え")) != 12 {
		t.Errorf("key = %q", res.Key)
	}
	for _, bad := range []string{"", "two words", "a-->b", "{other}"} {
		_, err := w.session(token).PostNote(ctx(), child, bad, "x")
		wantCode(t, err, exitcode.Usage)
	}
}

func TestOversizedNoteIsRefused(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	before := w.writes()
	// One over GitHub's character limit, and one under it whose bytes would not fit in a single
	// argument to gh.
	for _, text := range []string{strings.Repeat("a", coord.MaxBody), strings.Repeat("あ", 50000)} {
		_, err := w.session(token).PostNote(ctx(), child, "report:7:abc:{digest}", text)
		wantCode(t, err, exitcode.Refused)
	}
	if w.writes() != before {
		t.Error("an oversized note was posted")
	}
}

// TestNoteOnAnIssueWithV1LeftoversStops: a v1 marker on the target stops the writer with exit 6.
func TestNoteOnAnIssueWithV1LeftoversStops(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.store.Add(child, "loop", "OWNER", "<!-- orchestrate-epic:state -->\n- cycle: 0")
	_, err := w.session(token).PostNote(ctx(), child, "start:7:feat/issue-7", "x")
	wantCode(t, err, exitcode.Protocol)
}

// TestANoteKeyPlantedBySomeoneElseDoesNotSuppressThePost: only the loop's own notes count.
func TestANoteKeyPlantedBySomeoneElseDoesNotSuppressThePost(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	w.store.Add(child, "mallory", "NONE", "<!-- oe:v2 note start:7:feat/issue-7 -->\nfake")
	res, err := w.session(token).PostNote(ctx(), child, "start:7:feat/issue-7", "x")
	ok(t, err)
	if !res.Posted {
		t.Error("a planted note suppressed the loop's own")
	}
}
