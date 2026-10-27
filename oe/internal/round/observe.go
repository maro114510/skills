package round

import (
	"fmt"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// ObservationOf is what a fresh board and its classification show of the Epic: the latest merge
// the loop recorded, the phase of its latest record, any freeze, and the default branch's health.
func ObservationOf(b *snapshot.Board, res board.Result) Observation {
	obs := Observation{Mark: "", Phase: "", Frozen: res.Frozen, Health: res.Health}
	if b.PostMerge == nil {
		return obs
	}
	pm := b.PostMerge.State
	obs.Phase = pm.Phase
	if pm.Phase == state.PhaseMerged || pm.Phase == state.PhaseMergedUnverifiedBase {
		obs.Mark = fmt.Sprintf("%d:%s", pm.PR, pm.MergeSHA)
	}
	return obs
}

// Verifying reports whether an Issue is closed by the loop's latest merge whose default-branch
// checks have not passed.
func Verifying(res board.Result) bool {
	for _, i := range res.Issues {
		if i.State == board.Verifying {
			return true
		}
	}
	return false
}

// FixInFlight are the Issues whose state holds pending findings, a fix cycle a restart cut off.
func FixInFlight(b *snapshot.Board) map[int]bool {
	out := map[int]bool{}
	for n, st := range b.IssueStates {
		if len(st.PendingFindings) > 0 {
			out[n] = true
		}
	}
	return out
}
