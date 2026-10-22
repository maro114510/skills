package coord_test

import (
	"testing"
	"time"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/state"
)

func lease(token, hostName string, pid int) *state.Lease {
	var l state.Lease
	l.Entity, l.Key, l.Revision, l.UpdatedBy = state.EntityLease, state.KeyLease, 3, token
	l.Token, l.Host, l.PID, l.StartedAt, l.RenewedAt = token, hostName, pid, "2026-10-18T00:00:00Z", "2026-10-18T00:00:00Z"
	return &l
}

func TestAcquireWritesALeaseWithAFreshToken(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	var l state.Lease
	if !w.stateOf(t, epic, state.KeyLease, &l) {
		t.Fatal("no lease written")
	}
	if len(token) != 32 || l.Token != token || l.Host != host || l.PID != 4242 || l.UpdatedBy != token || l.Revision != 1 {
		t.Errorf("lease = %+v, token %q", l, token)
	}
}

func TestAcquireTakesAnEndedLeaseUnderANewToken(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, lease("old", "host-b", 0))
	token := w.acquire(t)
	var l state.Lease
	w.stateOf(t, epic, state.KeyLease, &l)
	if token == "old" || l.Token != token || l.Revision != 4 {
		t.Errorf("lease = %+v", l)
	}
}

// TestForeignLeaseStopsWithoutTakingOver: a lease held from another host, however old, or from
// this host by a running pid, stops acquire with exit 7 and nothing is written.
func TestForeignLeaseStopsWithoutTakingOver(t *testing.T) {
	t.Parallel()

	for name, l := range map[string]*state.Lease{
		"another host":         lease("other", "host-b", 1),
		"a live pid this host": lease("other", host, 4242),
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			w.put(t, epic, l)
			before := w.writes()
			_, err := w.session("").Acquire(ctx(), 4242)
			wantCode(t, err, exitcode.Coordination)
			if w.writes() != before {
				t.Error("a foreign lease was written over")
			}
		})
	}
}

func TestAcquireReclaimsADeadHolderOnThisHost(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	w.put(t, epic, lease("other", host, 9999))
	res, err := w.session("").Acquire(ctx(), 4242)
	ok(t, err)
	if !res.Reclaimed || res.Token == "other" || res.PID != 4242 {
		t.Errorf("result = %+v", res)
	}
}

func TestAcquireWithATokenResumesOnlyItsOwnLease(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	res, err := w.session(token).Acquire(ctx(), 4243)
	ok(t, err)
	if res.Token != token || res.PID != 4243 {
		t.Errorf("resume = %+v", res)
	}
	_, err = w.session("someone-else").Acquire(ctx(), 4242)
	wantCode(t, err, exitcode.Coordination)
}

// TestLostLeaseStopsEveryMutatingCall: with the lease ended, deleted, or taken by another token,
// every mutating call stops with exit 7, writes nothing, and never takes the lease back.
func TestLostLeaseStopsEveryMutatingCall(t *testing.T) {
	t.Parallel()

	losses := map[string]func(w *world, id int64){
		"ended":   func(w *world, id int64) { w.store.Edit(id, mustBody(lease("x", host, 0))) },
		"deleted": func(w *world, id int64) { w.store.Delete(id) },
		"foreign": func(w *world, id int64) { w.store.Edit(id, mustBody(lease("x", "host-b", 1))) },
	}
	calls := map[string]func(s *coord.Session) error{
		"note": func(s *coord.Session) error {
			_, err := s.PostNote(ctx(), child, "start:7:feat/issue-7", "x")
			return err
		},
		"start":  func(s *coord.Session) error { _, err := s.Update(ctx(), child, coord.Start{Branch: ""}); return err },
		"ledger": func(s *coord.Session) error { _, err := s.CreateLedger(ctx(), 2); return err },
		"reserve": func(s *coord.Session) error {
			_, _, err := s.Reserve(ctx(), coord.Request{WorkerDispatches: 1, ReviewerPasses: 0, FixCycles: 0})
			return err
		},
		"freeze": func(s *coord.Session) error { _, err := s.Freeze(ctx(), "health failed", "", ""); return err },
		"verify": func(s *coord.Session) error { return s.Verify(ctx()) },
		"end":    func(s *coord.Session) error { _, err := s.End(ctx()); return err },
	}
	for lossName, lose := range losses {
		for callName, call := range calls {
			t.Run(lossName+"/"+callName, func(t *testing.T) {
				t.Parallel()
				w := newWorld(t)
				if callName != "ledger" {
					w.put(t, epic, ledgerOf(2))
				}
				token := w.acquire(t)
				var id int64
				for _, c := range w.store.Comments(epic) {
					if c.Login == "loop" && containsKey(c.Body, "lease") {
						id = c.ID
					}
				}
				lose(w, id)
				before := w.writes()
				wantCode(t, call(w.session(token)), exitcode.Coordination)
				if w.writes() != before {
					t.Errorf("%d write(s) after the lease was lost", w.writes()-before)
				}
			})
		}
	}
}

func TestVerifyRenewsAtMostOnceAMinute(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	before := w.writes()
	w.now = w.now.Add(59 * time.Second)
	ok(t, w.session(token).Verify(ctx()))
	if w.writes() != before {
		t.Error("renewed within a minute")
	}
	w.now = w.now.Add(time.Second)
	ok(t, w.session(token).Verify(ctx()))
	var l state.Lease
	w.stateOf(t, epic, state.KeyLease, &l)
	if w.writes() != before+1 || l.RenewedAt != "2026-10-19T00:06:00Z" || l.StartedAt != "2026-10-19T00:05:00Z" {
		t.Errorf("writes %d, lease %+v", w.writes()-before, l)
	}
}

func TestEndSetsPIDZeroAndTheNextSessionTakesOver(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	token := w.acquire(t)
	res, err := w.session(token).End(ctx())
	ok(t, err)
	if res.PID != 0 {
		t.Errorf("ended lease = %+v", res)
	}
	if next := w.acquire(t); next == token {
		t.Error("the next session reused the ended token")
	}
}

// TestSecondLocalProcessStopsOnTheLock: while one oe process holds the Epic's host-wide lock, a
// second one on the same Epic stops with exit 7, before any call.
func TestSecondLocalProcessStopsOnTheLock(t *testing.T) {
	t.Parallel()

	w := newWorld(t)
	first := w.session("")
	ok(t, first.Lock())
	second := w.session("")
	wantCode(t, second.Lock(), exitcode.Coordination)
	if len(w.r.Calls()) != 0 {
		t.Errorf("calls = %d, want none", len(w.r.Calls()))
	}
	first.Close()
	ok(t, second.Lock())
	second.Close()
}

func TestLockPathNamesTheEpic(t *testing.T) {
	t.Parallel()

	dir, err := coord.LockDir(func(k string) string { return map[string]string{"HOME": "/home/u"}[k] })
	ok(t, err)
	if got := coord.LockPath(dir, "o/r", 277); got != "/home/u/.local/state/oe/locks/o-r-277.lock" {
		t.Errorf("path = %q", got)
	}
	dir, err = coord.LockDir(func(k string) string { return map[string]string{"XDG_STATE_HOME": "/x", "HOME": "/h"}[k] })
	ok(t, err)
	if dir != "/x/oe/locks" {
		t.Errorf("dir = %q", dir)
	}
	_, err = coord.LockDir(func(string) string { return "" })
	wantCode(t, err, exitcode.Refused)
}
