// Package gate is the loop's entry gate, contract §15: it finds the Run Plan, reads the Epic-level
// signals above it, and renders the Run Plan to post when there is none. It is pure: it reads
// comments and facts already read in full, and never calls GitHub or writes anything.
package gate

import (
	"fmt"

	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

// RunPlanKey is the dedup key of the Run Plan note, contract §7.
const RunPlanKey = "run-plan"

// Grant is the merge grant: the latest trusted strict epic-auto-merge or epic-revoke-auto-merge
// above the Run Plan, by comment ID. With neither, nothing is granted.
type Grant struct {
	Granted bool `json:"granted"`
	// CommentID is the deciding comment, or 0 when there is none.
	CommentID int64 `json:"comment_id"`
	// Command is the deciding command, or empty when there is none.
	Command signals.Command `json:"command"`
}

// Signals are the Epic-level signals, contract §6. They are never consumed: each gate reads them
// fresh from the comments above the Run Plan note.
type Signals struct {
	// RunPlan is the Run Plan note's comment ID, or 0 when the Epic has none.
	RunPlan int64 `json:"run_plan"`
	// Approval is the highest trusted strict epic-approve above the Run Plan, or 0.
	Approval   int64 `json:"approval"`
	MergeGrant Grant `json:"merge_grant"`
}

// Approved reports whether the Epic carries an approval.
func (s Signals) Approved() bool { return s.Approval != 0 }

// MergeAuthorized reports whether merging is authorized: an approval and an unrevoked grant. An
// approval alone never authorizes a merge, and neither does a grant without an approval.
func (s Signals) MergeAuthorized() bool { return s.Approved() && s.MergeGrant.Granted }

// Read finds the Run Plan among me's notes on the Epic and reads the signals above it. A v1
// marker, a bad state, or a duplicate state among me's comments stops with exit 6.
func Read(epicComments []snapshot.Comment, me string) (Signals, error) {
	pcs := make([]protocol.Comment, 0, len(epicComments))
	for _, c := range epicComments {
		pcs = append(pcs, c.Protocol())
	}
	idx, err := protocol.Scan(pcs, me)
	if err != nil {
		return Signals{}, fmt.Errorf("the Epic: %w", err)
	}
	plan := RunPlanID(idx)
	return Signals{RunPlan: plan, Approval: Approval(epicComments, plan), MergeGrant: MergeGrant(epicComments, plan)}, nil
}

// RunPlanID is the lowest comment ID of the loop's Run Plan notes, or 0. A duplicate is harmless,
// contract §7; the first one opens the window, so a later duplicate never narrows it.
func RunPlanID(idx protocol.Index) int64 {
	var low int64
	for _, c := range idx.Notes[RunPlanKey] {
		if low == 0 || c.ID < low {
			low = c.ID
		}
	}
	return low
}

// commands yields the trusted strict commands above the Run Plan. Without a Run Plan there is no
// window, so nothing is yielded.
func commands(comments []snapshot.Comment, runPlan int64, yield func(id int64, cmd signals.Command)) {
	if runPlan == 0 {
		return
	}
	for _, c := range comments {
		if c.ID <= runPlan || !signals.Trusted(c.Association, c.Body) {
			continue
		}
		if cmd := signals.Parse(c.Body); cmd != signals.None {
			yield(c.ID, cmd)
		}
	}
}

// Approval is the highest ID of a trusted strict epic-approve above the Run Plan, or 0. One
// posted before the Run Plan, by any other author association, or inside other text never counts.
func Approval(comments []snapshot.Comment, runPlan int64) int64 {
	var top int64
	commands(comments, runPlan, func(id int64, cmd signals.Command) {
		if cmd == signals.Approve {
			top = max(top, id)
		}
	})
	return top
}

// MergeGrant is the latest of epic-auto-merge and epic-revoke-auto-merge above the Run Plan, by
// comment ID. A revoke after a grant withdraws it; a grant after that revoke restores it.
func MergeGrant(comments []snapshot.Comment, runPlan int64) Grant {
	g := Grant{Granted: false, CommentID: 0, Command: signals.None}
	commands(comments, runPlan, func(id int64, cmd signals.Command) {
		if (cmd == signals.AutoMerge || cmd == signals.RevokeAutoMerge) && id > g.CommentID {
			g = Grant{Granted: cmd == signals.AutoMerge, CommentID: id, Command: cmd}
		}
	})
	return g
}
