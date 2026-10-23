package coord

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/scan"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// MaxCycle is the fix-cycle cap per Issue.
const MaxCycle = 2

// The worker report statuses.
const (
	StatusDone    = "DONE"
	StatusBlocked = "BLOCKED"
	StatusFailed  = "FAILED"
)

// The criterion results and kinds review evidence may carry.
const (
	ResultVerified = "verified"
	KindBehavior   = "behavior"
	KindStatic     = "static"
)

// Transition is one of the named transitions of contract §5. The set is closed: a state
// changes only through the transitions this package defines.
type Transition interface {
	// Name is the transition's contract name.
	Name() string
	apply(in applyInput) (*state.Issue, error)
}

// applyInput is what a transition reads: the Issue, its current state or nil, and the full
// read its write follows.
type applyInput struct {
	n   int
	cur *state.Issue
	r   comments
}

func refused(format string, args ...any) error {
	return exitcode.New(exitcode.Refused, fmt.Sprintf(format, args...))
}

func needState(in applyInput, name string) error {
	if in.cur == nil {
		return refused("#%d has no state; %s needs one, and only start creates it", in.n, name)
	}
	return nil
}

// Start creates an Issue's state at dispatch: cycle 0, no head, no approval, and the signal
// watermark at the highest comment ID read, so earlier comments are never signals.
type Start struct {
	// Branch is the branch to record; empty means feat/issue-<n>.
	Branch string
}

// Name implements Transition.
func (Start) Name() string { return "start" }

func (t Start) apply(in applyInput) (*state.Issue, error) {
	if in.cur != nil {
		return nil, refused("#%d already has a state; start creates it only once", in.n)
	}
	branch := t.Branch
	if branch == "" {
		branch = fmt.Sprintf("%s%d", snapshot.BranchPrefix, in.n)
	}
	st := emptyIssue(in.n, branch)
	st.SignalWatermark = in.r.highest()
	return &st, nil
}

func emptyIssue(n int, branch string) state.Issue {
	var st state.Issue
	st.Entity, st.Key = state.EntityIssue, state.IssueKey(n)
	st.Branch = branch
	st.PendingFindings, st.UnresolvedBlockers, st.Context = []string{}, []string{}, []state.Context{}
	return st
}

// Report is the part of a worker report a transition checks.
type Report struct {
	Status   string
	Issue    int
	Branch   string
	Worktree string
	HeadSHA  string
	Error    string
}

// WorkerResult records a worker report whose Issue, branch, and worktree match. DONE records
// the head, resets failures, clears approval, and empties the pending findings it answered. BLOCKED is recorded only after its question
// note exists. FAILED counts a failure; a second in a row parks the Issue. A BLOCKED or FAILED
// report that carries a head the worker committed records it too.
type WorkerResult struct {
	Report Report
	// Worktree is the worktree the worker was dispatched to.
	Worktree string
	// QuestionKey is the blocked note a BLOCKED report needs posted first.
	QuestionKey string
}

// Name implements Transition.
func (WorkerResult) Name() string { return "record_worker_result" }

func (t WorkerResult) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	rep := t.Report
	if rep.Issue != in.n || rep.Branch != in.cur.Branch || rep.Worktree == "" || rep.Worktree != t.Worktree {
		return nil, refused("the report names #%d on %q in %q, not #%d on %q in %q; it is not this dispatch's",
			rep.Issue, rep.Branch, rep.Worktree, in.n, in.cur.Branch, t.Worktree)
	}
	st := cloneIssue(in.cur)
	return st, t.record(st, in.r)
}

