package round

import (
	"slices"

	"github.com/maro114510/skills/oe/internal/board"
)

// The kinds of work a round starts.
const (
	// KindDispatch is a worker for an Issue, new or resumed.
	KindDispatch = "dispatch"
	// KindReverify is a fresh reviewer for a pull request whose verdict went stale.
	KindReverify = "reverify"
)

// Input is what a schedule is made from.
type Input struct {
	// Board is a fresh classification of the Epic.
	Board board.Result
	// FixInFlight are the Issues whose state holds pending findings, a fix cycle cut off by a restart.
	FixInFlight map[int]bool
	// MaxParallel caps the workers and reviewers one round starts.
	MaxParallel int
	// Deferred are the Issues this invocation left for the next one.
	Deferred map[int]Reason
}

// Item is one worker or reviewer to start.
type Item struct {
	Kind   string `json:"kind"`
	Issue  int    `json:"issue"`
	Branch string `json:"branch"`
	PR     int    `json:"pr,omitempty"`
	// Resume marks an Issue with work already in flight.
	Resume bool `json:"resume,omitempty"`
	// FixInFlight marks an Issue whose pending findings go to a fresh worker.
	FixInFlight bool `json:"fix_in_flight,omitempty"`
}

// Candidate is a pull request landing may take, in ascending Issue number.
type Candidate struct {
	Issue int    `json:"issue"`
	PR    int    `json:"pr"`
	Head  string `json:"head,omitempty"`
	// Stale marks the one candidate whose verdict is re-verified before it can land.
	Stale bool `json:"stale,omitempty"`
}

// Plan is what one round does.
type Plan struct {
	MaxParallel int `json:"max_parallel"`
	// Signals are the Issues with a human decision to apply first.
	Signals []int `json:"signals"`
	// Freeze is the freeze the board proposes, if any.
	Freeze *board.Action `json:"freeze"`
	// Work is at most MaxParallel items: the stale candidate's reviewer, then the Issues in
	// flight, then the ready ones.
	Work []Item `json:"work"`
	// Landing is the candidates in ascending Issue number, at most one of them stale.
	Landing []Candidate `json:"landing"`
	// StaleWaiting are the stale candidates behind the one whose turn it is.
	StaleWaiting []int `json:"stale_waiting"`
	// LeftOut are the Issues the cap left out, which the next round or invocation starts.
	LeftOut []int `json:"left_out"`
	// Deferred are the proposed Issues this invocation skips.
	Deferred []Deferral `json:"deferred"`
}

// proposals are the board's actions of one round, sorted into the groups a schedule orders.
type proposals struct {
	signals []int
	freeze  *board.Action
	resume  []board.Action
	ready   []board.Action
	fresh   []board.Action
	stale   []board.Action
	// deferred are the proposed Issues this invocation skips, by number.
	deferred map[int]Reason
}

func sortProposals(in Input) proposals {
	p := proposals{
		signals: []int{}, freeze: nil, resume: nil, ready: nil, fresh: nil, stale: nil,
		deferred: map[int]Reason{},
	}
	for _, a := range in.Board.Actions {
		switch {
		case a.Kind == board.ActionApplySignals:
			p.signals = append(p.signals, a.Issue)
		case a.Kind == board.ActionFreeze:
			frozen := a
			p.freeze = &frozen
		case in.Deferred[a.Issue] != "":
			p.deferred[a.Issue] = in.Deferred[a.Issue]
		default:
			p.add(a)
		}
	}
	slices.Sort(p.signals)
	for _, group := range [][]board.Action{p.resume, p.ready, p.fresh, p.stale} {
		slices.SortFunc(group, func(a, b board.Action) int { return a.Issue - b.Issue })
	}
	return p
}

// add puts a work action in its group.
func (p *proposals) add(a board.Action) {
	switch {
	case a.Kind == board.ActionDispatch && a.Resume:
		p.resume = append(p.resume, a)
	case a.Kind == board.ActionDispatch:
		p.ready = append(p.ready, a)
	case a.Kind == board.ActionLand:
		p.fresh = append(p.fresh, a)
	case a.Kind == board.ActionReverify:
		p.stale = append(p.stale, a)
	}
}

// Schedule makes the plan of one round from a fresh classification. The cap counts workers and
// reviewers together, a stale candidate's reviewer first, then every Issue in flight, then the
// ready ones. Landing takes one stale candidate at a time, the lowest Issue number: the others
// wait, so each spends its re-verification only when it is next to land.
func Schedule(in Input) Plan {
	limit := max(in.MaxParallel, 1)
	p := sortProposals(in)
	plan := Plan{
		MaxParallel: limit, Signals: p.signals, Freeze: p.freeze, Work: []Item{}, Landing: []Candidate{},
		StaleWaiting: []int{}, LeftOut: []int{}, Deferred: deferrals(p.deferred),
	}
	var turn *board.Action
	if len(p.stale) > 0 {
		turn = &p.stale[0]
		for _, a := range p.stale[1:] {
			plan.StaleWaiting = append(plan.StaleWaiting, a.Issue)
		}
	}
	fix := turn != nil && in.FixInFlight[turn.Issue]
	for i, it := range workItems(p, turn, fix) {
		if i < limit {
			plan.Work = append(plan.Work, it)
		} else {
			plan.LeftOut = append(plan.LeftOut, it.Issue)
		}
	}
	for _, a := range p.fresh {
		plan.Landing = append(plan.Landing, Candidate{Issue: a.Issue, PR: a.PR, Head: a.Head, Stale: false})
	}
	if turn != nil && !fix {
		plan.Landing = append(plan.Landing, Candidate{Issue: turn.Issue, PR: turn.PR, Head: "", Stale: true})
	}
	slices.SortFunc(plan.Landing, func(a, b Candidate) int { return a.Issue - b.Issue })
	return plan
}

// workItems orders the work before the cap: the stale candidate's reviewer, the Issues in flight,
// then the ready ones. A stale candidate whose fix a restart cut off needs a worker with its
// pending findings instead, so it joins the Issues in flight.
func workItems(p proposals, turn *board.Action, fix bool) []Item {
	inFlight := slices.Clone(p.resume)
	var items []Item
	if turn != nil && fix {
		inFlight = append(inFlight, *turn)
		slices.SortFunc(inFlight, func(a, b board.Action) int { return a.Issue - b.Issue })
	} else if turn != nil {
		items = append(items, Item{Kind: KindReverify, Issue: turn.Issue, Branch: turn.Branch, PR: turn.PR, Resume: false, FixInFlight: false})
	}
	for _, a := range inFlight {
		items = append(items, Item{Kind: KindDispatch, Issue: a.Issue, Branch: a.Branch, PR: a.PR, Resume: true, FixInFlight: a.Kind == board.ActionReverify})
	}
	for _, a := range p.ready {
		items = append(items, Item{Kind: KindDispatch, Issue: a.Issue, Branch: a.Branch, PR: 0, Resume: false, FixInFlight: false})
	}
	return items
}

func deferrals(by map[int]Reason) []Deferral {
	out := make([]Deferral, 0, len(by))
	for issue, reason := range by {
		out = append(out, Deferral{Issue: issue, Reason: reason})
	}
	slices.SortFunc(out, func(a, b Deferral) int { return a.Issue - b.Issue })
	return out
}
