package board

import (
	"fmt"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// world indexes a board for classification.
type world struct {
	b *snapshot.Board
	h health.Result
	// verifying is the Issue the loop's latest merge closed whose checks have not passed, or 0.
	verifying  int
	leaves     map[int]snapshot.Issue
	containers map[int]snapshot.Issue
	// parent maps a leaf to the container it sits under.
	parent map[int]int
}

func newWorld(b *snapshot.Board, h health.Result) *world {
	w := &world{
		b: b, h: h, verifying: 0,
		leaves: map[int]snapshot.Issue{}, containers: map[int]snapshot.Issue{}, parent: map[int]int{},
	}
	for _, ch := range b.Children {
		if len(ch.Children) == 0 {
			w.leaves[ch.Number] = ch
			continue
		}
		w.containers[ch.Number] = ch
		for _, g := range ch.Children {
			w.leaves[g.Number] = g
			w.parent[g.Number] = ch.Number
		}
	}
	if b.PostMerge != nil {
		switch h.Status {
		case health.Pending, health.Fail, health.Unconfirmed:
			w.verifying = b.PostMerge.State.Issue
		case health.Clear, health.Pass, health.Handled, health.Unreadable:
		}
	}
	return w
}

// leafDone reports whether a dispatchable Issue is done: closed, and not the Issue whose merge
// is still being verified.
func (w *world) leafDone(i snapshot.Issue) bool {
	return i.State == snapshot.StateClosed && i.Number != w.verifying
}

// containerDone reports whether every sub-issue of a container is done, whatever state the
// container Issue itself is in.
func (w *world) containerDone(c snapshot.Issue) bool {
	return !slices.ContainsFunc(c.Children, func(g snapshot.Issue) bool { return !w.leafDone(g) })
}

// blockerDone reports whether a dependency is done. A blocker the Epic knows is judged like any
// other Issue of it; a blocker outside the Epic is done once it is closed.
func (w *world) blockerDone(bl snapshot.Blocker) bool {
	if sameRepo(bl.Repo, w.b.Repo) {
		if leaf, ok := w.leaves[bl.Number]; ok {
			return w.leafDone(leaf)
		}
		if c, ok := w.containers[bl.Number]; ok {
			return w.containerDone(c)
		}
	}
	return bl.State == snapshot.StateClosed
}

func sameRepo(a, b string) bool {
	return a != "" && strings.EqualFold(a, b)
}

// blockersOf are the dependencies of a dispatchable Issue: its own, and those of the container
// it sits under, because a container that depends on another theme makes the whole container
// wait for it.
func (w *world) blockersOf(leaf snapshot.Issue) []snapshot.Blocker {
	if c, ok := w.containers[w.parent[leaf.Number]]; ok {
		return append(slices.Clone(leaf.Blockers), c.Blockers...)
	}
	return leaf.Blockers
}

func (w *world) waitingOn(leaf snapshot.Issue) []int {
	var out []int
	for _, bl := range w.blockersOf(leaf) {
		if !w.blockerDone(bl) {
			out = append(out, bl.Number)
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

func (w *world) containerResults() []Container {
	out := make([]Container, 0, len(w.containers))
	for _, ch := range w.b.Children {
		if len(ch.Children) == 0 {
			continue
		}
		nums := make([]int, 0, len(ch.Children))
		for _, g := range ch.Children {
			nums = append(nums, g.Number)
		}
		out = append(out, Container{Number: ch.Number, Title: ch.Title, Done: w.containerDone(ch), Children: nums})
	}
	return out
}

// view is everything one open Issue is classified from.
type view struct {
	leaf snapshot.Issue
	st   *state.Issue
	// branch is the branch the Issue's work is on, see ownsBranch.
	branch string
	// hasBranch says that branch exists on origin or in the local checkout.
	hasBranch bool
	open      []snapshot.PR
	merged    []snapshot.PR
	closed    []snapshot.PR
}

// branchOf is the branch an Issue works on: the one its state records, which an applied redo
// moves to a fresh name, else feat/issue-<n>.
func branchOf(n int, st *state.Issue) string {
	if recorded(st) {
		return st.Branch
	}
	return fmt.Sprintf("%s%d", snapshot.BranchPrefix, n)
}

func recorded(st *state.Issue) bool { return st != nil && st.Branch != "" }

// ownsBranch reports whether a branch is the Issue's work. A recorded branch is matched exactly,
// so an applied redo leaves the old one behind. With none recorded, any branch named for the
// Issue is its work: a person who started it by hand names it feat/issue-<n>-<slug>, and a
// worker dispatched beside that work would put two writers on one Issue.
func ownsBranch(n int, st *state.Issue, name string) bool {
	if recorded(st) {
		return name == st.Branch
	}
	m, ok := snapshot.IssueOfBranch(name)
	return ok && m == n
}

func (w *world) view(leaf snapshot.Issue) view {
	st := w.b.IssueStates[leaf.Number]
	v := view{leaf: leaf, st: st, branch: branchOf(leaf.Number, st), hasBranch: false, open: nil, merged: nil, closed: nil}
	for _, pr := range w.b.PRs {
		if !ownsBranch(leaf.Number, st, pr.Branch) {
			continue
		}
		switch pr.State {
		case snapshot.StateOpen:
			v.open = append(v.open, pr)
		case snapshot.StateMerged:
			v.merged = append(v.merged, pr)
		default:
			v.closed = append(v.closed, pr)
		}
	}
	if !recorded(st) {
		v.branch = w.chosenBranch(v)
	}
	v.hasBranch = slices.Contains(w.b.Branches, v.branch)
	return v
}

// chosenBranch picks, for an Issue whose state records no branch, the branch its work is on: the
// newest PR's, in the order the PRs decide the Issue, else an existing branch, else the loop's own
// name. The loop's own name wins whenever it is among the candidates.
func (w *world) chosenBranch(v view) string {
	own := branchOf(v.leaf.Number, v.st)
	for _, prs := range [][]snapshot.PR{v.merged, v.open, v.closed} {
		if len(prs) == 0 {
			continue
		}
		return prBranch(prs)
	}
	var found []string
	for _, name := range w.b.Branches {
		if ownsBranch(v.leaf.Number, v.st, name) {
			found = append(found, name)
		}
	}
	switch {
	case len(found) == 0 || slices.Contains(found, own):
		return own
	default:
		return found[0]
	}
}

// prBranch is the branch of the newest of prs.
func prBranch(prs []snapshot.PR) string {
	top := prs[0]
	for _, p := range prs[1:] {
		if p.Number > top.Number {
			top = p
		}
	}
	return top.Branch
}

// highest returns the highest PR number.
func highest(prs []snapshot.PR) int {
	top := 0
	for _, p := range prs {
		top = max(top, p.Number)
	}
	return top
}

// parkReason is why state alone parks an Issue: unresolved blockers, or a drop no later
// decision replaced. Pending findings never park an Issue.
func parkReason(st *state.Issue) string {
	switch {
	case st == nil:
		return ""
	case len(st.UnresolvedBlockers) > 0:
		return "unresolved blockers: " + strings.Join(st.UnresolvedBlockers, "; ")
	case st.Decision != nil && st.Decision.Command == string(signals.Drop):
		return "dropped by epic-drop"
	default:
		return ""
	}
}

// approvalHolds reports whether an open PR is still on the verdict that was bound: the PR head
// is the reviewed head, the default branch is the verified base, the state's own head agrees,
// and the evidence is present. Anything less is no approval.
func approvalHolds(st *state.Issue, pr snapshot.PR, base string) bool {
	if st == nil || st.Approval == nil {
		return false
	}
	a := st.Approval
	return a.ReviewedSHA == pr.HeadSHA && a.VerifiedBase == base && a.ReviewEvidence.Present() &&
		st.HeadSHA != nil && *st.HeadSHA == a.ReviewedSHA
}

// pending reports the trusted comments past an Issue's signal watermark, and the decision the
// latest strict retry, redo, or drop among them would apply. Nothing is applied by reading.
func (w *world) pending(n int, st *state.Issue) (count int, decision signals.Command) {
	if st == nil {
		return 0, signals.None
	}
	var top int64
	for _, c := range w.b.Comments[n] {
		if c.ID <= st.SignalWatermark || !signals.Trusted(c.Association, c.Body) || signals.Blank(c.Body) {
			continue
		}
		count++
		switch cmd := signals.Parse(c.Body); cmd {
		case signals.Retry, signals.Redo, signals.Drop:
			if c.ID > top {
				top, decision = c.ID, cmd
			}
		case signals.None, signals.Approve, signals.AutoMerge, signals.RevokeAutoMerge, signals.Release:
		}
	}
	return count, decision
}