func (t WorkerResult) record(st *state.Issue, r comments) error {
	rep := t.Report
	switch rep.Status {
	case StatusDone:
		if rep.HeadSHA == "" {
			return refused("a DONE report needs its head SHA")
		}
		// DONE ends the fix cycle in flight, so the same findings on the next review count against the cap and never read as a replay.
		st.HeadSHA, st.ConsecutiveFailures, st.Approval, st.PendingFindings = &rep.HeadSHA, 0, nil, []string{}
	case StatusBlocked:
		if t.QuestionKey == "" || r.noteID(t.QuestionKey) == 0 {
			return refused("a BLOCKED report is recorded only after its question note %q is posted", t.QuestionKey)
		}
		movedHead(st, rep.HeadSHA)
	case StatusFailed:
		movedHead(st, rep.HeadSHA)
		st.ConsecutiveFailures++
		if st.ConsecutiveFailures > 1 {
			park(st, []string{"two FAILED reports in a row: " + rep.Error})
		}
	default:
		return refused("report status %q is not DONE, BLOCKED, or FAILED", rep.Status)
	}
	return nil
}

// movedHead records a head a BLOCKED or FAILED worker committed before it stopped, read by oe
// from the worktree, so the next dispatch starts from it instead of stopping on a divergence.
// An empty head, or the recorded one, changes nothing.
func movedHead(st *state.Issue, head string) {
	if head == "" || (st.HeadSHA != nil && *st.HeadSHA == head) {
		return
	}
	st.HeadSHA, st.Approval = &head, nil
}

// RecordHead records a head oe made itself or synced to, and clears approval.
type RecordHead struct {
	SHA string
}

// Name implements Transition.
func (RecordHead) Name() string { return "record_head" }

func (t RecordHead) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	if t.SHA == "" {
		return nil, refused("record_head needs a SHA")
	}
	st := cloneIssue(in.cur)
	st.HeadSHA, st.Approval = &t.SHA, nil
	return st, nil
}

// BeginFix hands findings to a fix cycle. It needs a confirmed ledger reservation of a fix
// cycle, which only Session.Reserve returns, and a cycle below the cap.
type BeginFix struct {
	Findings []string
	Grant    Grant
	// Repair, when set, records the repair this fix cycle is.
	Repair *state.Repair
}

// Name implements Transition.
func (BeginFix) Name() string { return "begin_fix" }

func (t BeginFix) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	switch {
	case !t.Grant.confirmed() || t.Grant.req.FixCycles < 1:
		return nil, refused("begin_fix needs a confirmed reservation of a fix cycle")
	case in.cur.Cycle >= MaxCycle:
		return nil, refused("#%d is at the fix-cycle cap of %d; park it instead", in.n, MaxCycle)
	case len(t.Findings) == 0:
		return nil, refused("begin_fix needs the findings to fix")
	}
	st := cloneIssue(in.cur)
	st.PendingFindings, st.Approval = slices.Clone(t.Findings), nil
	st.Cycle++
	if t.Repair != nil {
		r := *t.Repair
		st.Repair = &r
	}
	return st, nil
}

// BindApproval binds a verdict while its pins are unchanged: the reviewed head is the recorded
// head and the current head, the verified base is the current base, the evidence holds and is
// scanned, and the review left no finding.
type BindApproval struct {
	Approval state.Approval
	// Head and Base are the head and base read right before binding.
	Head string
	Base string
	// Findings are the review's own findings, nits included; any one binds nothing.
	Findings []string
}

// Name implements Transition.
func (BindApproval) Name() string { return "bind_approval" }

func (t BindApproval) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	a := t.Approval
	switch {
	case in.cur.HeadSHA == nil || *in.cur.HeadSHA != a.ReviewedSHA || t.Head != a.ReviewedSHA:
		return nil, exitcode.New(exitcode.Stale, "the reviewed head is not the recorded and current head; nothing binds")
	case t.Base != a.VerifiedBase:
		return nil, exitcode.New(exitcode.Stale, "the verified base is not the current base; nothing binds")
	case len(t.Findings) > 0:
		return nil, refused("the review left %d finding(s); nothing binds", len(t.Findings))
	}
	if err := validEvidence(a.ReviewEvidence); err != nil {
		return nil, err
	}
	raw, err := json.Marshal(a.ReviewEvidence)
	if err != nil {
		return nil, exitcode.Wrap(exitcode.Refused, err, "review evidence cannot be encoded")
	}
	if report := scan.Text("review-evidence", raw); !report.Clean {
		return nil, refused("the review evidence holds a suspected secret; nothing binds")
	}
	st := cloneIssue(in.cur)
	ev := a.ReviewEvidence
	ev.Criteria = slices.Clone(ev.Criteria)
	st.Approval = &state.Approval{ReviewedSHA: a.ReviewedSHA, VerifiedBase: a.VerifiedBase, ReviewEvidence: ev}
	st.PendingFindings, st.UnresolvedBlockers = []string{}, []string{}
	return st, nil
}

