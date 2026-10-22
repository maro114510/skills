package coord_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

const (
	epic  = 277
	child = 7
	host  = "host-a"
)

// world is one Epic on a fake GitHub whose comments live in a store.
type world struct {
	r     *ghfake.Router
	store *ghfake.Store
	dir   string
	now   time.Time
	alive map[int]bool
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{r: ghfake.New(), store: ghfake.NewStore(100), dir: t.TempDir(),
		now: time.Date(2026, 10, 19, 0, 5, 0, 0, time.UTC), alive: map[int]bool{4242: true}}
	w.r.Serve(w.store)
	return w
}

// session is a fresh oe process: a new client, so an earlier failed read taints nothing.
func (w *world) session(token string) *coord.Session {
	return coord.New(coord.Config{
		Client:  gh.New(w.r, false),
		Inputs:  inputs.Inputs{Repo: "o/r", Epic: epic, Me: "loop", DefaultBranch: "main", MaxParallel: 3, MaxParallelReason: "", GHVersion: "2.102.0"},
		Token:   token,
		LockDir: w.dir,
		Host:    host,
		Alive:   func(pid int) bool { return w.alive[pid] },
		Now:     func(context.Context) (time.Time, error) { return w.now, nil },
	})
}

// acquire starts a session holding the lease and returns its token.
func (w *world) acquire(t *testing.T) string {
	t.Helper()
	res, err := w.session("").Acquire(context.Background(), 4242)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	return res.Token
}

// writes counts the writes the store received.
func (w *world) writes() int { return len(w.store.Writes()) }

// human adds a comment by a trusted person.
func (w *world) human(issue int, body string) int64 {
	return w.store.Add(issue, "alice", "MEMBER", body)
}

// stateOf decodes the loop's state comment for key on issue into v; ok is false when absent.
func (w *world) stateOf(t *testing.T, issue int, key string, v protocol.State) bool {
	t.Helper()
	found := false
	for _, c := range w.store.Comments(issue) {
		m, ok, err := protocol.ParseMarker(c.Body)
		if err != nil || !ok || m.Kind != protocol.KindState || m.Key != key || c.Login != "loop" {
			continue
		}
		if found {
			t.Fatalf("two states for %s", key)
		}
		if _, err := protocol.DecodeState(c.Body, v); err != nil {
			t.Fatalf("decode %s: %v", key, err)
		}
		found = true
	}
	return found
}

func (w *world) issue(t *testing.T, n int) state.Issue {
	t.Helper()
	var st state.Issue
	if !w.stateOf(t, n, state.IssueKey(n), &st) {
		t.Fatalf("#%d has no state", n)
	}
	return st
}

func (w *world) ledger(t *testing.T) state.Ledger {
	t.Helper()
	var l state.Ledger
	if !w.stateOf(t, epic, state.KeyLedger, &l) {
		t.Fatal("the Epic has no ledger")
	}
	return l
}

func (w *world) notes(issue int, key string) int {
	n := 0
	for _, c := range w.store.Comments(issue) {
		if strings.HasPrefix(c.Body, fmt.Sprintf("<!-- oe:v2 note %s -->", key)) {
			n++
		}
	}
	return n
}

// put stores a state written by the loop, as an earlier run left it.
func (w *world) put(t *testing.T, issue int, s protocol.State) int64 {
	t.Helper()
	env := s.StateEnvelope()
	if env.UpdatedBy == "" {
		env.UpdatedBy = "earlier"
	}
	body, err := protocol.EncodeState(s)
	if err != nil {
		t.Fatal(err)
	}
	return w.store.Add(issue, "loop", "OWNER", body)
}

func wantCode(t *testing.T, err error, code exitcode.Code) {
	t.Helper()
	if got := exitcode.CodeOf(err); got != code {
		t.Fatalf("exit %d (%v), want %d", got, err, code)
	}
}

func ok(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// parked is an Issue state parked by blockers, with its watermark below every later comment.
func parked() *state.Issue {
	st := newIssue()
	st.UnresolvedBlockers = []string{"cap reached"}
	return st
}

func newIssue() *state.Issue {
	n := child
	var st state.Issue
	st.Entity, st.Key, st.Revision, st.UpdatedBy = state.EntityIssue, state.IssueKey(n), 1, "earlier"
	st.Branch = fmt.Sprintf("feat/issue-%d", n)
	st.PendingFindings, st.UnresolvedBlockers, st.Context = []string{}, []string{}, []state.Context{}
	return &st
}

func ledgerOf(n int) *state.Ledger {
	l := coord.NewLedger(n)
	l.Revision, l.UpdatedBy = 1, "earlier"
	return &l
}

func ctx() context.Context { return context.Background() }

func mustBody(s protocol.State) string {
	b, err := protocol.EncodeState(s)
	if err != nil {
		panic(err)
	}
	return b
}

func containsKey(body, key string) bool {
	return strings.HasPrefix(body, "<!-- oe:v2 state "+key+" -->")
}

func (w *world) storeComments(v map[string]string) string { return w.store.Query(v) }
