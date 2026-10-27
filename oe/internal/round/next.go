package round

import (
	"fmt"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/health"
)

// The decisions at a round boundary.
const (
	// DecisionContinue starts a new round in this session.
	DecisionContinue = "continue"
	// DecisionEnd ends the session. DecisionStop is landing's own end.
	DecisionEnd = "end"
)

// extraRounds is how many rounds an invocation may run beyond its merges.
const extraRounds = 2

// Conditions are the four a continuation needs, and the cap that bounds them.
type Conditions struct {
	// Outdated is a merge that outdated this round's reading, made in the round or still verifying at its start.
	Outdated bool `json:"outdated"`
	// LandingNotStopped is landing not stopped by a failed health check or an unsettled merge record.
	LandingNotStopped bool `json:"landing_not_stopped"`
	// HealthPassed is the last merge's default-branch checks passing.
	HealthPassed bool `json:"health_passed"`
	// FreezeClear is no freeze holding the Epic.
	FreezeClear bool `json:"freeze_clear"`
	// WithinCap is rounds not exceeding the merges plus two.
	WithinCap bool `json:"within_cap"`
}

// NextResult is the decision at a round boundary.
type NextResult struct {
	Decision   string     `json:"decision"`
	Conditions Conditions `json:"conditions"`
	Reasons    []string   `json:"reasons"`
}

// RequireRound refuses a session whose first round never began, with exit 8. It needs no GitHub
// state, so a command can refuse before it reads anything.
func RequireRound(s *Session) error {
	if s.Round == nil {
		return exitcode.New(exitcode.Refused, "no round has begun in this session, so there is no reading to compare with; run oe round plan first")
	}
	return nil
}

// Next decides, from a fresh read only, whether the session goes on into a new round. A session
// whose first round never began has no reading to compare with, and is refused with exit 8.
func Next(s *Session, obs Observation) (NextResult, error) {
	if err := RequireRound(s); err != nil {
		return NextResult{}, err
	}
	observe(s, obs.Mark)
	why := landingStopped(obs)
	c := Conditions{
		Outdated:          s.Mark != s.Round.Mark || s.Round.Verifying,
		LandingNotStopped: why == "",
		HealthPassed:      obs.Health.Next == health.NextProceed,
		FreezeClear:       !obs.Frozen,
		WithinCap:         s.Rounds+1 <= s.Merges+extraRounds,
	}
	res := NextResult{Decision: DecisionEnd, Conditions: c, Reasons: []string{}}
	for _, r := range []struct {
		ok  bool
		why string
	}{
		{c.Outdated, "no merge outdated this round's reading, so a new round would read the same board"},
		{c.LandingNotStopped, "landing was stopped: " + why},
		{c.HealthPassed, "the default branch's checks after the latest merge have not passed (" + string(obs.Health.Status) + ")"},
		{c.FreezeClear, "the Epic is frozen"},
		{c.WithinCap, fmt.Sprintf("%d rounds ran for %d merges, the most an invocation runs is the merges plus %d", s.Rounds, s.Merges, extraRounds)},
	} {
		if !r.ok {
			res.Reasons = append(res.Reasons, r.why)
		}
	}
	if len(res.Reasons) == 0 {
		res.Decision = DecisionContinue
	}
	return res, nil
}

// BeginRound records the start of a round: one more round, and the latest merge it began from.
func BeginRound(s *Session, mark string, verifying bool) {
	observe(s, mark)
	s.Rounds++
	s.Round = &Baseline{Mark: s.Mark, Verifying: verifying}
}