// InvalidateApproval clears a bound approval.
type InvalidateApproval struct{}

// Name implements Transition.
func (InvalidateApproval) Name() string { return "invalidate_approval" }

func (t InvalidateApproval) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	if in.cur.Approval == nil {
		return nil, refused("#%d has no approval to invalidate", in.n)
	}
	st := cloneIssue(in.cur)
	st.Approval = nil
	return st, nil
}

// Park records what parks the Issue for a person, empties pending findings, and clears
// approval. Head, when set, is a head the worker committed before it stopped.
type Park struct {
	Blockers []string
	Head     string
}

// Name implements Transition.
func (Park) Name() string { return "park" }

func (t Park) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	if len(t.Blockers) == 0 {
		return nil, refused("park needs the blockers that park the Issue")
	}
	st := cloneIssue(in.cur)
	movedHead(st, t.Head)
	park(st, t.Blockers)
	return st, nil
}

func park(st *state.Issue, blockers []string) {
	st.UnresolvedBlockers = slices.Clone(blockers)
	st.PendingFindings, st.Approval, st.ConsecutiveFailures = []string{}, nil, 0
}

// cloneIssue deep-copies a state so a transition never changes what was read.
func cloneIssue(cur *state.Issue) *state.Issue {
	st := *cur
	if cur.HeadSHA != nil {
		h := *cur.HeadSHA
		st.HeadSHA = &h
	}
	if cur.Approval != nil {
		a := *cur.Approval
		a.ReviewEvidence.Criteria = slices.Clone(a.ReviewEvidence.Criteria)
		st.Approval = &a
	}
	if cur.Decision != nil {
		d := *cur.Decision
		st.Decision = &d
	}
	if cur.Publish != nil {
		p := *cur.Publish
		st.Publish = &p
	}
	if cur.Repair != nil {
		r := *cur.Repair
		st.Repair = &r
	}
	st.PendingFindings = nonNil(slices.Clone(cur.PendingFindings))
	st.UnresolvedBlockers = nonNil(slices.Clone(cur.UnresolvedBlockers))
	st.Context = nonNil(slices.Clone(cur.Context))
	return &st
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// The publish phases, contract §5.
const (
	PublishIntent = "intent"
	PublishPushed = "pushed"
	PublishLinked = "linked"
)

// Validate rejects the forbidden combinations of contract §5.1 that a single state can show.
// The writer runs it on every state before any request, so none is ever written.
func Validate(st *state.Issue) error {
	if st.Branch == "" {
		return refused("state %s records no branch", st.Key)
	}
	if st.Cycle < 0 || st.Cycle > MaxCycle {
		return refused("state %s: cycle %d is outside 0 to %d", st.Key, st.Cycle, MaxCycle)
	}
	if st.ConsecutiveFailures < 0 || st.ConsecutiveFailures > 1 {
		return refused("state %s: consecutive_failures %d is not 0 or 1", st.Key, st.ConsecutiveFailures)
	}
	if len(st.PendingFindings) > 0 && len(st.UnresolvedBlockers) > 0 {
		return refused("state %s holds pending findings and blockers at once", st.Key)
	}
	if err := validApproval(st); err != nil {
		return err
	}
	return validPublish(st)
}

func validApproval(st *state.Issue) error {
	a := st.Approval
	if a == nil {
		return nil
	}
	switch {
	case a.ReviewedSHA == "" || a.VerifiedBase == "":
		return refused("state %s holds part of the approval triple", st.Key)
	case len(st.PendingFindings) > 0 || len(st.UnresolvedBlockers) > 0:
		return refused("state %s holds an approval beside findings or blockers", st.Key)
	case st.HeadSHA == nil || *st.HeadSHA != a.ReviewedSHA:
		return refused("state %s: reviewed_sha is not head_sha", st.Key)
	}
	return validEvidence(a.ReviewEvidence)
}

// validEvidence requires at least one criterion, every one verified with a kind and evidence,
// and behavior evidence for a behavior change.
func validEvidence(ev state.ReviewEvidence) error {
	if !ev.Present() {
		return refused("review evidence holds no criterion, so it is no approval")
	}
	behavior := false
	for i, c := range ev.Criteria {
		if err := validCriterion(i+1, c); err != nil {
			return err
		}
		behavior = behavior || c.Kind == KindBehavior
	}
	if ev.BehaviorChange && !behavior {
		return refused("a behavior change needs behavior evidence for at least one criterion")
	}
	return nil
}

func validCriterion(i int, c state.Criterion) error {
	switch {
	case c.Text == "" || c.Evidence == "":
		return refused("criterion %d has no text or no evidence", i)
	case c.Result != ResultVerified:
		return refused("criterion %d is %q, not verified", i, c.Result)
	case c.Kind != KindBehavior && c.Kind != KindStatic:
		return refused("criterion %d has kind %q, not behavior or static", i, c.Kind)
	}
	return nil
}

func validPublish(st *state.Issue) error {
	p := st.Publish
	if p == nil {
		return nil
	}
	switch p.Phase {
	case PublishLinked:
		return nil
	case PublishIntent, PublishPushed:
		if st.Approval == nil || p.SHA != st.Approval.ReviewedSHA {
			return refused("state %s: a publish in %s needs an approval on its SHA", st.Key, p.Phase)
		}
		return nil
	default:
		return refused("state %s: unknown publish phase %q", st.Key, p.Phase)
	}
}

// Update applies one transition to Issue n after a full read of its comments, validates the
// result, and writes it. A transition that changes nothing writes nothing.
func (s *Session) Update(ctx context.Context, n int, t Transition) (state.Issue, error) {
	r, err := s.read(ctx, n)
	if err != nil {
		return state.Issue{}, err
	}
	return s.update(ctx, n, r, t)
}

func (s *Session) update(ctx context.Context, n int, r comments, t Transition) (state.Issue, error) {
	var cur state.Issue
	id, err := r.decode(state.IssueKey(n), state.EntityIssue, &cur)
	if err != nil {
		return state.Issue{}, err
	}
	in := applyInput{n: n, cur: nil, r: r}
	if id != 0 {
		in.cur = &cur
	}
	next, err := t.apply(in)
	if err != nil {
		return state.Issue{}, err
	}
	if err := Validate(next); err != nil {
		return state.Issue{}, err
	}
	if in.cur != nil {
		if next.SignalWatermark < cur.SignalWatermark {
			return state.Issue{}, refused("state %s: the watermark would fall from %d to %d", cur.Key, cur.SignalWatermark, next.SignalWatermark)
		}
		if unchanged(&cur, next) {
			return cur, nil
		}
	}
	if err := s.saveState(ctx, n, stored{id: id, revision: cur.Revision}, next, decodeIssue, confirmLanded); err != nil {
		return state.Issue{}, err
	}
	return *next, nil
}

// unchanged compares two states apart from their envelopes.
func unchanged(a, b *state.Issue) bool {
	x, y := *cloneIssue(a), *cloneIssue(b)
	x.Envelope, y.Envelope = b.Envelope, b.Envelope
	ja, errA := json.Marshal(x)
	jb, errB := json.Marshal(y)
	return errA == nil && errB == nil && string(ja) == string(jb)
}
