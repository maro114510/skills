package round

import (
	"cmp"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// Unfinished is an Issue that keeps the Epic from completing, and why.
type Unfinished struct {
	Issue  int    `json:"issue"`
	State  string `json:"state"`
	Reason string `json:"reason"`
}

// Dropped is an Issue a person gave up with epic-drop, and why it never shipped.
type Dropped struct {
	Issue   int      `json:"issue"`
	Title   string   `json:"title"`
	Reasons []string `json:"reasons"`
}

// The kinds of recorded assumption.
const (
	// AssumptionSkipped is a criterion or requirement a worker deferred rather than met.
	AssumptionSkipped = "skipped"
	// AssumptionDecision is a choice a worker made where no source settled it.
	AssumptionDecision = "decision"
	// AssumptionAnswer is a question the loop answered from written sources.
	AssumptionAnswer = "answer"
)

// Assumption is something an earlier invocation recorded and the completion must carry.
type Assumption struct {
	Issue int    `json:"issue"`
	Kind  string `json:"kind"`
	Text  string `json:"text"`
}

// Report is what a completion decides and says, built from a fresh board and every leaf Issue's comments.
type Report struct {
	Epic   int           `json:"epic"`
	Merged []board.Issue `json:"merged"`
	// Dropped and Unfinished are Issues that did not ship.
	Dropped     []Dropped    `json:"dropped"`
	Unfinished  []Unfinished `json:"unfinished"`
	Assumptions []Assumption `json:"assumptions"`
	// Counters are the ledger's budget counters, nil without a ledger.
	Counters *state.Counters `json:"counters"`
	// Cycles are the fix cycles each Issue used, for the Issues that used any.
	Cycles map[int]int `json:"cycles"`
	// StaleStarts counts the dispatches whose branch was gone.
	StaleStarts int `json:"stale_starts"`
	// DoneContainers are the containers whose sub-issues are all done and which are still open.
	DoneContainers []int `json:"done_containers"`
}

// Assess builds the report from a fresh classification, the board it came from, and the
// comments of every leaf Issue, closed ones included. A comment that cannot be read as the
// loop's own stops with the protocol error.
func Assess(res board.Result, b *snapshot.Board, comments map[int][]snapshot.Comment) (Report, error) {
	rep := Report{
		Epic: res.Epic, Merged: []board.Issue{}, Dropped: []Dropped{}, Unfinished: []Unfinished{}, Assumptions: []Assumption{},
		Counters: nil, Cycles: map[int]int{}, StaleStarts: 0, DoneContainers: []int{},
	}
	ev, err := gather(b, comments)
	if err != nil {
		return Report{}, err
	}
	rep.Assumptions, rep.StaleStarts = ev.assumptions, ev.staleStarts
	for n, st := range ev.states {
		if st.Cycle > 0 {
			rep.Cycles[n] = st.Cycle
		}
	}
	if b.Ledger != nil {
		counters := b.Ledger.Counters
		rep.Counters = &counters
	}
	sortIssues(&rep, res.Issues, ev)
	rep.DoneContainers = doneContainers(res, b)
	return rep, nil
}

// sortIssues sorts the classified Issues, in Issue order, into what merged, what a person gave
// up on, and what the loop can still move.
func sortIssues(r *Report, issues []board.Issue, ev evidence) {
	for _, i := range sortedIssues(issues) {
		switch {
		case i.State == board.Done:
			r.Merged = append(r.Merged, i)
		case (i.State == board.Parked || i.State == board.Rejected) && ev.dropped(i.Number):
			r.Dropped = append(r.Dropped, Dropped{Issue: i.Number, Title: i.Title, Reasons: ev.reasons(i)})
		default:
			r.Unfinished = append(r.Unfinished, Unfinished{Issue: i.Number, State: string(i.State), Reason: i.Reason})
		}
	}
}

func sortedIssues(in []board.Issue) []board.Issue {
	out := slices.Clone(in)
	slices.SortFunc(out, func(a, b board.Issue) int { return cmp.Compare(a.Number, b.Number) })
	return out
}

// doneContainers are the containers every sub-issue of which is done and which are still open.
func doneContainers(res board.Result, b *snapshot.Board) []int {
	open := map[int]bool{}
	for _, ch := range b.Children {
		if len(ch.Children) > 0 && ch.State == snapshot.StateOpen {
			open[ch.Number] = true
		}
	}
	out := []int{}
	for _, c := range res.Containers {
		if c.Done && open[c.Number] {
			out = append(out, c.Number)
		}
	}
	slices.Sort(out)
	return out
}

// Complete reports whether the Epic is complete: it has dispatchable Issues, and every one is
// done or dropped by a person.
func (r Report) Complete() bool {
	return len(r.Unfinished) == 0 && len(r.Merged)+len(r.Dropped) > 0
}

// evidence is what the leaf Issues' comments say: their states, and the assumptions and lost
// dispatches their notes record.
type evidence struct {
	states      map[int]*state.Issue
	assumptions []Assumption
	staleStarts int
}

// gather reads every leaf Issue's comments as the loop's own, in Issue order.
func gather(b *snapshot.Board, comments map[int][]snapshot.Comment) (evidence, error) {
	ev := evidence{states: map[int]*state.Issue{}, assumptions: []Assumption{}, staleStarts: 0}
	leaves := b.Leaves()
	slices.SortFunc(leaves, func(a, b snapshot.Issue) int { return cmp.Compare(a.Number, b.Number) })
	for _, leaf := range leaves {
		n := leaf.Number
		pcs := make([]protocol.Comment, 0, len(comments[n]))
		for _, c := range comments[n] {
			pcs = append(pcs, c.Protocol())
		}
		idx, err := protocol.Scan(pcs, b.Me)
		if err != nil {
			return evidence{}, fmt.Errorf("#%d: %w", n, err)
		}
		if c, ok := idx.States[state.IssueKey(n)]; ok {
			var st state.Issue
			if _, err := protocol.DecodeState(c.Body, &st); err != nil {
				return evidence{}, fmt.Errorf("#%d: comment %d: %w", n, c.ID, err)
			}
			if st.Entity != state.EntityIssue {
				return evidence{}, exitcode.New(exitcode.Protocol, fmt.Sprintf("#%d: comment %d: state %q is a %q, not an issue", n, c.ID, st.Key, st.Entity))
			}
			ev.states[n] = &st
		}
		ev.addNotes(n, idx)
	}
	return ev, nil
}

// dropped reports whether a person's epic-drop is applied to the Issue's state.
func (ev evidence) dropped(n int) bool {
	st := ev.states[n]
	return st != nil && st.Decision != nil && st.Decision.Command == string(signals.Drop)
}

// reasons are why a dropped Issue never shipped: its unresolved blockers, else the board's reason.
func (ev evidence) reasons(i board.Issue) []string {
	var out []string
	if st := ev.states[i.Number]; st != nil {
		for _, blocker := range st.UnresolvedBlockers {
			out = append(out, clip(blocker))
		}
	}
	if len(out) == 0 {
		out = append(out, clip(i.Reason))
	}
	return out
}

// maxLine bounds one recorded line in the completion, so a long record never fills the comment.
const maxLine = 400

// clip collapses whitespace to one line and bounds its length.
func clip(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > maxLine {
		return string(r[:maxLine]) + "…"
	}
	return s
}

// The most a completion may hold. The comment writer refuses a body over 65536 characters or 127
// KiB, and a refused completion is never posted, so a record too long to fit is cut to counts.
// The limits leave room for the marker line the writer adds.
const (
	maxTextBytes = 100_000
	maxTextRunes = 60_000
)

// Text is the completion comment, from oe's own template. When the whole record would not fit
// in a comment, the assumptions and the reasons are counted instead of listed, and each Issue's
// own notes still hold them.
func (r Report) Text() string {
	if text := r.render(true); len(text) <= maxTextBytes && utf8.RuneCountInString(text) <= maxTextRunes {
		return text
	}
	return r.render(false)
}

// render writes the comment. Without detail it counts the assumptions and leaves out the reasons.
func (r Report) render(detail bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Epic #%d のループは、これ以上自動で進められる Issue が無いため終了しました。\n\n"+
		"これは終了報告です。すべてが成功したとは限りません。\n", r.Epic)
	section(&b, "マージされた Issue", len(r.Merged), func() {
		for _, i := range r.Merged {
			fmt.Fprintf(&b, "- #%d %s\n", i.Number, clip(i.Title))
		}
	})
	section(&b, "記録された前提", len(r.Assumptions), func() {
		if !detail {
			fmt.Fprintf(&b, "%d 件。長すぎて載せられないため、各 Issue の report と qa の記録を参照してください。\n", len(r.Assumptions))
			return
		}
		for _, a := range r.Assumptions {
			fmt.Fprintf(&b, "- #%d %s: %s\n", a.Issue, kindLabel(a.Kind), a.Text)
		}
	})
	section(&b, "保留または見送った Issue", len(r.Dropped), func() {
		for _, d := range r.Dropped {
			fmt.Fprintf(&b, "- #%d %s\n", d.Issue, clip(d.Title))
			for _, reason := range d.Reasons {
				if detail {
					fmt.Fprintf(&b, "  - %s\n", reason)
				}
			}
		}
	})
	b.WriteString("\n## 数値\n\n")
	r.writeCounts(&b)
	b.WriteString("\n## 人が行うこと\n\n" +
		"ループは Epic も、サブ issue がすべて完了したコンテナも閉じません。内容を確認して、人が閉じてください。\n\n")
	fmt.Fprintf(&b, "- Epic #%d\n", r.Epic)
	for _, c := range r.DoneContainers {
		fmt.Fprintf(&b, "- コンテナ #%d\n", c)
	}
	return b.String()
}

