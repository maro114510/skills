package coord

import (
	"cmp"
	"fmt"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// Standing is how the board classified an Issue whose signals are applied. It decides which
// human decisions apply to it.
type Standing string

// The standings a decision can apply to.
const (
	StandingParked   Standing = "parked"
	StandingRejected Standing = "rejected"
	StandingOther    Standing = "other"
)

// The kinds of a retained human comment, contract §6.
const (
	ContextAnswer = "answer"
	ContextPlain  = "context"
)

// firstRedo is the suffix of the first branch an epic-redo moves to.
const firstRedo = 2

// ApplySignals consumes the human comments above the signal watermark, contract §6. It moves
// the watermark to the highest comment ID of the full read it follows, trusted or not, in the
// same write that applies the window: a comment posted after that read stays above the
// watermark for the next run, and a failed write consumes nothing. Every trusted comment that
// is not a command joins context. The highest-ID decision that applies to the Issue's standing
// is applied once; any other command is consumed and never applied later.
type ApplySignals struct {
	Standing Standing
	// Taken are the branch names already in use, on origin, locally, or as the head of any pull
	// request, so an epic-redo never moves to a branch with history.
	Taken []string
}

// Name implements Transition.
func (ApplySignals) Name() string { return "apply_signals" }

type decision struct {
	cmd signals.Command
	id  int64
}

func (t ApplySignals) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	st := cloneIssue(in.cur)
	window := slices.DeleteFunc(slices.Clone(in.r.list), func(c snapshot.Comment) bool { return c.ID <= in.cur.SignalWatermark })
	slices.SortFunc(window, func(a, b snapshot.Comment) int { return cmp.Compare(a.ID, b.ID) })
	win := t.consume(st, window, questions(in.r, in.n))
	st.SignalWatermark = max(in.cur.SignalWatermark, in.r.highest())
	if win != nil {
		t.decide(st, in.n, *win)
	}
	return st, nil
}

// consume reads a window in ID order: trusted prose joins context, and the highest-ID decision
// that applies is returned.
func (t ApplySignals) consume(st *state.Issue, window []snapshot.Comment, asked asked) *decision {
	var win *decision
	for _, c := range window {
		if !signals.Trusted(c.Association, c.Body) || signals.Blank(c.Body) {
			continue
		}
		switch cmd := signals.Parse(c.Body); cmd {
		case signals.Retry, signals.Redo, signals.Drop:
			if applies(cmd, t.Standing, st) && (win == nil || c.ID > win.id) {
				win = &decision{cmd: cmd, id: c.ID}
			}
		case signals.None:
			st.Context = append(st.Context, asked.retain(c))
		case signals.Approve, signals.AutoMerge, signals.RevokeAutoMerge, signals.Release:
			// Epic-level commands on a child Issue are neither a decision nor context.
		}
	}
	return win
}

// applies says which decisions a standing takes: retry only on an Issue its own state parks,
// since a retry cannot undo what its pull requests park it for, and redo and drop on a parked
// or rejected one.
func applies(cmd signals.Command, s Standing, st *state.Issue) bool {
	switch cmd {
	case signals.Retry:
		return s == StandingParked && parkedByState(st)
	case signals.Redo, signals.Drop:
		return s == StandingParked || s == StandingRejected
	case signals.None, signals.Approve, signals.AutoMerge, signals.RevokeAutoMerge, signals.Release:
		return false
	}
	return false
}

// parkedByState reports whether the state alone parks the Issue: blockers, or a drop no later
// decision replaced.
func parkedByState(st *state.Issue) bool {
	return len(st.UnresolvedBlockers) > 0 || (st.Decision != nil && st.Decision.Command == string(signals.Drop))
}

func (t ApplySignals) decide(st *state.Issue, n int, d decision) {
	st.Decision = &state.Decision{Command: string(d.cmd), CommentID: d.id, RedoBranch: ""}
	switch d.cmd {
	case signals.Drop:
		return
	case signals.Redo:
		branch := t.nextBranch(n)
		st.Branch, st.Decision.RedoBranch = branch, branch
		st.HeadSHA, st.Publish, st.Repair = nil, nil, nil
	case signals.None, signals.Approve, signals.AutoMerge, signals.RevokeAutoMerge, signals.Release, signals.Retry:
	}
	st.Cycle, st.ConsecutiveFailures, st.Approval = 0, 0, nil
	st.PendingFindings, st.UnresolvedBlockers = []string{}, []string{}
}

// nextBranch is the first feat/issue-<n>-<k>, from k=2, that no branch or pull request uses.
func (t ApplySignals) nextBranch(n int) string {
	for k := firstRedo; ; k++ {
		name := fmt.Sprintf("%s%d-%d", snapshot.BranchPrefix, n, k)
		if !slices.Contains(t.Taken, name) {
			return name
		}
	}
}

// asked holds the IDs of the loop's question and answered-Q&A notes on one Issue.
type asked struct {
	blocked []int64
	qa      []int64
}

func questions(r comments, n int) asked {
	var a asked
	blockedPrefix, qaPrefix := fmt.Sprintf("blocked:%d:", n), fmt.Sprintf("qa:%d:", n)
	for key, notes := range r.idx.Notes {
		for _, c := range notes {
			switch {
			case strings.HasPrefix(key, blockedPrefix):
				a.blocked = append(a.blocked, c.ID)
			case strings.HasPrefix(key, qaPrefix):
				a.qa = append(a.qa, c.ID)
			}
		}
	}
	return a
}

// retain is the context entry of a trusted prose comment: an answer while a question is open.
func (a asked) retain(c snapshot.Comment) state.Context {
	kind := ContextPlain
	if a.open(c.ID) {
		kind = ContextAnswer
	}
	return state.Context{ID: c.ID, Author: c.Author, Time: c.CreatedAt, Digest: Digest(c.Body), Kind: kind}
}

// open reports whether a BLOCKED question is open at comment id: the latest question note
// before it has no answered-Q&A note after it.
func (a asked) open(id int64) bool {
	var q int64
	for _, b := range a.blocked {
		if b < id {
			q = max(q, b)
		}
	}
	if q == 0 {
		return false
	}
	return !slices.ContainsFunc(a.qa, func(x int64) bool { return x > q && x < id })
}
