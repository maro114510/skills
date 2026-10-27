package round_test

import (
	"reflect"
	"testing"

	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/readiness"
	"github.com/maro114510/skills/oe/internal/round"
)

const noChecks = "no checks reported on head"

func quiet() round.Observation {
	return round.Observation{
		Mark: "", Phase: "", Frozen: false,
		Health: health.Result{Status: health.Clear, Reason: "", RecordID: 0, PR: 0, Issue: 0, Merge: "", Next: health.NextProceed},
	}
}

func merged(mark string) round.Observation {
	o := quiet()
	o.Mark, o.Phase = mark, "merged"
	return o
}

func candidate(issue, pr int, head string, next readiness.Next, reason string) round.Waiter {
	return round.Waiter{
		Issue: issue, PR: pr, Head: head, Stale: false,
		Readiness: readiness.Result{Status: readiness.Waiting, Reason: reason, PR: pr, Head: head, Next: next, Repair: nil, Unreadable: false},
	}
}

func waiting(issue, pr int, head, reason string) round.Waiter {
	return candidate(issue, pr, head, readiness.NextWait, reason)
}

func TestThirtyPollsEachAskForASixtySecondSleep(t *testing.T) {
	t.Parallel()

	s := round.New()
	pending := []round.Waiter{waiting(7, 12, "h1", "check pending: build")}

	for i := 1; i <= round.PollLimit; i++ {
		res := round.Poll(s, quiet(), pending)
		if res.Decision != round.DecisionSleep || res.Polls != i || res.SleepSeconds != 60 || res.Limit != 30 {
			t.Fatalf("poll %d = %+v, want sleep 60s with %d polls spent of 30", i, res, i)
		}
	}
}

func TestTheThirtyFirstPollStopsAndListsTheWaitingPullRequests(t *testing.T) {
	t.Parallel()

	s := round.New()
	pending := []round.Waiter{waiting(7, 12, "h1", "check pending: build"), waiting(9, 14, "h2", "check pending: test")}
	for range round.PollLimit {
		round.Poll(s, quiet(), pending)
	}

	res := round.Poll(s, quiet(), pending)

	if res.Decision != round.DecisionStop || res.SleepSeconds != 0 || s.Polls != 30 {
		t.Fatalf("the 31st poll = %+v with %d polls, want stop, no sleep, and no poll spent", res, s.Polls)
	}
	want := []round.Held{{Issue: 7, PR: 12, Reason: "check pending: build"}, {Issue: 9, PR: 14, Reason: "check pending: test"}}
	if !reflect.DeepEqual(res.Waiting, want) {
		t.Errorf("waiting = %+v, want %+v", res.Waiting, want)
	}
}

func TestAMergeResetsThePollsAndRunsAnotherPassAtOnce(t *testing.T) {
	t.Parallel()

	s := round.New()
	pending := []round.Waiter{waiting(7, 12, "h1", "check pending: build")}
	round.Poll(s, quiet(), pending)
	round.Poll(s, quiet(), pending)
	round.Poll(s, quiet(), pending)

	res := round.Poll(s, merged("12:merge01"), pending)

	if res.Decision != round.DecisionPass || res.SleepSeconds != 0 || res.Polls != 0 {
		t.Errorf("poll after a merge = %+v, want pass at once with the polls reset", res)
	}
	if s.Merges != 1 || s.Polls != 0 {
		t.Errorf("session merges %d polls %d, want 1 and 0", s.Merges, s.Polls)
	}
	if again := round.Poll(s, merged("12:merge01"), pending); again.Decision != round.DecisionSleep || again.Polls != 1 {
		t.Errorf("the next poll = %+v, want sleep with 1 poll: the same merge counts once", again)
	}
}

func TestAMergeMadeBeforeTheSessionBeganIsNeverCounted(t *testing.T) {
	t.Parallel()

	s := round.New()

	res := round.Poll(s, merged("9:old"), []round.Waiter{waiting(7, 12, "h1", "check pending: build")})

	if res.Decision != round.DecisionSleep || s.Merges != 0 {
		t.Errorf("first poll = %+v with %d merges, want sleep and 0 merges", res, s.Merges)
	}
}

func TestARecordThatIsNoMergeKeepsTheLastMergeSoTheNextMergeCountsOnce(t *testing.T) {
	t.Parallel()

	s := round.New()
	round.Poll(s, merged("1:a"), nil)
	intent := quiet()
	intent.Phase = "intent"
	round.Poll(s, intent, nil)

	res := round.Poll(s, merged("2:b"), nil)

	if res.Decision != round.DecisionPass || s.Merges != 1 {
		t.Errorf("poll = %+v with %d merges, want pass and exactly 1 merge", res, s.Merges)
	}
}

func TestAHeadWithNoChecksGetsFivePollsThenNeedsAPerson(t *testing.T) {
	t.Parallel()

	s := round.New()
	silent := []round.Waiter{waiting(7, 12, "h1", noChecks)}

	for i := 1; i <= round.NoChecksLimit; i++ {
		if res := round.Poll(s, quiet(), silent); res.Decision != round.DecisionSleep {
			t.Fatalf("poll %d = %+v, want sleep", i, res)
		}
	}
	res := round.Poll(s, quiet(), silent)

	if res.Decision != round.DecisionSettled || len(res.Waiting) != 0 {
		t.Errorf("the 6th poll = %+v, want settled with nothing left to wait on", res)
	}
	if len(res.Human) != 1 || res.Human[0].PR != 12 || res.Human[0].Issue != 7 {
		t.Errorf("human = %+v, want PR 12", res.Human)
	}
}

