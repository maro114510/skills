// Package coord is the loop's durable coordination, contract §4 to §8: the host-wide lock and
// the lease that keep one Publisher per Epic, the ledger that reserves budget before every
// spawn and owns freeze and release, the named transitions that are the only way an Issue
// state changes, and the single writer through which every loop comment is posted.
//
// Every write goes through a Session, after a full read, with the lease checked first. A
// state edit re-reads its comment and stops with exit 7 when the revision moved since the
// read. Nothing here deletes a comment, and nothing here reads or writes a label.
package coord

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/scan"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// MaxBody is GitHub's comment size limit, in characters.
const MaxBody = 65536

// maxBodyBytes keeps a body, passed to gh as one `body=<text>` argument, under Linux's 128 KiB
// limit on a single argument, which multi-byte text reaches before GitHub's character limit.
const maxBodyBytes = 128*1024 - 1024

// checkBody applies publishable to a state body. The lease is only size-checked: every field of
// it is oe's own, and its token is a session identifier the scan would read as a credential.
func checkBody(env *protocol.Envelope, body string) error {
	if env.Entity == state.EntityLease {
		if utf8.RuneCountInString(body) > MaxBody || len(body) > maxBodyBytes {
			return exitcode.New(exitcode.Refused, "the lease would exceed the comment size limit")
		}
		return nil
	}
	return publishable("state "+env.Key, body)
}

// publishable refuses a body GitHub or the argument list cannot take, or one the secret scan
// finds anything in. It runs before any request, so a refused body is never published.
func publishable(what, body string) error {
	if utf8.RuneCountInString(body) > MaxBody || len(body) > maxBodyBytes {
		return exitcode.New(exitcode.Refused, what+" would exceed the comment size limit; nothing was written")
	}
	if report := scan.Text(what, []byte(body)); !report.Clean {
		rules := make([]string, 0, len(report.Findings))
		for _, f := range report.Findings {
			rules = append(rules, f.Rule)
		}
		return exitcode.New(exitcode.Refused, what+" holds a suspected secret ("+strings.Join(rules, ", ")+"); nothing was written")
	}
	return nil
}

// Config is what a Session runs with. Host, Alive, and Now default to the real host name,
// process table, and GitHub's clock.
type Config struct {
	Client *gh.Client
	Inputs inputs.Inputs
	// Token is this session's lease token. Every mutating call but Acquire needs it.
	Token string
	// LockDir is the directory of the host-wide locks.
	LockDir string
	Host    string
	Alive   func(pid int) bool
	Now     func(ctx context.Context) (time.Time, error)
}

// Session is one oe process acting for one Publisher session on one Epic.
type Session struct {
	c       *gh.Client
	in      inputs.Inputs
	owner   string
	name    string
	token   string
	lockDir string
	host    string
	alive   func(int) bool
	now     func(context.Context) (time.Time, error)
	lock    *lock
}

// New returns a Session. It makes no call and takes no lock.
func New(cfg Config) *Session {
	owner, name, _ := strings.Cut(cfg.Inputs.Repo, "/")
	s := &Session{
		c: cfg.Client, in: cfg.Inputs, owner: owner, name: name, token: cfg.Token, lockDir: cfg.LockDir,
		host: cfg.Host, alive: cfg.Alive, now: cfg.Now, lock: nil,
	}
	if s.alive == nil {
		s.alive = processAlive
	}
	if s.now == nil {
		s.now = func(ctx context.Context) (time.Time, error) { return snapshot.Now(ctx, s.c) }
	}
	return s
}

// Lock takes the host-wide lock of the Epic. Held by another process is exit 7.
func (s *Session) Lock() error {
	if s.lockDir == "" {
		return exitcode.New(exitcode.Usage, "no lock directory")
	}
	l, err := acquireLock(LockPath(s.lockDir, s.in.Repo, s.in.Epic))
	if err != nil {
		return err
	}
	s.lock = l
	return nil
}

// Close releases the lock.
func (s *Session) Close() { s.lock.release() }

// Token is the session's lease token.
func (s *Session) Token() string { return s.token }

