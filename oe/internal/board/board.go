// Package board classifies every dispatchable Issue of an Epic from one complete snapshot, and
// proposes what to do next. It is pure: it reads a snapshot.Board and returns a Result, and it
// never calls GitHub, writes a comment, or changes a branch. A proposal is not a permission;
// each proposed action is checked again by the command that performs it.
package board

import (
	"fmt"
	"slices"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// State is what an Issue is, to the loop.
type State string

// The Issue states. A container is never one of them: it is derived from its sub-issues.
const (
	// Done is a closed Issue that is not verifying.
	Done State = "done"
	// Verifying is the Issue the loop's latest merge closed, whose default-branch checks have
	// not passed yet. It is not done, so nothing depending on it is ready.
	Verifying State = "verifying"
	// AwaitingMerge is an open Issue with an open PR on its bound head, base, and evidence.
	AwaitingMerge State = "awaiting-merge"
	// Reverify is an open Issue with an open PR whose bound verdict no longer holds.
	Reverify State = "reverify"
	// Rejected is an open Issue whose PRs were all closed without merging.
	Rejected State = "rejected"
	// Parked is an Issue that waits on a human: unresolved blockers, a drop, a merged PR with
	// the Issue still open, or an ambiguous PR set.
	Parked State = "parked"
	// InProgress is an open Issue with no PR, not parked, with evidence that work started.
	InProgress State = "in-progress"
	// Ready is an open Issue with no PR, no evidence of work, and every dependency done.
	Ready State = "ready"
	// Waiting is an open Issue with a dependency that is not done.
	Waiting State = "waiting"
)

// Action kinds.
const (
	ActionDispatch     = "dispatch"
	ActionReverify     = "reverify"
	ActionLand         = "land"
	ActionApplySignals = "apply_signals"
	ActionFreeze       = "freeze"
)

// Notification kinds, each the name of a note in contract §7.
const (
	NoteDepCycle      = "dep-cycle"
	NoteLeftoverToken = "leftover-token"
	NoteRejected      = "rejected"
	NoteMergedOpen    = "merged-open"
	NoteStale         = "stale"
	NoteStaleStart    = "stale-start"
	NoteFreeze        = "freeze"
)

// Issue is the classification of one dispatchable Issue.
type Issue struct {
	Number    int    `json:"number"`
	Title     string `json:"title"`
	Container int    `json:"container,omitempty"`
	State     State  `json:"state"`
	Reason    string `json:"reason"`
	Branch    string `json:"branch,omitempty"`
	PR        int    `json:"pr,omitempty"`
	// MergedPR is the highest merged PR of an Issue that is still open.
	MergedPR int `json:"merged_pr,omitempty"`
	// WaitingOn are the dependencies that are not done.
	WaitingOn []int `json:"waiting_on,omitempty"`
	// PendingDecision is a trusted retry, redo, or drop not applied to the state yet. It takes
	// effect only once apply_signals writes it.
	PendingDecision string `json:"pending_decision,omitempty"`
}

// Container is a parent Issue that groups sub-issues. It is never dispatched.
type Container struct {
	Number   int    `json:"number"`
	Title    string `json:"title"`
	Done     bool   `json:"done"`
	Children []int  `json:"children"`
}

// Action is something the board proposes. Nothing here has been done.
type Action struct {
	Kind   string `json:"kind"`
	Issue  int    `json:"issue,omitempty"`
	Branch string `json:"branch,omitempty"`
	PR     int    `json:"pr,omitempty"`
	Head   string `json:"head,omitempty"`
	// Resume marks a dispatch of an Issue that already has work in flight.
	Resume bool `json:"resume,omitempty"`
	// Merge, Health, and Reason describe a proposed freeze.
	Merge  string `json:"merge,omitempty"`
	Health string `json:"health,omitempty"`
	Reason string `json:"reason,omitempty"`
}

// Notification is a note the board proposes to post. Key is its contract §7 dedup key; the
// comment writer posts it at most once.
type Notification struct {
	Key    string   `json:"key"`
	Kind   string   `json:"kind"`
	On     int      `json:"on"`
	Issues []int    `json:"issues,omitempty"`
	Tokens []string `json:"tokens,omitempty"`
}

// Result is the classification of the Epic.
type Result struct {
	Repo          string         `json:"repo"`
	Epic          int            `json:"epic"`
	DefaultBranch string         `json:"default_branch"`
	BaseSHA       string         `json:"base_sha"`
	Frozen        bool           `json:"frozen"`
	Health        health.Result  `json:"health"`
	Issues        []Issue        `json:"issues"`
	Containers    []Container    `json:"containers"`
	Actions       []Action       `json:"actions"`
	Notifications []Notification `json:"notifications"`
}

// Options are what the caller brings to a classification.
type Options struct {
	// LeaseToken is the caller's lease token, or empty when it holds none.
	LeaseToken string
	// MaxParallel caps the combined reverify and dispatch proposals. Zero means no cap.
	MaxParallel int
}

// Classify classifies the board. It stops, writing and proposing nothing, when the Epic's lease
// is held by another session (exit 7) or the post-merge health cannot be read (exit 1).
func Classify(b *snapshot.Board, opts Options) (Result, error) {
	if err := checkLease(b.Lease, opts.LeaseToken); err != nil {
		return Result{}, err
	}
	h := health.FromBoard(b)
	if h.Status == health.Unreadable {
		return Result{}, exitcode.New(exitcode.Unreadable, "post-merge health is unreadable: "+h.Reason)
	}
	w := newWorld(b, h)
	w.maxParallel = opts.MaxParallel
	res := Result{
		Repo: b.Repo, Epic: b.Epic, DefaultBranch: b.DefaultBranch, BaseSHA: b.BaseSHA,
		Frozen: b.Ledger != nil && b.Ledger.Freeze != nil && !b.Ledger.Freeze.Released, Health: h,
		Issues: nil, Containers: nil, Actions: nil, Notifications: nil,
	}
	cycles := w.cycles()
	for _, leaf := range b.Leaves() {
		res.Issues = append(res.Issues, w.classify(leaf, cycles))
	}
	// Containers are derived last, from the leaves' own classification.
	res.Containers = w.containerResults()
	res.Actions = w.actions(res)
	res.Notifications = w.notifications(res, cycles)
	// An empty list is [] in the payload, never null.
	res.Issues, res.Actions, res.Notifications = nonNil(res.Issues), nonNil(res.Actions), nonNil(res.Notifications)
	res.Containers = nonNil(res.Containers)
	return res, nil
}

// checkLease refuses a board read while another session holds the Epic's lease. A lease whose
// pid is 0 ended cleanly. Detection only: reclaiming a dead holder is an explicit step of its
// own, never something a read does.
func checkLease(l *state.Lease, token string) error {
	if l == nil || l.PID == 0 || (token != "" && l.Token == token) {
		return nil
	}
	return exitcode.New(exitcode.Coordination, fmt.Sprintf(
		"the Epic's lease is held by another session (host %s, pid %d, renewed %s); this oe does not take it over",
		l.Host, l.PID, l.RenewedAt))
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// sortedKeys returns the keys of a set in order.
func sortedKeys[V any](m map[int]V) []int {
	out := make([]int, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}
