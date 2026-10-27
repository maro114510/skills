package board

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/maro114510/skills/oe/internal/health"
)

// digestLen is the length of a digest in a dedup key, contract §7.
const digestLen = 12

// leftoverTokenRe matches a placeholder create-github-issues leaves behind when creating an
// Issue failed: {{T3}} or {{T3.2}}.
var leftoverTokenRe = regexp.MustCompile(`\{\{T[0-9]+(?:\.[0-9]+)?\}\}`)

func newAction(kind string) Action {
	return Action{Kind: kind, Issue: 0, Branch: "", PR: 0, Head: "", Resume: false, Merge: "", Health: "", Reason: ""}
}

// actions proposes what to do next. A frozen Epic, or a post-merge check that needs a freeze,
// proposes no work. A merge whose default-branch checks are still pending proposes no landing.
func (w *world) actions(res Result) []Action {
	var out []Action
	for _, i := range res.Issues {
		if w.hasPending(i.Number) {
			a := newAction(ActionApplySignals)
			a.Issue = i.Number
			out = append(out, a)
		}
	}
	if res.Health.Next == health.NextFreeze && !res.Frozen {
		a := newAction(ActionFreeze)
		a.Merge, a.Health, a.Reason = res.Health.Merge, string(res.Health.Status), res.Health.Reason
		out = append(out, a)
	}
	if res.Frozen || res.Health.Next == health.NextFreeze {
		return out
	}
	return append(out, w.workActions(res)...)
}

// workActions proposes landing, re-verifying, and dispatching. Each group is proposed in
// Issue-number order, whatever order the tree lists them in.
func (w *world) workActions(res Result) []Action {
	byState := func(s State) []Issue {
		in := slices.DeleteFunc(slices.Clone(res.Issues), func(i Issue) bool { return i.State != s })
		slices.SortFunc(in, func(a, b Issue) int { return a.Number - b.Number })
		return in
	}
	var out []Action
	if res.Health.Next == health.NextProceed {
		for _, i := range byState(AwaitingMerge) {
			a := newAction(ActionLand)
			a.Issue, a.PR, a.Branch, a.Head = i.Number, i.PR, i.Branch, w.headOf(i)
			out = append(out, a)
		}
	}
	for _, i := range byState(Reverify) {
		a := newAction(ActionReverify)
		a.Issue, a.PR, a.Branch = i.Number, i.PR, i.Branch
		out = append(out, a)
	}
	// Work already in flight resumes before new work starts.
	for _, s := range []State{InProgress, Ready} {
		for _, i := range byState(s) {
			a := newAction(ActionDispatch)
			a.Issue, a.Branch, a.Resume = i.Number, i.Branch, s == InProgress
			out = append(out, a)
		}
	}
	return out
}

func (w *world) hasPending(n int) bool {
	count, _ := w.pending(n, w.b.IssueStates[n])
	return count > 0
}

func (w *world) headOf(i Issue) string {
	for _, pr := range w.b.PRs {
		if pr.Number == i.PR {
			return pr.HeadSHA
		}
	}
	return ""
}

func newNote(kind, key string, on int) Notification {
	return Notification{Key: key, Kind: kind, On: on, Issues: nil, Tokens: nil}
}

// notifications proposes the notes the board found a reason for. The comment writer posts each
// at most once per key, so a note already posted is proposed again and costs nothing.
func (w *world) notifications(res Result, cycles [][]int) []Notification {
	var out []Notification
	for _, g := range cycles {
		parts := make([]string, 0, len(g))
		for _, n := range g {
			parts = append(parts, strconv.Itoa(n))
		}
		n := newNote(NoteDepCycle, "dep-cycle:"+strings.Join(parts, ","), w.b.Epic)
		n.Issues = g
		out = append(out, n)
	}
	out = append(out, w.tokenNotes()...)
	for _, i := range res.Issues {
		out = append(out, w.issueNotes(i)...)
	}
	if l := w.b.Ledger; l != nil && l.Freeze != nil {
		out = append(out, newNote(NoteFreeze, fmt.Sprintf("freeze:%d", l.Freeze.Seq), w.b.Epic))
	}
	slices.SortStableFunc(out, func(a, b Notification) int { return strings.Compare(a.Key, b.Key) })
	return out
}

// tokenNotes finds leftover placeholder tokens in the Epic body and in each container body.
// The bodies are searched here and never printed.
func (w *world) tokenNotes() []Notification {
	var out []Notification
	scan := func(issue int, body string) {
		tokens := slices.Compact(slices.Sorted(slices.Values(leftoverTokenRe.FindAllString(body, -1))))
		if len(tokens) == 0 {
			return
		}
		sum := sha256.Sum256([]byte(strings.Join(tokens, ",")))
		n := newNote(NoteLeftoverToken, fmt.Sprintf("leftover-placeholder:%d:%s", issue, hex.EncodeToString(sum[:])[:digestLen]), issue)
		n.Tokens = tokens
		out = append(out, n)
	}
	scan(w.b.Epic, w.b.EpicBody)
	for _, ch := range w.b.Children {
		if len(ch.Children) > 0 {
			scan(ch.Number, ch.Body)
		}
	}
	return out
}

func (w *world) issueNotes(i Issue) []Notification {
	var out []Notification
	switch i.State {
	case Rejected:
		out = append(out, newNote(NoteRejected, fmt.Sprintf("rejected:%d:%d", i.Number, i.PR), i.Number))
	case Parked:
		if i.MergedPR > 0 {
			out = append(out, newNote(NoteMergedOpen, fmt.Sprintf("merged-open:%d:%d", i.Number, i.MergedPR), i.Number))
		}
	case Reverify:
		if head := w.headOf(i); head != "" {
			out = append(out, newNote(NoteStale, fmt.Sprintf("stale:%d:%s:%s", i.Number, head, w.b.BaseSHA), i.Number))
		}
	case InProgress, Waiting, Ready:
		if key := w.staleStart(i); key != "" {
			out = append(out, newNote(NoteStaleStart, key, i.Number))
		}
	case Done, Verifying, AwaitingMerge:
	}
	return out
}

// staleStart returns the key of a stale-start note: the Issue's dispatch was recorded for its
// current branch, and that branch exists nowhere.
func (w *world) staleStart(i Issue) string {
	if slices.Contains(w.b.Branches, i.Branch) {
		return ""
	}
	if !w.b.Notes[i.Number][fmt.Sprintf("start:%d:%s", i.Number, i.Branch)] {
		return ""
	}
	return fmt.Sprintf("stale-start:%d:%s", i.Number, i.Branch)
}