// comments is one full read of an Issue's comments, indexed.
type comments struct {
	list []snapshot.Comment
	idx  protocol.Index
}

// highest is the highest comment ID read, or 0.
func (r comments) highest() int64 {
	var top int64
	for _, c := range r.list {
		top = max(top, c.ID)
	}
	return top
}

// read reads every comment of an Issue and indexes the loop's own. A v1 marker, a bad state,
// or a duplicate state stops with exit 6.
func (s *Session) read(ctx context.Context, n int) (comments, error) {
	byIssue, err := snapshot.ReadComments(ctx, s.c, s.in.Repo, []int{n})
	if err != nil {
		return comments{}, err
	}
	list := byIssue[n]
	pcs := make([]protocol.Comment, 0, len(list))
	for _, c := range list {
		pcs = append(pcs, c.Protocol())
	}
	idx, err := protocol.Scan(pcs, s.in.Me)
	if err != nil {
		return comments{}, fmt.Errorf("#%d: %w", n, err)
	}
	return comments{list: list, idx: idx}, nil
}

// decode reads the state comment for key into v, checking its entity. It returns the comment
// ID, or 0 when there is none.
func (r comments) decode(key, entity string, v protocol.State) (int64, error) {
	c, ok := r.idx.States[key]
	if !ok {
		return 0, nil
	}
	if _, err := protocol.DecodeState(c.Body, v); err != nil {
		return 0, fmt.Errorf("comment %d: %w", c.ID, err)
	}
	if got := v.StateEnvelope().Entity; got != entity {
		return 0, exitcode.New(exitcode.Protocol, fmt.Sprintf("comment %d: state %q is a %q, not a %q", c.ID, key, got, entity))
	}
	return c.ID, nil
}

// noteID is the lowest ID of the loop's notes with this key, or 0.
func (r comments) noteID(key string) int64 {
	var low int64
	for _, c := range r.idx.Notes[key] {
		if low == 0 || c.ID < low {
			low = c.ID
		}
	}
	return low
}

// stored is a state comment as read: its ID, 0 when absent, and its revision.
type stored struct {
	id       int64
	revision int64
}

// writeMode says what a failed write may still count as.
type writeMode int

const (
	// confirmLanded re-reads after a failed write and takes an intended object it finds stored
	// as done, contract §8.
	confirmLanded writeMode = iota
	// neverConfirm takes every failed write as failed. A reservation is spent if it landed,
	// but it grants nothing until its write succeeded, contract §8.
	neverConfirm
)

// saveState writes next as the state comment for its key on Issue on, after checking the
// lease.
func (s *Session) saveState(ctx context.Context, on int, prev stored, next protocol.State, decodeAs func() protocol.State, mode writeMode) error {
	if err := s.checkLease(ctx); err != nil {
		return err
	}
	return s.write(ctx, on, prev, next, decodeAs, mode)
}

// write sets the revision and the writer of next and writes it, editing the comment read as
// prev only when its revision has not moved since that read.
func (s *Session) write(ctx context.Context, on int, prev stored, next protocol.State, decodeAs func() protocol.State, mode writeMode) error {
	env := next.StateEnvelope()
	env.Revision = prev.revision + 1
	env.UpdatedBy = s.token
	body, err := protocol.EncodeState(next)
	if err != nil {
		return err
	}
	if err := checkBody(env, body); err != nil {
		return err
	}
	if prev.id == 0 {
		return s.createState(ctx, on, env.Key, body, decodeAs, mode)
	}
	if err := s.checkRevision(ctx, prev, env.Key, decodeAs); err != nil {
		return err
	}
	path := fmt.Sprintf("repos/%s/%s/issues/comments/%d", s.owner, s.name, prev.id)
	if _, err := s.c.Write(ctx, "api", "-X", http.MethodPatch, path, "-f", "body="+body); err != nil {
		if mode == confirmLanded && s.landed(ctx, prev.id, body, decodeAs) {
			return nil
		}
		return exitcode.Wrap(exitcode.Unreadable, err, fmt.Sprintf("state %q was not written; redo from a fresh read", env.Key))
	}
	return nil
}

