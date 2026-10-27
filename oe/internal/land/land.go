// Package land merges a shipped pull request and hands a failing one back to a worker, contract §19.
// `oe land merge` is the only code that requests a merge, and it never uses gh pr merge, --admin, or a rebase.
package land

import (
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/state"
)

// The routes a landing pass takes.
const (
	// RouteMerged is a merge on the verified base.
	RouteMerged = "MERGED"
	// RouteHeld is a pull request that is not merged, with what lifts the hold in Next.
	RouteHeld = "HELD"
	// RouteHeadMoved is a request GitHub refused because the head is no longer the reviewed commit.
	RouteHeadMoved = "HEAD_MOVED"
	// RouteRejected is a request the repository refused.
	RouteRejected = "REJECTED"
	// RouteUnknown is a request whose outcome could not be learned.
	RouteUnknown = "UNKNOWN"
	// RouteUnverifiedBase is a merge that landed on a commit nobody verified, which froze the Epic.
	RouteUnverifiedBase = "MERGED_UNVERIFIED_BASE"
	// RouteReconciled is a record an earlier run left unresolved, settled from its pull request.
	RouteReconciled = "RECONCILED"
)

// What the loop does next.
const (
	// NextRescan is after a merge: every other verdict is stale, so read the board again.
	NextRescan = "rescan"
	// NextLand is to land again, since nothing blocks it.
	NextLand = "land"
	// NextReverify is to review the Issue again.
	NextReverify = "reverify"
	// NextRepair is to hand the pull request to a worker with oe land repair.
	NextRepair = "repair"
	// NextHuman is a hold only a person lifts.
	NextHuman = "human"
	// NextStop is to stop landing for this invocation.
	NextStop = "stop"
)

// Reconciled is the record an earlier run left unresolved and this run settled.
type Reconciled struct {
	PR     int    `json:"pr"`
	Issue  int    `json:"issue"`
	Result string `json:"result"`
}

// Result is what a landing pass did and what the loop does next.
type Result struct {
	Issue  int    `json:"issue"`
	PR     int    `json:"pr"`
	Route  string `json:"route"`
	Reason string `json:"reason"`
	Next   string `json:"next"`
	// Method is the merge method requested, and ReviewedSHA and VerifiedBase the pair it merged.
	Method       string `json:"method"`
	ReviewedSHA  string `json:"reviewed_sha"`
	VerifiedBase string `json:"verified_base"`
	// MergeSHA is the merge commit, and Result the post-merge phase recorded for it.
	MergeSHA string `json:"merge_sha"`
	Result   string `json:"result"`
	// Repair lists the kinds of repair a held pull request needs, when Next is repair.
	Repair     []string           `json:"repair"`
	Reconciled *Reconciled        `json:"reconciled"`
	Freeze     *state.Freeze      `json:"freeze"`
	Notes      []coord.NoteResult `json:"notes"`
}

// NewResult is an empty result for the Issue.
func NewResult(n int) Result {
	return Result{
		Issue: n, PR: 0, Route: "", Reason: "", Next: "", Method: "", ReviewedSHA: "", VerifiedBase: "", MergeSHA: "", Result: "",
		Repair: []string{}, Reconciled: nil, Freeze: nil, Notes: []coord.NoteResult{},
	}
}

// Deps is what a landing pass runs with.
type Deps struct {
	S      *coord.Session
	Client *gh.Client
	In     inputs.Inputs
}
