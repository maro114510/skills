package board

import (
	"fmt"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

func newIssue(leaf snapshot.Issue, container int) Issue {
	return Issue{
		Number: leaf.Number, Title: leaf.Title, Container: container, State: "", Reason: "",
		Branch: "", PR: 0, MergedPR: 0, WaitingOn: nil, PendingDecision: "",
	}
}

// classify classifies one dispatchable Issue. An open member of a dependency cycle waits, so no
// work or landing is proposed for it, whether it is ready, in flight, or has a PR to re-verify
// or land. A parked or rejected Issue waits on a person, not on the cycle: it keeps its state and
// its note.
func (w *world) classify(leaf snapshot.Issue, cycles [][]int) Issue {
	out := newIssue(leaf, w.parent[leaf.Number])
	if leaf.State != snapshot.StateOpen {
		out.State, out.Reason = w.closed(leaf)
		return out
	}
	v := w.view(leaf)
	out.Branch = v.branch
	out.State, out.Reason, out.PR = w.classifyOpen(v)
	if len(v.merged) > 0 {
		out.MergedPR = highest(v.merged)
	}
	if _, decision := w.pending(leaf.Number, v.st); decision != signals.None {
		out.PendingDecision = string(decision)
	}
	if group := cycleOf(cycles, leaf.Number); group != nil && heldByCycle(out.State) {
		out.State, out.Reason = Waiting, "in a dependency cycle with "+numbers(group)
	}
	if out.State == Waiting {
		out.WaitingOn = w.waitingOn(leaf)
	}
	return out
}

// heldByCycle says which states a dependency cycle turns into waiting: those that would
// otherwise propose work or a landing.
func heldByCycle(s State) bool {
	return slices.Contains([]State{Ready, InProgress, Waiting, Reverify, AwaitingMerge}, s)
}

func (w *world) closed(leaf snapshot.Issue) (State, string) {
	if w.leafDone(leaf) {
		return Done, "closed"
	}
	return Verifying, fmt.Sprintf("closed by the latest merge, whose default-branch checks are %s", w.h.Status)
}

func (w *world) classifyOpen(v view) (State, string, int) {
	switch {
	case len(v.merged) > 0:
		pr := highest(v.merged)
		return Parked, fmt.Sprintf("PR #%d merged but the Issue is still open", pr), pr
	case len(v.open) > 1:
		return Parked, "several open PRs on " + v.branch, 0
	case len(v.open) == 1:
		return w.openPR(v)
	case len(v.closed) > 0:
		pr := highest(v.closed)
		return Rejected, fmt.Sprintf("every PR on %s was closed without merging", v.branch), pr
	}
	if reason := parkReason(v.st); reason != "" {
		return Parked, reason, 0
	}
	if v.st != nil || v.hasBranch {
		return InProgress, "work was started: a state comment or a branch exists", 0
	}
	if len(w.waitingOn(v.leaf)) > 0 {
		return Waiting, "a dependency is not done", 0
	}
	return Ready, "every dependency is done", 0
}

func (w *world) openPR(v view) (State, string, int) {
	pr := v.open[0]
	switch {
	case parkReason(v.st) != "":
		return Parked, parkReason(v.st), pr.Number
	case approvalHolds(v.st, pr, w.b.BaseSHA):
		return AwaitingMerge, "the open PR is on the bound head, base, and evidence", pr.Number
	default:
		return Reverify, w.staleReason(v, pr), pr.Number
	}
}

// staleReason says which part of the bound verdict no longer holds.
func (w *world) staleReason(v view, pr snapshot.PR) string {
	switch a := v.st; {
	case a == nil || a.Approval == nil:
		return "no approval is bound to the open PR"
	case a.Approval.ReviewedSHA != pr.HeadSHA:
		return "the PR head moved since the reviewed head"
	case a.Approval.VerifiedBase != w.b.BaseSHA:
		return "the default branch moved since the verified base"
	case !a.Approval.ReviewEvidence.Present():
		return "the approval has no review evidence"
	default:
		return "the recorded head differs from the reviewed head"
	}
}

func numbers(ns []int) string {
	parts := make([]string, 0, len(ns))
	for _, n := range ns {
		parts = append(parts, fmt.Sprintf("#%d", n))
	}
	return strings.Join(parts, ", ")
}

func cycleOf(cycles [][]int, n int) []int {
	for _, g := range cycles {
		if slices.Contains(g, n) {
			return g
		}
	}
	return nil
}

// cycles finds the dependency cycles among open dispatchable Issues. A dependency on a
// container is a dependency on each open sub-issue of it. Each cycle is a sorted list.
func (w *world) cycles() [][]int {
	edges := map[int][]int{}
	for _, n := range sortedKeys(w.leaves) {
		leaf := w.leaves[n]
		if leaf.State != snapshot.StateOpen {
			continue
		}
		for _, bl := range w.blockersOf(leaf) {
			edges[n] = append(edges[n], w.openLeavesOf(bl)...)
		}
	}
	return stronglyConnected(edges)
}

// openLeavesOf resolves a dependency to the open dispatchable Issues it stands for.
func (w *world) openLeavesOf(bl snapshot.Blocker) []int {
	if !sameRepo(bl.Repo, w.b.Repo) {
		return nil
	}
	if leaf, ok := w.leaves[bl.Number]; ok && leaf.State == snapshot.StateOpen {
		return []int{bl.Number}
	}
	var out []int
	if c, ok := w.containers[bl.Number]; ok {
		for _, g := range c.Children {
			if g.State == snapshot.StateOpen {
				out = append(out, g.Number)
			}
		}
	}
	return out
}

// scc finds strongly connected groups of a graph with Tarjan's algorithm.
type scc struct {
	edges   map[int][]int
	counter int
	stack   []int
	onStack map[int]bool
	index   map[int]int
	low     map[int]int
	groups  [][]int
}

// stronglyConnected returns every group of Issues that depend on each other, and every Issue
// that depends on itself, each group sorted and the groups in order.
func stronglyConnected(edges map[int][]int) [][]int {
	t := &scc{edges: edges, counter: 0, stack: nil, onStack: map[int]bool{}, index: map[int]int{}, low: map[int]int{}, groups: nil}
	for _, v := range sortedKeys(edges) {
		if _, seen := t.index[v]; !seen {
			t.visit(v)
		}
	}
	slices.SortFunc(t.groups, slices.Compare)
	return t.groups
}

func (t *scc) visit(v int) {
	t.index[v], t.low[v] = t.counter, t.counter
	t.counter++
	t.stack = append(t.stack, v)
	t.onStack[v] = true
	for _, to := range t.edges[v] {
		if _, seen := t.index[to]; !seen {
			t.visit(to)
			t.low[v] = min(t.low[v], t.low[to])
		} else if t.onStack[to] {
			t.low[v] = min(t.low[v], t.index[to])
		}
	}
	if t.low[v] == t.index[v] {
		t.pop(v)
	}
}

// pop closes the group rooted at v, keeping it only if it is a real cycle.
func (t *scc) pop(v int) {
	var group []int
	for {
		top := t.stack[len(t.stack)-1]
		t.stack = t.stack[:len(t.stack)-1]
		t.onStack[top] = false
		group = append(group, top)
		if top == v {
			break
		}
	}
	if len(group) > 1 || slices.Contains(t.edges[v], v) {
		slices.Sort(group)
		t.groups = append(t.groups, group)
	}
}
