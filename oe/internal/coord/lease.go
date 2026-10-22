package coord

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/state"
)

// RenewEvery is how often a held lease's renewed_at is refreshed, at most.
const RenewEvery = time.Minute

// tokenBytes is the size of a lease token before hex encoding.
const tokenBytes = 16

// LeaseResult is what a lease command did.
type LeaseResult struct {
	Token     string `json:"token"`
	Host      string `json:"host"`
	PID       int    `json:"pid"`
	StartedAt string `json:"started_at"`
	RenewedAt string `json:"renewed_at"`
	// Reclaimed says the lease was taken from a holder on this host whose pid no longer runs.
	Reclaimed bool `json:"reclaimed"`
}

func leaseResult(l state.Lease, reclaimed bool) LeaseResult {
	return LeaseResult{Token: l.Token, Host: l.Host, PID: l.PID, StartedAt: l.StartedAt, RenewedAt: l.RenewedAt, Reclaimed: reclaimed}
}

func foreign(l state.Lease) error {
	return exitcode.New(exitcode.Coordination, fmt.Sprintf(
		"the Epic's lease is held by another session (host %s, pid %d, renewed %s); oe never takes it over. "+
			"If that session is gone for good, a person deletes the lease comment", l.Host, l.PID, l.RenewedAt))
}

// readLease reads the Epic's lease, if any.
func (s *Session) readLease(ctx context.Context) (state.Lease, stored, error) {
	var l state.Lease
	r, err := s.read(ctx, s.in.Epic)
	if err != nil {
		return l, stored{}, err
	}
	id, err := r.decode(state.KeyLease, state.EntityLease, &l)
	if err != nil {
		return l, stored{}, err
	}
	return l, stored{id: id, revision: l.Revision}, nil
}

// Acquire starts a session on the Epic, contract §4.1, recording pid as the holder. With no
// token it takes a lease that is absent, ended, or held on this host by a pid that no longer
// runs, under a fresh token. With a token it resumes only the lease that still carries it.
// Any other holder is exit 7, however old its lease is.
func (s *Session) Acquire(ctx context.Context, pid int) (LeaseResult, error) {
	if pid <= 0 {
		return LeaseResult{}, exitcode.New(exitcode.Usage, "--pid needs the session's positive process ID")
	}
	if s.host == "" {
		return LeaseResult{}, exitcode.New(exitcode.Refused, "this host has no name to record in the lease")
	}
	cur, prev, err := s.readLease(ctx)
	if err != nil {
		return LeaseResult{}, err
	}
	reclaimed, err := s.mayTake(cur, prev)
	if err != nil {
		return LeaseResult{}, err
	}
	now, err := s.clock(ctx)
	if err != nil {
		return LeaseResult{}, err
	}
	next := cur
	if s.token == "" {
		if s.token, err = newToken(); err != nil {
			return LeaseResult{}, err
		}
		next.StartedAt = now
	}
	next.Entity, next.Key = state.EntityLease, state.KeyLease
	next.Token, next.Host, next.PID, next.RenewedAt = s.token, s.host, pid, now
	if err := s.saveLease(ctx, prev, &next); err != nil {
		return LeaseResult{}, err
	}
	return leaseResult(next, reclaimed), nil
}

// mayTake decides whether Acquire may write the lease, and whether that reclaims it from a
// dead holder on this host.
func (s *Session) mayTake(cur state.Lease, prev stored) (bool, error) {
	switch {
	case s.token != "":
		if prev.id == 0 || cur.Token != s.token || cur.PID == 0 {
			return false, exitcode.New(exitcode.Coordination,
				"this session's lease token is no longer on the Epic; oe never re-acquires mid-session")
		}
		return false, nil
	case prev.id == 0 || cur.PID == 0:
		return false, nil
	case cur.Host == s.host && !s.alive(cur.PID):
		return true, nil
	default:
		return false, foreign(cur)
	}
}

// Verify confirms this session still holds the Epic's lease before a mutating command, and
// renews it when it is a minute old. A lease that is gone, ended, or under another token is
// exit 7: the session stops and never re-acquires.
func (s *Session) Verify(ctx context.Context) error {
	cur, prev, err := s.held(ctx)
	if err != nil {
		return err
	}
	now, err := s.clock(ctx)
	if err != nil {
		return err
	}
	if renewed, perr := time.Parse(time.RFC3339, cur.RenewedAt); perr == nil {
		if t, _ := time.Parse(time.RFC3339, now); t.Sub(renewed) < RenewEvery {
			return nil
		}
	}
	cur.RenewedAt = now
	return s.saveLease(ctx, prev, &cur)
}

// End ends the session cleanly: the lease stays, with pid 0, so the next session takes it.
func (s *Session) End(ctx context.Context) (LeaseResult, error) {
	cur, prev, err := s.held(ctx)
	if err != nil {
		return LeaseResult{}, err
	}
	now, err := s.clock(ctx)
	if err != nil {
		return LeaseResult{}, err
	}
	cur.PID, cur.RenewedAt = 0, now
	if err := s.saveLease(ctx, prev, &cur); err != nil {
		return LeaseResult{}, err
	}
	return leaseResult(cur, false), nil
}

// checkLease is the lease check that precedes every write.
func (s *Session) checkLease(ctx context.Context) error {
	_, _, err := s.held(ctx)
	return err
}

// held reads the lease and confirms this session holds it.
func (s *Session) held(ctx context.Context) (state.Lease, stored, error) {
	if s.token == "" {
		return state.Lease{}, stored{}, exitcode.New(exitcode.Usage, "--lease-token is required; run oe lease acquire first")
	}
	cur, prev, err := s.readLease(ctx)
	if err != nil {
		return state.Lease{}, stored{}, err
	}
	switch {
	case prev.id == 0:
		return state.Lease{}, stored{}, exitcode.New(exitcode.Coordination, "the Epic has no lease; this session lost it and never re-acquires mid-session")
	case cur.Token != s.token:
		return state.Lease{}, stored{}, foreign(cur)
	case cur.PID == 0:
		return state.Lease{}, stored{}, exitcode.New(exitcode.Coordination, "this session's lease was ended; it never re-acquires mid-session")
	}
	return cur, prev, nil
}

// saveLease writes the lease. It is the one state write that does not check the lease first,
// since it is what takes it; the revision check still stops a concurrent writer.
func (s *Session) saveLease(ctx context.Context, prev stored, next *state.Lease) error {
	return s.write(ctx, s.in.Epic, prev, next, decodeLease, confirmLanded)
}

func (s *Session) clock(ctx context.Context) (string, error) {
	t, err := s.now(ctx)
	if err != nil {
		return "", err
	}
	return t.UTC().Format(time.RFC3339), nil
}

func newToken() (string, error) {
	b := make([]byte, tokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", exitcode.Wrap(exitcode.Refused, err, "cannot make a lease token")
	}
	return hex.EncodeToString(b), nil
}