func section(b *strings.Builder, title string, n int, body func()) {
	fmt.Fprintf(b, "\n## %s\n\n", title)
	if n == 0 {
		b.WriteString("なし\n")
		return
	}
	body()
}

func kindLabel(kind string) string {
	switch kind {
	case AssumptionSkipped:
		return "見送り"
	case AssumptionDecision:
		return "判断"
	case AssumptionAnswer:
		return "回答"
	}
	return kind
}

// writeCounts lists the numbers oe already has: the ledger's counters, the fix cycles each Issue
// used, and the dispatches whose branch was lost.
func (r Report) writeCounts(b *strings.Builder) {
	if r.Counters == nil {
		b.WriteString("- 台帳（ledger）はありません。\n")
	} else {
		c := r.Counters
		fmt.Fprintf(b, "- worker dispatch: %d / %d\n- reviewer pass: %d / %d\n- fix cycle: %d / %d\n",
			c.WorkerDispatches.Used, c.WorkerDispatches.Bound, c.ReviewerPasses.Used, c.ReviewerPasses.Bound,
			c.FixCycles.Used, c.FixCycles.Bound)
	}
	issues := make([]int, 0, len(r.Cycles))
	for n := range r.Cycles {
		issues = append(issues, n)
	}
	slices.Sort(issues)
	used := make([]string, 0, len(issues))
	for _, n := range issues {
		used = append(used, fmt.Sprintf("#%d: %d", n, r.Cycles[n]))
	}
	if len(used) > 0 {
		fmt.Fprintf(b, "- fix cycle を使った Issue: %s\n", strings.Join(used, "、"))
	}
	fmt.Fprintf(b, "- 記録されたのにブランチが無かった dispatch: %s 件\n", strconv.Itoa(r.StaleStarts))
}
