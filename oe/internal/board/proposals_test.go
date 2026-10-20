package board

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

func TestFrozenBoardDoesNotProposeAnotherFreeze(t *testing.T) {
	t.Parallel()

	res := Result{
		Repo: "", Epic: 0, DefaultBranch: "", BaseSHA: "", Frozen: true, Lease: nil,
		Health: health.Result{Status: "", Reason: "", RecordID: 0, PR: 0, Issue: 0, Merge: "", Next: health.NextFreeze},
		Issues: []Issue{}, Containers: []Container{}, Actions: []Action{}, Notifications: []Notification{},
	}
	w := &world{b: nil, h: res.Health, verifying: 0, leaves: map[int]snapshot.Issue{},
		containers: map[int]snapshot.Issue{}, parent: map[int]int{}}
	if got := w.actions(res); len(got) != 0 {
		t.Fatalf("actions = %+v, want no second freeze or work while frozen", got)
	}
}
