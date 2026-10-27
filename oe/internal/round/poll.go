package round

import (
	"fmt"
	"strconv"

	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/readiness"
	"github.com/maro114510/skills/oe/internal/state"
)

// noChecksReason is what readiness reports when it waits only for a check that nothing reports.
const noChecksReason = "no checks reported on head"

// The decisions of a poll.
const (
	// DecisionPass is a merge since the last look: landing runs a new pass at once.
	DecisionPass = "pass"
	// DecisionSleep is a wait: sleep PollSleepSeconds in a call of its own, then land again.
	DecisionSleep = "sleep"
	// DecisionStop is the end of landing for this invocation, with what still waits listed.
	DecisionStop = "stop"
	// DecisionSettled is nothing left to merge, repair, or wait on.
	DecisionSettled = "settled"
)

// Observation is what a fresh read shows of the Epic after a landing pass.
type Observation struct {
	// Mark is the latest merge the loop recorded, or "" when its latest record is no merge.
	Mark string
	// Phase is the post-merge record's phase, or "" without a record.
	Phase string
	// Frozen is a freeze that holds the Epic.
	Frozen bool
	Health health.Result
}

// Waiter is a landing candidate as a fresh read shows it.
type Waiter struct {
	Issue int
	PR    int
	Head  string
	// Stale is a candidate whose verdict must be re-verified before it can land.
	Stale bool
	// Readiness is the pull request's own classification; it is ignored for a stale candidate.
	Readiness readiness.Result
}

// Held is a pull request and why landing waits on or is held at it.
type Held struct {
	Issue  int    `json:"issue"`
	PR     int    `json:"pr"`
	Reason string `json:"reason"`
}

// PollResult is what landing does next.
type PollResult struct {
	Decision     string `json:"decision"`
	Reason       string `json:"reason"`
	SleepSeconds int    `json:"sleep_seconds,omitempty"`
	Polls        int    `json:"polls"`
	Limit        int    `json:"limit"`
	// Waiting are the pull requests and checks landing waits on.
	Waiting []Held `json:"waiting"`
	// Human are the pull requests only a person can move.
	Human []Held `json:"human"`
}

// observe notes the latest merge the loop recorded. The first look only learns the mark, so a
// merge from before this session never counts. A new mark is a merge: it counts, and the polls
// spent before it are forgotten. A record that is no merge, such as an intent, keeps the mark.
func observe(s *Session, mark string) bool {
	if !s.Known {
		s.Known, s.Mark = true, mark
		return false
	}
	if mark == "" || mark == s.Mark {
		return false
	}
	s.Mark = mark
	s.Merges++
	s.Polls = 0
	return true
}

// landingStopped says why landing cannot go on, or "" when nothing stops it: a default-branch
// check that failed or cannot be read, or a merge request whose outcome is not settled.
func landingStopped(obs Observation) string {
	switch {
	case obs.Health.Next == health.NextFreeze || obs.Health.Next == health.NextHold:
		return "the default branch's checks after the latest merge are " + string(obs.Health.Status) + ": " + obs.Health.Reason
	case obs.Phase == state.PhaseIntent || obs.Phase == state.PhaseUnknown:
		return "the latest merge request's outcome is not settled (" + obs.Phase + ")"
	}
	return ""
}

// stopped adds a freeze to what landingStopped says.
func stopped(obs Observation) string {
	if obs.Frozen {
		return "the Epic is frozen"
	}
	return landingStopped(obs)
}

// Poll decides what landing does after a pass. It counts a merge when the record names a new
// one, spends one poll when the decision is to sleep, and records both in the session.
func Poll(s *Session, obs Observation, candidates []Waiter) PollResult {
	res := decide(s, obs, candidates)
	res.Polls = s.Polls
	return res
}

func decide(s *Session, obs Observation, candidates []Waiter) PollResult {
	res := PollResult{Decision: "", Reason: "", SleepSeconds: 0, Polls: 0, Limit: PollLimit, Waiting: []Held{}, Human: []Held{}}
	merged := observe(s, obs.Mark)
	if why := stopped(obs); why != "" {
		res.Decision, res.Reason = DecisionStop, why
		return res
	}
	if merged {
		res.Decision, res.Reason = DecisionPass, "a merge was recorded since the last look, so every other verdict is stale: land again"
		return res
	}
	var counted []Waiter
	res.Waiting, res.Human, counted = sortWaiters(s, obs, candidates)
	switch {
	case len(res.Waiting) == 0:
		res.Decision, res.Reason = DecisionSettled, "nothing is left to merge, repair, or wait on"
	case s.Polls >= PollLimit:
		res.Decision, res.Reason = DecisionStop, fmt.Sprintf("%d polls were spent since the last merge; the next invocation picks the waiting pull requests up from GitHub", PollLimit)
	default:
		s.Polls++
		for _, c := range counted {
			s.spendNoChecks(c)
		}
		res.Decision, res.Reason, res.SleepSeconds = DecisionSleep, "something still waits; sleep in a call of its own, then land again", PollSleepSeconds
	}
	return res
}

// sortWaiters splits what landing sees into what it waits on and what only a person moves. The
// third result is the waiters whose wait is a head that reports no checks, which spend their own
// poll count when the decision is to sleep.
func sortWaiters(s *Session, obs Observation, candidates []Waiter) (waiting, human []Held, counted []Waiter) {
	waiting, human = []Held{}, []Held{}
	if obs.Health.Next == health.NextWait {
		waiting = append(waiting, Held{Issue: obs.Health.Issue, PR: obs.Health.PR, Reason: "the default branch's checks after the latest merge: " + obs.Health.Reason})
	}
	for _, c := range candidates {
		held := Held{Issue: c.Issue, PR: c.PR, Reason: c.Readiness.Reason}
		switch {
		case c.Stale:
			held.Reason = "the verdict is stale: re-verification pending"
			waiting = append(waiting, held)
		case c.Readiness.Next == readiness.NextWait && c.Readiness.Reason == noChecksReason && s.noChecksSpent(c):
			held.Reason = fmt.Sprintf("%s after %d polls: nothing reports checks on this head", noChecksReason, NoChecksLimit)
			human = append(human, held)
		case c.Readiness.Next == readiness.NextWait:
			if c.Readiness.Reason == noChecksReason {
				counted = append(counted, c)
			}
			waiting = append(waiting, held)
		case c.Readiness.Next == readiness.NextHuman:
			human = append(human, held)
		}
	}
	return waiting, human, counted
}

// noChecksSpent reports whether the pull request already had its polls on this head.
func (s *Session) noChecksSpent(c Waiter) bool {
	nc, ok := s.NoChecks[strconv.Itoa(c.PR)]
	return ok && nc.Head == c.Head && nc.Polls >= NoChecksLimit
}

// spendNoChecks counts one poll against the head, starting over when the head is a new push.
func (s *Session) spendNoChecks(c Waiter) {
	key := strconv.Itoa(c.PR)
	nc := s.NoChecks[key]
	if nc.Head != c.Head {
		nc = NoChecks{Head: c.Head, Polls: 0}
	}
	nc.Polls++
	s.NoChecks[key] = nc
}