func TestANewPushGivesTheNoChecksCountAFreshStart(t *testing.T) {
	t.Parallel()

	s := round.New()
	for range round.NoChecksLimit {
		round.Poll(s, quiet(), []round.Waiter{waiting(7, 12, "h1", noChecks)})
	}

	res := round.Poll(s, quiet(), []round.Waiter{waiting(7, 12, "h2", noChecks)})

	if res.Decision != round.DecisionSleep || len(res.Human) != 0 {
		t.Errorf("poll on a new head = %+v, want sleep: five polls run from the latest push", res)
	}
}

func TestOtherWaitReasonsAreNeverCutOff(t *testing.T) {
	t.Parallel()

	for name, reason := range map[string]string{
		"pending check":            "check pending: build",
		"no checks plus another":   noChecks + "; mergeability still being computed",
		"mergeability being known": "mergeability still being computed",
	} {
		s := round.New()
		for i := 1; i <= round.NoChecksLimit+3; i++ {
			if res := round.Poll(s, quiet(), []round.Waiter{waiting(7, 12, "h1", reason)}); res.Decision != round.DecisionSleep {
				t.Errorf("%s: poll %d = %+v, want sleep", name, i, res)
				break
			}
		}
	}
}

func TestPendingPostMergeChecksAlsoMakeLandingWait(t *testing.T) {
	t.Parallel()

	s := round.New()
	obs := quiet()
	obs.Health = health.Result{Status: health.Pending, Reason: "check pending: ci", RecordID: 4, PR: 12, Issue: 7, Merge: "merge01", Next: health.NextWait}

	res := round.Poll(s, obs, nil)

	if res.Decision != round.DecisionSleep || len(res.Waiting) != 1 || res.Waiting[0].PR != 12 {
		t.Errorf("poll = %+v, want sleep waiting on the merge's checks of PR 12", res)
	}
}

func TestNothingToWaitOnSettlesLanding(t *testing.T) {
	t.Parallel()

	res := round.Poll(round.New(), quiet(), nil)

	if res.Decision != round.DecisionSettled || len(res.Waiting) != 0 {
		t.Errorf("poll = %+v, want settled", res)
	}
}

func TestAFreezeOrAFailedHealthCheckStopsLandingWithoutSpendingAPoll(t *testing.T) {
	t.Parallel()

	for name, edit := range map[string]func(*round.Observation){
		"a ledger freeze":       func(o *round.Observation) { o.Frozen = true },
		"health calls a freeze": func(o *round.Observation) { o.Health.Status, o.Health.Next = health.Fail, health.NextFreeze },
	} {
		s := round.New()
		obs := quiet()
		edit(&obs)

		res := round.Poll(s, obs, []round.Waiter{waiting(7, 12, "h1", "check pending: build")})

		if res.Decision != round.DecisionStop || s.Polls != 0 {
			t.Errorf("%s: poll = %+v with %d polls, want stop and no poll spent", name, res, s.Polls)
		}
	}
}

func TestAMergeRecordWhoseOutcomeIsUnsettledStopsLanding(t *testing.T) {
	t.Parallel()

	for _, phase := range []string{"intent", "unknown"} {
		obs := quiet()
		obs.Phase = phase

		res := round.Poll(round.New(), obs, nil)

		if res.Decision != round.DecisionStop {
			t.Errorf("phase %s: poll = %+v, want stop", phase, res)
		}
	}
}

func TestAStaleCandidateWaitsForItsTurnAndCountsAsWaiting(t *testing.T) {
	t.Parallel()

	stale := round.Waiter{Issue: 6, PR: 13, Head: "h6", Stale: true, Readiness: readiness.Result{Status: readiness.Ready, Reason: "", PR: 13, Head: "h6", Next: readiness.NextMerge, Repair: nil, Unreadable: false}}

	res := round.Poll(round.New(), quiet(), []round.Waiter{stale})

	if res.Decision != round.DecisionSleep || len(res.Waiting) != 1 || res.Waiting[0].Issue != 6 {
		t.Errorf("poll = %+v, want sleep waiting on the stale candidate whatever its own readiness says", res)
	}
}

func TestACandidateNotWaitingIsNeverPolledFor(t *testing.T) {
	t.Parallel()

	for name, tc := range map[string]struct {
		next      readiness.Next
		wantHuman bool
	}{
		"ready to merge, held back by the missing grant": {readiness.NextMerge, false},
		"repair handed to a worker":                      {readiness.NextRepair, false},
		"a repository control for a person":              {readiness.NextHuman, true},
		"nothing":                                        {readiness.NextNone, false},
	} {
		res := round.Poll(round.New(), quiet(), []round.Waiter{candidate(7, 12, "h1", tc.next, "reason")})

		if res.Decision != round.DecisionSettled || len(res.Waiting) != 0 || (len(res.Human) == 1) != tc.wantHuman {
			t.Errorf("%s: poll = %+v, want settled, human listed %v", name, res, tc.wantHuman)
		}
	}
}
