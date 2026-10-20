// Package readiness classifies whether one pull request is ready to merge, from a single read
// of its state, draft flag, conflicts, checks, reviews, review requests, review threads, and
// merge state. It is the Go form of the earlier pr-readiness.sh and keeps its statuses and
// next actions. Merge only on READY, for exactly the reviewed head; every other result holds.
package readiness

import (
	"fmt"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

// Status is what the pull request is ready for.
type Status string

// The statuses.
const (
	Ready   Status = "READY"
	Waiting Status = "WAITING"
	Blocked Status = "BLOCKED"
	Merged  Status = "MERGED"
	Closed  Status = "CLOSED"
)

// Next is the action the result calls for.
type Next string

// The next actions.
const (
	NextMerge  Next = "merge"
	NextWait   Next = "wait"
	NextRepair Next = "repair"
	NextHuman  Next = "human"
	NextNone   Next = "none"
)

// Repair is a kind of block a worker can lift.
type Repair string

// The repair kinds, in the fixed order they are listed.
const (
	RepairChecks   Repair = "checks"
	RepairConflict Repair = "conflict"
	RepairReview   Repair = "review"
)

// kind is what lifts one reason: a repairable block, time, or a person.
type kind string

const (
	kindChecks   kind = "checks"
	kindConflict kind = "conflict"
	kindReview   kind = "review"
	kindWait     kind = "wait"
	kindHuman    kind = "human"
)

const (
	stateOpen        = "OPEN"
	stateMerged      = "MERGED"
	stateClosed      = "CLOSED"
	unknownLogin     = "unknown"
	unknownReviewer  = "unknown reviewer"
	unreadablePrefix = "unreadable: "
)

// Result is the classification of one pull request. An Unreadable result always has Status
// BLOCKED and Next human, and is never permission to merge.
type Result struct {
	Status     Status   `json:"status"`
	Reason     string   `json:"reason"`
	PR         int      `json:"pr"`
	Head       string   `json:"head"`
	Next       Next     `json:"next"`
	Repair     []Repair `json:"repair,omitempty"`
	Unreadable bool     `json:"unreadable,omitempty"`
}

// item is one reason and what lifts it.
type item struct {
	reason string
	kind   kind
}

// Classify classifies a pull request. Precedence: MERGED or CLOSED, then any unreadable
// signal, then BLOCKED, then WAITING, then READY. Every check counts, required or not, so a
// check that is not configured as required still holds the merge. An unknown enum value fails
// closed.
func Classify(pr *snapshot.PullRequest) Result {
	if pr == nil {
		return unreadable(0, "", []string{"pull request not found in response"})
	}
	switch deref(pr.State) {
	case stateMerged:
		return terminal(pr, Merged, "merged")
	case stateClosed:
		return terminal(pr, Closed, "closed without merging")
	}
	rollup := rollupOf(pr)
	var latest []checks.Check
	if rollup != nil {
		latest = checks.Latest(snapshot.Items(rollup.Contexts))
	}
	if problems := unreadableSignals(pr, rollup, latest); len(problems) > 0 {
		return unreadable(pr.Number, pr.HeadRefOid, problems)
	}
	blocked := blockedItems(pr, latest)
	if len(blocked) > 0 {
		return withKinds(pr, Blocked, blocked)
	}
	if waiting := waitingItems(pr, rollup, latest); len(waiting) > 0 {
		return withKinds(pr, Waiting, waiting)
	}
	if ms := deref(pr.MergeStateStatus); ms == "CLEAN" || ms == "HAS_HOOKS" {
		return finish(pr, Ready, "checks and reviews complete, merge state "+ms, nil)
	}
	return withKinds(pr, Blocked, []item{{
		reason: "merge state " + deref(pr.MergeStateStatus) + ": repository merge controls not satisfied",
		kind:   kindHuman,
	}})
}

func terminal(pr *snapshot.PullRequest, status Status, reason string) Result {
	return finish(pr, status, reason, nil)
}

func unreadable(number int, head string, problems []string) Result {
	return Result{
		Status: Blocked, Reason: unreadablePrefix + strings.Join(problems, "; "), PR: number, Head: head,
		Next: NextHuman, Repair: nil, Unreadable: true,
	}
}

func withKinds(pr *snapshot.PullRequest, status Status, items []item) Result {
	reasons := make([]string, 0, len(items))
	for _, it := range items {
		reasons = append(reasons, it.reason)
	}
	var kinds []kind
	for _, k := range []kind{kindChecks, kindConflict, kindReview, kindWait, kindHuman} {
		for _, it := range items {
			if it.kind == k {
				kinds = append(kinds, k)
				break
			}
		}
	}
	return finish(pr, status, strings.Join(reasons, "; "), kinds)
}

// finish chooses the next action. Merge only on READY. Human whenever any reason needs a
// person, since no worker or wait can lift it; otherwise repair for a block, wait for a wait.
func finish(pr *snapshot.PullRequest, status Status, reason string, kinds []kind) Result {
	r := Result{Status: status, Reason: reason, PR: pr.Number, Head: pr.HeadRefOid, Next: NextWait, Repair: nil, Unreadable: false}
	switch {
	case status == Ready:
		r.Next = NextMerge
	case status == Merged || status == Closed:
		r.Next = NextNone
	case hasKind(kinds, kindHuman):
		r.Next = NextHuman
	case status == Blocked:
		r.Next = NextRepair
		for _, k := range kinds {
			r.Repair = append(r.Repair, Repair(k))
		}
	}
	return r
}

func hasKind(kinds []kind, k kind) bool { return slices.Contains(kinds, k) }

func rollupOf(pr *snapshot.PullRequest) *snapshot.Rollup {
	if c := lastCommit(pr); c != nil {
		return c.StatusCheckRollup
	}
	return nil
}

func lastCommit(pr *snapshot.PullRequest) *snapshot.Commit {
	if pr.Commits == nil || len(pr.Commits.Nodes) == 0 {
		return nil
	}
	return pr.Commits.Nodes[0].Commit
}

// unreadableSignals lists every signal that could not be read, each named once.
func unreadableSignals(pr *snapshot.PullRequest, rollup *snapshot.Rollup, latest []checks.Check) []string {
	out := missingScalars(pr)
	out = append(out, connectionProblems(pr, rollup)...)
	out = append(out, nodeProblems(pr)...)
	for _, name := range checks.Named(latest, checks.Unreadable) {
		out = append(out, "check state missing: "+name)
	}
	return out
}

func missingScalars(pr *snapshot.PullRequest) []string {
	var out []string
	if s := deref(pr.State); s != stateOpen {
		out = append(out, "state "+orMissing(pr.State, s))
	}
	for _, f := range []struct {
		name string
		gone bool
	}{
		{"isDraft", pr.IsDraft == nil},
		{"isMergeQueueEnabled", pr.IsMergeQueueEnabled == nil},
		{"mergeable", pr.Mergeable == nil},
		{"mergeStateStatus", pr.MergeStateStatus == nil},
	} {
		if f.gone {
			out = append(out, f.name+" missing")
		}
	}
	return out
}

func connectionProblems(pr *snapshot.PullRequest, rollup *snapshot.Rollup) []string {
	var out []string
	for _, p := range []string{
		snapshot.Problem(pr.ReviewRequests, "reviewRequests"),
		snapshot.Problem(pr.LatestOpinionatedReviews, "latestOpinionatedReviews"),
		snapshot.Problem(pr.ReviewThreads, "reviewThreads"),
	} {
		if p != "" {
			out = append(out, p)
		}
	}
	if lastCommit(pr) == nil {
		out = append(out, "head commit missing")
	}
	if rollup != nil {
		if p := snapshot.Problem(rollup.Contexts, "contexts"); p != "" {
			out = append(out, "checks: "+p)
		}
	}
	return out
}

func nodeProblems(pr *snapshot.PullRequest) []string {
	var out []string
	if slices.ContainsFunc(snapshot.Items(pr.ReviewThreads), func(t snapshot.Thread) bool { return t.IsResolved == nil }) {
		out = append(out, "review thread state missing")
	}
	if slices.ContainsFunc(snapshot.Items(pr.LatestOpinionatedReviews), func(r snapshot.Review) bool { return r.State == nil }) {
		out = append(out, "review state missing")
	}
	return out
}

func blockedItems(pr *snapshot.PullRequest, latest []checks.Check) []item {
	var out []item
	if deref2(pr.IsDraft) {
		out = append(out, item{"draft", kindHuman})
	}
	if deref(pr.Mergeable) == "CONFLICTING" || deref(pr.MergeStateStatus) == "DIRTY" {
		out = append(out, item{"conflict with base", kindConflict})
	}
	out = append(out, reviewBlocks(pr)...)
	out = append(out, checkBlocks(latest)...)
	if deref2(pr.IsMergeQueueEnabled) {
		out = append(out, item{"merge queue required; this loop never bypasses it", kindHuman})
	}
	return out
}

func reviewBlocks(pr *snapshot.PullRequest) []item {
	var out []item
	if deref(pr.ReviewDecision) == "CHANGES_REQUESTED" {
		out = append(out, item{"changes requested by review decision", kindReview})
	}
	for _, r := range snapshot.Items(pr.LatestOpinionatedReviews) {
		if deref(r.State) == "CHANGES_REQUESTED" {
			out = append(out, item{"changes requested: " + reviewAuthor(r), kindReview})
		}
	}
	unresolved := 0
	for _, t := range snapshot.Items(pr.ReviewThreads) {
		if t.IsResolved != nil && !*t.IsResolved {
			unresolved++
		}
	}
	if unresolved > 0 {
		out = append(out, item{fmt.Sprintf("%d unresolved review thread(s)", unresolved), kindReview})
	}
	return out
}

// checkBlocks holds a cancelled run like a failed one; health, after the merge, reads it apart.
func checkBlocks(latest []checks.Check) []item {
	var out []item
	for _, c := range latest {
		if c.Class == checks.Failed || c.Class == checks.Cancelled {
			out = append(out, item{"check failed: " + c.Name, kindChecks})
		}
	}
	for _, name := range checks.Named(latest, checks.Action) {
		out = append(out, item{"human action required: " + name, kindHuman})
	}
	return out
}

func waitingItems(pr *snapshot.PullRequest, rollup *snapshot.Rollup, latest []checks.Check) []item {
	var out []item
	if deref(pr.Mergeable) == "UNKNOWN" || deref(pr.MergeStateStatus) == "UNKNOWN" {
		out = append(out, item{"mergeability still being computed", kindWait})
	}
	if rollup == nil || len(latest) == 0 {
		out = append(out, item{"no checks reported on head", kindWait})
	}
	for _, name := range checks.Named(latest, checks.Pending) {
		out = append(out, item{"check pending: " + name, kindWait})
	}
	if deref(pr.ReviewDecision) == "REVIEW_REQUIRED" {
		out = append(out, item{"review required", kindHuman})
	}
	for _, rq := range snapshot.Items(pr.ReviewRequests) {
		k := kindHuman
		if rq.RequestedReviewer != nil && rq.RequestedReviewer.Typename == "Bot" {
			k = kindWait
		}
		out = append(out, item{"review requested: " + requestedReviewer(rq), k})
	}
	return out
}

func requestedReviewer(rq snapshot.ReviewRequest) string {
	r := rq.RequestedReviewer
	switch {
	case r == nil:
		return unknownReviewer
	case r.Login != nil:
		return *r.Login
	case r.Slug != nil:
		return *r.Slug
	default:
		return unknownReviewer
	}
}

func reviewAuthor(r snapshot.Review) string {
	if r.Author != nil && r.Author.Login != nil {
		return *r.Author.Login
	}
	return unknownLogin
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func deref2(b *bool) bool { return b != nil && *b }

func orMissing(s *string, v string) string {
	if s == nil {
		return "missing"
	}
	return v
}