func (s *Session) createState(ctx context.Context, on int, key, body string, decodeAs func() protocol.State, mode writeMode) error {
	// The create analog of the revision check: a state created since the read is another writer.
	r, err := s.read(ctx, on)
	if err != nil {
		return err
	}
	if c, ok := r.idx.States[key]; ok {
		return exitcode.New(exitcode.Coordination, fmt.Sprintf(
			"state %q was created as comment %d since it was read; another writer is active, so nothing was written", key, c.ID))
	}
	path := fmt.Sprintf("repos/%s/%s/issues/%d/comments", s.owner, s.name, on)
	out, err := s.c.Write(ctx, "api", "-X", http.MethodPost, path, "-f", "body="+body)
	if err == nil {
		_, err = postedID(out)
		return err
	}
	if mode == confirmLanded {
		if r, rerr := s.read(ctx, on); rerr == nil {
			if c, ok := r.idx.States[key]; ok && sameState(c.Body, body, decodeAs) {
				return nil
			}
		}
	}
	return exitcode.Wrap(exitcode.Unreadable, err, fmt.Sprintf("state %q was not created; redo from a fresh read", key))
}

// checkRevision re-reads the comment and stops with exit 7 when its revision moved.
func (s *Session) checkRevision(ctx context.Context, prev stored, key string, decodeAs func() protocol.State) error {
	body, author, err := s.getComment(ctx, prev.id)
	if err != nil {
		return err
	}
	cur := decodeAs()
	if author != s.in.Me {
		return exitcode.New(exitcode.Coordination, fmt.Sprintf("state %q comment %d is no longer the loop's own", key, prev.id))
	}
	if _, err := protocol.DecodeState(body, cur); err != nil {
		return fmt.Errorf("comment %d: %w", prev.id, err)
	}
	if got := cur.StateEnvelope().Revision; got != prev.revision {
		return exitcode.New(exitcode.Coordination, fmt.Sprintf(
			"state %q moved from revision %d to %d since it was read; another writer is active, so nothing was written", key, prev.revision, got))
	}
	return nil
}

// landed re-reads a comment after a failed edit and reports whether it holds the intended body.
func (s *Session) landed(ctx context.Context, id int64, body string, decodeAs func() protocol.State) bool {
	got, _, err := s.getComment(ctx, id)
	return err == nil && sameState(got, body, decodeAs)
}

func sameState(got, want string, decodeAs func() protocol.State) bool {
	a, b := decodeAs(), decodeAs()
	if _, err := protocol.DecodeState(got, a); err != nil {
		return false
	}
	if _, err := protocol.DecodeState(want, b); err != nil {
		return false
	}
	ea, errA := protocol.EncodeState(a)
	eb, errB := protocol.EncodeState(b)
	return errA == nil && errB == nil && ea == eb
}

type restComment struct {
	ID   int64  `json:"id"`
	Body string `json:"body"`
	User *struct {
		Login string `json:"login"`
	} `json:"user"`
}

// getComment reads one comment by ID.
func (s *Session) getComment(ctx context.Context, id int64) (string, string, error) {
	out, err := s.c.Read(ctx, "api", fmt.Sprintf("repos/%s/%s/issues/comments/%d", s.owner, s.name, id))
	if err != nil {
		return "", "", err
	}
	var c restComment
	if err := json.Unmarshal(out, &c); err != nil || c.ID != id || c.User == nil {
		return "", "", exitcode.New(exitcode.Unreadable, "comment "+strconv.FormatInt(id, 10)+" was not read")
	}
	return c.Body, c.User.Login, nil
}

func postedID(out []byte) (int64, error) {
	var c restComment
	if err := json.Unmarshal(out, &c); err != nil || c.ID <= 0 {
		return 0, exitcode.New(exitcode.Unreadable, "the posted comment's ID was not returned; re-read before acting on it")
	}
	return c.ID, nil
}

func decodeIssue() protocol.State  { return new(state.Issue) }
func decodeLedger() protocol.State { return new(state.Ledger) }
func decodeLease() protocol.State  { return new(state.Lease) }
