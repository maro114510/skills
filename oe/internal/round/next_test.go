package round_test

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/round"
)

func passed(mark string) round.Observation {
	o := merged(mark)
	o.Health.Status, o.Health.Next = health.Pass, health.NextProceed
	return o
}

func mustNext(t *testing.T, s *round.Session, obs round.Observation) round.NextResult {
	t.Helper()
	res, err := round.Next(s, obs)
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	return res
}

func TestNextRefusesASessionWhoseFirstRoundNeverBegan(t *testing.T) {
	t.Parallel()

	_, err := round.Next(round.New(), quiet())

	if exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("Next without a round = %v, want exit 8", err)
	}
}

func TestARoundThatMergedNothingEndsTheSession(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.BeginRound(s, "9:old", false)

	res := mustNext(t, s, passed("9:old"))

	if res.Decision != round.DecisionEnd || res.Conditions.Outdated {
		t.Errorf("Next = %+v, want end: no merge outdated this round's reading", res)
	}
}

func TestAMergeMadeInTheRoundWhoseChecksPassedContinues(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.BeginRound(s, "9:old", false)

	res := mustNext(t, s, passed("12:merge01"))

	want := round.Conditions{Outdated: true, LandingNotStopped: true, HealthPassed: true, FreezeClear: true, WithinCap: true}
	if res.Decision != round.DecisionContinue || res.Conditions != want {
		t.Errorf("Next = %+v, want continue with %+v", res, want)
	}
	if s.Merges != 1 {
		t.Errorf("merges = %d, want 1: the continuation counts the merge it saw", s.Merges)
	}
}

func TestARoundThatBeganVerifyingContinuesOnceTheChecksPass(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.BeginRound(s, "9:old", true)

	if res := mustNext(t, s, passed("9:old")); res.Decision != round.DecisionContinue || !res.Conditions.Outdated {
		t.Errorf("Next with passed checks = %+v, want continue", res)
	}
}

func TestAMergeWhoseChecksAreStillPendingNeverContinues(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.BeginRound(s, "9:old", false)
	obs := merged("12:merge01")
	obs.Health.Status, obs.Health.Next = health.Pending, health.NextWait

	res := mustNext(t, s, obs)

	if res.Decision != round.DecisionEnd || res.Conditions.HealthPassed || !res.Conditions.Outdated {
		t.Errorf("Next = %+v, want end because the merge's checks are pending", res)
	}
}

func TestAFreezeAFailedHealthCheckOrAnUnsettledRecordEndsTheSession(t *testing.T) {
	t.Parallel()

	for name, tc := range map[string]struct {
		edit func(*round.Observation)
		cond func(round.Conditions) bool
	}{
		"a ledger freeze": {
			func(o *round.Observation) { o.Frozen = true },
			func(c round.Conditions) bool { return !c.FreezeClear },
		},
		"health calls a freeze": {
			func(o *round.Observation) { o.Health.Status, o.Health.Next = health.Fail, health.NextFreeze },
			func(c round.Conditions) bool { return !c.LandingNotStopped && !c.HealthPassed },
		},
		"a merge request with an unknown outcome": {
			func(o *round.Observation) { o.Phase = "unknown" },
			func(c round.Conditions) bool { return !c.LandingNotStopped },
		},
		"a merge request not yet answered": {
			func(o *round.Observation) { o.Phase = "intent" },
			func(c round.Conditions) bool { return !c.LandingNotStopped },
		},
	} {
		s := round.New()
		round.BeginRound(s, "9:old", false)
		obs := passed("12:merge01")
		tc.edit(&obs)

		res := mustNext(t, s, obs)

		if res.Decision != round.DecisionEnd || !tc.cond(res.Conditions) || len(res.Reasons) == 0 {
			t.Errorf("%s: Next = %+v, want end with the condition and a reason named", name, res)
		}
	}
}

func TestAnInvocationNeverRunsMoreThanItsMergesPlusTwoRounds(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.BeginRound(s, "9:old", true)
	if res := mustNext(t, s, passed("9:old")); res.Decision != round.DecisionContinue {
		t.Fatalf("the second round = %+v, want continue", res)
	}
	round.BeginRound(s, "9:old", true)

	res := mustNext(t, s, passed("9:old"))

	if res.Decision != round.DecisionEnd || res.Conditions.WithinCap {
		t.Errorf("a third round with no merge between = %+v, want end over the cap of merges plus two", res)
	}
}

func TestEachMergeBuysOneMoreRound(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.BeginRound(s, "", false)
	for merge := 1; merge <= 4; merge++ {
		mark := "pr" + string(rune('0'+merge)) + ":sha"
		res := mustNext(t, s, passed(mark))
		if res.Decision != round.DecisionContinue || !res.Conditions.WithinCap {
			t.Fatalf("after merge %d: Next = %+v, want continue", merge, res)
		}
		round.BeginRound(s, mark, false)
	}

	if s.Rounds != 5 || s.Merges != 4 {
		t.Errorf("rounds %d merges %d, want 5 and 4", s.Rounds, s.Merges)
	}
}

func TestBeginRoundCountsTheRoundAndNeverCountsAnEarlierMerge(t *testing.T) {
	t.Parallel()

	s := round.New()

	round.BeginRound(s, "9:old", false)

	if s.Rounds != 1 || s.Merges != 0 || s.Round == nil || s.Round.Mark != "9:old" || s.Round.Verifying || !s.Known {
		t.Errorf("session = %+v, want round 1 from mark 9:old with no merges", s)
	}
}

func TestExhaustedPollsDoNotByThemselvesEndTheSession(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.BeginRound(s, "9:old", true)
	pending := []round.Waiter{waiting(7, 12, "h1", "check pending: build")}
	for range round.PollLimit {
		round.Poll(s, quiet(), pending)
	}
	if res := round.Poll(s, quiet(), pending); res.Decision != round.DecisionStop {
		t.Fatalf("the 31st poll = %+v, want stop", res)
	}

	res := mustNext(t, s, passed("9:old"))

	if res.Decision != round.DecisionContinue || s.Polls != round.PollLimit {
		t.Errorf("Next after exhausted polls (%d spent) and checks that passed = %+v, want continue: the polls decide only whether the last merge passed", s.Polls, res)
	}
}

func TestBeginRoundNeverResetsWhatTheInvocationKeeps(t *testing.T) {
	t.Parallel()

	s := round.New()
	s.Known, s.Mark, s.Polls = true, "9:old", 7
	s.Defer(5, round.ReasonBlocked)
	s.NoChecks["12"] = round.NoChecks{Head: "h1", Polls: 4}
	s.Round = &round.Baseline{Mark: "9:old", Verifying: false}

	round.BeginRound(s, "9:old", false)

	if s.Polls != 7 || len(s.Deferred) != 1 || s.NoChecks["12"].Polls != 4 {
		t.Errorf("session = %+v, want polls, deferrals, and no-checks counts kept: allowances belong to the lease session, not to a round", s)
	}
}

func TestRequireRoundRefusesASessionWhoseFirstRoundNeverBeganWithoutReadingAnything(t *testing.T) {
	t.Parallel()

	s := round.New()
	if err := round.RequireRound(s); exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("RequireRound before a round = %v, want exit 8", err)
	}

	round.BeginRound(s, "9:old", false)

	if err := round.RequireRound(s); err != nil {
		t.Errorf("RequireRound after a round began = %v, want nil", err)
	}
}
