package coord

import (
	"context"
	"fmt"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// The budget per dispatchable Issue, contract §4.2.
const (
	WorkerDispatchesPerIssue = 5
	ReviewerPassesPerIssue   = 4
	FixCyclesPerIssue        = 2
)

// The freeze statuses of a ledger.
const (
	StatusClear  = "CLEAR"
	StatusFrozen = "FROZEN"
)

// Request is a reservation against the Epic-wide budget. A batch reserves as a whole.
type Request struct {
	WorkerDispatches int `json:"worker_dispatches"`
	ReviewerPasses   int `json:"reviewer_passes"`
	FixCycles        int `json:"fix_cycles"`
}

func (r Request) empty() bool {
	return r.WorkerDispatches == 0 && r.ReviewerPasses == 0 && r.FixCycles == 0
}

func (r Request) valid() bool {
	return r.WorkerDispatches >= 0 && r.ReviewerPasses >= 0 && r.FixCycles >= 0
}

// Grant is a reservation whose ledger write succeeded. Only Session.Reserve returns one, so a
// spawn or a fix cycle that needs a Grant cannot happen before the write is confirmed.
type Grant struct {
	req      Request
	revision int64
}

// Request is what the grant reserved.
func (g Grant) Request() Request { return g.req }

func (g Grant) confirmed() bool { return g.revision > 0 }

// LedgerResult reports the ledger after a ledger command.
type LedgerResult struct {
	Status   string        `json:"status"`
	Reason   string        `json:"reason"`
	Ledger   *state.Ledger `json:"ledger"`
	Granted  bool          `json:"granted"`
	Request  *Request      `json:"request,omitempty"`
	Released bool          `json:"released"`
	Release  int64         `json:"release,omitempty"`
	Freeze   *state.Freeze `json:"freeze,omitempty"`
	Note     *NoteResult   `json:"note,omitempty"`
}

func newLedgerResult(l *state.Ledger) LedgerResult {
	return LedgerResult{
		Status: ledgerStatus(l), Reason: "", Ledger: l, Granted: false, Request: nil,
		Released: false, Release: 0, Freeze: nil, Note: nil,
	}
}

// NewLedger is the ledger for n dispatchable Issues not done, at least 1.
func NewLedger(n int) state.Ledger {
	var l state.Ledger
	l.Entity, l.Key = state.EntityLedger, state.KeyLedger
	setBounds(&l, n)
	return l
}

func setBounds(l *state.Ledger, n int) {
	n = max(n, 1)
	l.N = n
	l.Counters = state.Counters{
		WorkerDispatches: state.Counter{Used: 0, Bound: WorkerDispatchesPerIssue * n},
		ReviewerPasses:   state.Counter{Used: 0, Bound: ReviewerPassesPerIssue * n},
		FixCycles:        state.Counter{Used: 0, Bound: FixCyclesPerIssue * n},
	}
}

// frozen reports whether a freeze holds the Epic.
func frozen(l *state.Ledger) bool { return l != nil && l.Freeze != nil && !l.Freeze.Released }

func ledgerStatus(l *state.Ledger) string {
	if frozen(l) {
		return StatusFrozen
	}
	return StatusClear
}

// ValidateLedger rejects a ledger no transition may write: a counter above its bound, bounds
// that are not the budget of n, or a freeze whose sequence is not the latest.
func ValidateLedger(l *state.Ledger) error {
	if l.N < 1 {
		return refused("ledger n %d is below 1", l.N)
	}
	for _, c := range []struct {
		name string
		c    state.Counter
		per  int
	}{
		{"worker_dispatches", l.Counters.WorkerDispatches, WorkerDispatchesPerIssue},
		{"reviewer_passes", l.Counters.ReviewerPasses, ReviewerPassesPerIssue},
		{"fix_cycles", l.Counters.FixCycles, FixCyclesPerIssue},
	} {
		if c.c.Used < 0 || c.c.Used > c.c.Bound || c.c.Bound != c.per*l.N {
			return refused("ledger %s %d / %d is not within the budget of n=%d", c.name, c.c.Used, c.c.Bound, l.N)
		}
	}
	if l.Freeze != nil && l.Freeze.Seq != l.FreezeSeq {
		return refused("ledger freeze %d is not the latest freeze %d", l.Freeze.Seq, l.FreezeSeq)
	}
	return nil
}

// reserve adds a request to a clear ledger. It returns the reason when a counter would exceed
// its bound; nothing is reserved then.
func reserve(l state.Ledger, req Request) (state.Ledger, string) {
	var over []string
	add := func(name string, c *state.Counter, k int) {
		if c.Used+k > c.Bound {
			over = append(over, fmt.Sprintf("%s %d + %d > %d", name, c.Used, k, c.Bound))
		}
		c.Used += k
	}
	add("worker_dispatches", &l.Counters.WorkerDispatches, req.WorkerDispatches)
	add("reviewer_passes", &l.Counters.ReviewerPasses, req.ReviewerPasses)
	add("fix_cycles", &l.Counters.FixCycles, req.FixCycles)
	return l, strings.Join(over, "; ")
}

// freezeLedger records a freeze on a ledger no freeze holds.
func freezeLedger(l state.Ledger, reason, merge, health string) state.Ledger {
	l.FreezeSeq++
	l.Freeze = &state.Freeze{Seq: l.FreezeSeq, Reason: reason, MergeSHA: merge, Health: health, Released: false}
	return l
}

// releaseComment is the epic-release that lifts a freeze: the lowest-ID trusted strict
// epic-release above both the release watermark and the freeze note, or 0.
func releaseComment(list []snapshot.Comment, watermark, freezeNote int64) int64 {
	var low int64
	for _, c := range list {
		if c.ID <= watermark || c.ID <= freezeNote || !signals.Trusted(c.Association, c.Body) {
			continue
		}
		if signals.Parse(c.Body) == signals.Release && (low == 0 || c.ID < low) {
			low = c.ID
		}
	}
	return low
}

// releaseLedger lifts the freeze: it keeps the record with released set, for health to read
// as history, resets the budget to the bounds of n, and consumes the release comment.
func releaseLedger(l state.Ledger, n int, comment int64) state.Ledger {
	f := *l.Freeze
	f.Released = true
	l.Freeze = &f
	setBounds(&l, n)
	l.ReleaseWatermark = max(l.ReleaseWatermark, comment)
	return l
}

// ledgerRead is the Epic's comments and its ledger as read.
type ledgerRead struct {
	r    comments
	l    *state.Ledger
	prev stored
}

func (s *Session) readLedger(ctx context.Context) (ledgerRead, error) {
	r, err := s.read(ctx, s.in.Epic)
	if err != nil {
		return ledgerRead{}, err
	}
	var l state.Ledger
	id, err := r.decode(state.KeyLedger, state.EntityLedger, &l)
	if err != nil {
		return ledgerRead{}, err
	}
	out := ledgerRead{r: r, l: nil, prev: stored{id: id, revision: l.Revision}}
	if id != 0 {
		out.l = &l
	}
	return out, nil
}

// noted makes sure the note of a ledger's current freeze is posted, contract §4.2: any read of
// a frozen ledger posts a missing one before reading a release. It returns the note's ID.
func (s *Session) noted(ctx context.Context, lr ledgerRead) (NoteResult, error) {
	f := lr.l.Freeze
	return s.PostNote(ctx, s.in.Epic, fmt.Sprintf("freeze:%d", f.Seq), freezeText(lr.l))
}

func freezeText(l *state.Ledger) string {
	f := l.Freeze
	c := l.Counters
	var b strings.Builder
	b.WriteString("この Epic を凍結しました。dispatch、レビュー、ship、merge はすべて止まっています。\n\n")
	fmt.Fprintf(&b, "- 理由: %s\n", oneLine(f.Reason))
	if f.MergeSHA != "" {
		fmt.Fprintf(&b, "- merge: %s\n- health: %s\n", f.MergeSHA, f.Health)
	}
	fmt.Fprintf(&b, "- worker_dispatches: %d / %d\n- reviewer_passes: %d / %d\n- fix_cycles: %d / %d\n\n",
		c.WorkerDispatches.Used, c.WorkerDispatches.Bound, c.ReviewerPasses.Used, c.ReviewerPasses.Bound,
		c.FixCycles.Used, c.FixCycles.Bound)
	b.WriteString("再開するには、`epic-release` だけを書いたコメントをこの Epic に投稿してください。予算はその時点の未完了 Issue 数で再計算されます。")
	return b.String()
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// CreateLedger creates the Epic's ledger for n dispatchable Issues not done. A ledger that
// exists is left as it is: bounds change only on a release.
func (s *Session) CreateLedger(ctx context.Context, n int) (LedgerResult, error) {
	lr, err := s.readLedger(ctx)
	if err != nil {
		return LedgerResult{}, err
	}
	if lr.l != nil {
		res := newLedgerResult(lr.l)
		res.Reason = "the ledger exists; bounds change only on a release"
		return res, nil
	}
	l := NewLedger(n)
	if err := s.saveLedger(ctx, lr.prev, &l, confirmLanded); err != nil {
		return LedgerResult{}, err
	}
	res := newLedgerResult(&l)
	res.Reason = "created"
	return res, nil
}

func (s *Session) saveLedger(ctx context.Context, prev stored, l *state.Ledger, mode writeMode) error {
	if err := ValidateLedger(l); err != nil {
		return err
	}
	return s.saveState(ctx, s.in.Epic, prev, l, decodeLedger, mode)
}

// Reserve reserves a request before a spawn, contract §8. It needs the ledger and a freeze
// status of CLEAR. A request that does not fit freezes the Epic instead and reserves nothing.
// Only a confirmed write grants: a failed write grants nothing, even if it may have landed.
func (s *Session) Reserve(ctx context.Context, req Request) (Grant, LedgerResult, error) {
	if !req.valid() || req.empty() {
		return Grant{}, LedgerResult{}, exitcode.New(exitcode.Usage, "a reservation needs at least one positive count and no negative one")
	}
	lr, res, err := s.clearLedger(ctx)
	if err != nil {
		return Grant{}, res, err
	}
	next, over := reserve(*lr.l, req)
	if over != "" {
		fr, ferr := s.freeze(ctx, lr, over, "", "")
		return Grant{}, fr, ferr
	}
	if err := s.saveLedger(ctx, lr.prev, &next, neverConfirm); err != nil {
		return Grant{}, newLedgerResult(lr.l), err
	}
	res = newLedgerResult(&next)
	res.Granted, res.Request, res.Reason = true, &req, "within bounds"
	return Grant{req: req, revision: next.Revision}, res, nil
}

// Check is the freeze check without a reservation, for a pass that is not charged. It posts a
// missing freeze note and stops with exit 4 on a frozen Epic.
func (s *Session) Check(ctx context.Context) (LedgerResult, error) {
	_, res, err := s.clearLedger(ctx)
	return res, err
}

// clearLedger reads the ledger and stops unless it exists and no freeze holds it.
func (s *Session) clearLedger(ctx context.Context) (ledgerRead, LedgerResult, error) {
	lr, err := s.readLedger(ctx)
	if err != nil {
		return lr, LedgerResult{}, err
	}
	if lr.l == nil {
		return lr, LedgerResult{}, exitcode.New(exitcode.Refused, "the Epic has no ledger to reserve against; create it first")
	}
	res := newLedgerResult(lr.l)
	if frozen(lr.l) {
		note, err := s.noted(ctx, lr)
		res.Note, res.Freeze, res.Reason = &note, lr.l.Freeze, lr.l.Freeze.Reason
		if err != nil {
			return lr, res, err
		}
		return lr, res, exitcode.New(exitcode.Stop, "the Epic is frozen: "+oneLine(lr.l.Freeze.Reason)+"; only an epic-release lifts it")
	}
	return lr, res, nil
}

// Freeze freezes the Epic, contract §8: the ledger write first, then the note freeze:<seq>.
// A frozen Epic is never frozen twice; its missing note is posted instead. It always stops
// with exit 4, since nothing may act after it.
func (s *Session) Freeze(ctx context.Context, reason, merge, health string) (LedgerResult, error) {
	if strings.TrimSpace(reason) == "" {
		return LedgerResult{}, exitcode.New(exitcode.Usage, "a freeze needs its reason")
	}
	lr, err := s.readLedger(ctx)
	if err != nil {
		return LedgerResult{}, err
	}
	if lr.l == nil {
		return LedgerResult{}, exitcode.New(exitcode.Refused, "the Epic has no ledger to record the freeze in; create it first")
	}
	if frozen(lr.l) {
		res := newLedgerResult(lr.l)
		note, err := s.noted(ctx, lr)
		res.Note, res.Freeze, res.Reason = &note, lr.l.Freeze, "already frozen; a second freeze is never written"
		if err != nil {
			return res, err
		}
		return res, exitcode.New(exitcode.Stop, "the Epic was already frozen: "+oneLine(lr.l.Freeze.Reason))
	}
	return s.freeze(ctx, lr, reason, merge, health)
}

func (s *Session) freeze(ctx context.Context, lr ledgerRead, reason, merge, health string) (LedgerResult, error) {
	next := freezeLedger(*lr.l, oneLine(reason), merge, health)
	// The note must be postable before the freeze is written: a freeze whose note is refused
	// could never be released, since every later read posts the missing note first.
	if _, _, err := prepareNote(s.in.Epic, fmt.Sprintf("freeze:%d", next.Freeze.Seq), freezeText(&next)); err != nil {
		return newLedgerResult(lr.l), err
	}
	if err := s.saveLedger(ctx, lr.prev, &next, confirmLanded); err != nil {
		return newLedgerResult(lr.l), err
	}
	res := newLedgerResult(&next)
	res.Freeze, res.Reason = next.Freeze, next.Freeze.Reason
	note, err := s.noted(ctx, ledgerRead{r: lr.r, l: &next, prev: lr.prev})
	res.Note = &note
	if err != nil {
		return res, err
	}
	return res, exitcode.New(exitcode.Stop, "the Epic is frozen: "+next.Freeze.Reason+"; only an epic-release lifts it")
}

// Release applies an epic-release to a frozen Epic, contract §6: the lowest-ID trusted strict
// epic-release above the release watermark and the freeze note lifts the freeze, resets the
// budget to n, and is consumed, so reading it again resets nothing. With none, the Epic stays
// frozen: exit 4.
func (s *Session) Release(ctx context.Context, n int) (LedgerResult, error) {
	lr, err := s.readLedger(ctx)
	if err != nil {
		return LedgerResult{}, err
	}
	if lr.l == nil {
		return LedgerResult{}, exitcode.New(exitcode.Refused, "the Epic has no ledger, so there is no freeze to release")
	}
	res := newLedgerResult(lr.l)
	if !frozen(lr.l) {
		res.Reason = "no freeze holds the Epic; nothing to release"
		return res, nil
	}
	note, err := s.noted(ctx, lr)
	res.Note, res.Freeze = &note, lr.l.Freeze
	if err != nil {
		return res, err
	}
	// The note may have been posted just now, so read the window after it.
	again, err := s.readLedger(ctx)
	if err != nil {
		return res, err
	}
	if again.prev.revision != lr.prev.revision {
		return res, exitcode.New(exitcode.Coordination, "the ledger moved while its freeze note was checked; nothing was released")
	}
	id := releaseComment(again.r.list, again.l.ReleaseWatermark, note.CommentID)
	if id == 0 {
		res.Reason = "no trusted epic-release after the freeze note"
		return res, exitcode.New(exitcode.Stop, "the Epic stays frozen: "+oneLine(lr.l.Freeze.Reason))
	}
	next := releaseLedger(*again.l, n, id)
	if err := s.saveLedger(ctx, again.prev, &next, confirmLanded); err != nil {
		return res, err
	}
	res = newLedgerResult(&next)
	res.Released, res.Release, res.Freeze = true, id, next.Freeze
	res.Reason = fmt.Sprintf("epic-release %d lifted freeze %d; the budget was reset for n=%d", id, next.Freeze.Seq, next.N)
	return res, nil
}
