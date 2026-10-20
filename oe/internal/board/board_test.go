package board_test

import (
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

const (
	epic     = 277
	baseSHA  = "base1"
	headSHA  = "head1"
	otherSHA = "other"
)

// fx builds a board. Every field of every snapshot type is set once here, so a case states
// only what it changes.
type fx struct {
	b *snapshot.Board
}

func newFx() *fx {
	return &fx{b: &snapshot.Board{
		Repo: "o/r", Epic: epic, Me: "loop", DefaultBranch: "main", BaseSHA: baseSHA,
		Now: time.Date(2026, 10, 19, 0, 5, 0, 0, time.UTC), EpicBody: "", Children: nil, PRs: nil, Branches: nil,
		Comments: map[int][]snapshot.Comment{}, Notes: map[int]map[string]bool{},
		IssueStates: map[int]*state.Issue{}, Lease: nil, Ledger: nil, PostMerge: nil, PostMergePull: nil,
	}}
}

func blocker(n int, st string) snapshot.Blocker {
	return snapshot.Blocker{Number: n, State: st, Repo: "o/r"}
}

func leaf(n int, st string, blockers ...snapshot.Blocker) snapshot.Issue {
	return snapshot.Issue{Number: n, State: st, Title: "T", Body: "", CreatedAt: "", Blockers: blockers, Children: nil}
}

func container(n int, st string, body string, kids ...snapshot.Issue) snapshot.Issue {
	c := leaf(n, st)
	c.Body = body
	c.Children = kids
	return c
}

func (f *fx) with(children ...snapshot.Issue) *fx {
	f.b.Children = children
	return f
}

func (f *fx) pr(n int, branch, st, head string) *fx {
	f.b.PRs = append(f.b.PRs, snapshot.PR{Number: n, State: st, Branch: branch, HeadSHA: head, CreatedAt: ""})
	return f
}

func (f *fx) branch(names ...string) *fx {
	f.b.Branches = append(f.b.Branches, names...)
	return f
}

func envelope(key string) protocol.Envelope {
	return protocol.Envelope{ProtocolVersion: 2, Entity: state.EntityIssue, Key: key, Revision: 1, UpdatedBy: "token"}
}

func newState(n int) *state.Issue {
	head := headSHA
	return &state.Issue{
		Envelope: envelope(state.IssueKey(n)), Branch: "feat/issue-" + itoa(n), Cycle: 0, ConsecutiveFailures: 0,
		HeadSHA: &head, Approval: nil, PendingFindings: nil, UnresolvedBlockers: nil, Decision: nil,
		SignalWatermark: 0, Context: nil, Publish: nil, Repair: nil,
	}
}

func itoa(n int) string {
	const digits = "0123456789"
	if n < 10 {
		return digits[n : n+1]
	}
	return itoa(n/10) + digits[n%10:n%10+1]
}

func approved(st *state.Issue, base string) *state.Issue {
	st.Approval = &state.Approval{
		ReviewedSHA: headSHA, VerifiedBase: base,
		ReviewEvidence: state.ReviewEvidence{
			BehaviorChange: false, Basis: "tests",
			Criteria: []state.Criterion{{Text: "it works", Result: "verified", Kind: "test", Evidence: "go test -> exit 0"}},
		},
	}
	head := headSHA
	st.HeadSHA = &head
	return st
}

func (f *fx) state(n int, st *state.Issue) *fx {
	f.b.IssueStates[n] = st
	return f
}

func (f *fx) comment(id int64, association, body string) *fx {
	f.b.Comments[1] = append(f.b.Comments[1], snapshot.Comment{ID: id, CreatedAt: "", Author: "human", Association: association, Body: body})
	return f
}

func classify(t *testing.T, f *fx) board.Result {
	t.Helper()
	res, err := board.Classify(f.b, board.Options{LeaseToken: "", MaxParallel: 0})
	if err != nil {
		t.Fatalf("Classify() error = %v", err)
	}
	return res
}

func find(t *testing.T, res board.Result, n int) board.Issue {
	t.Helper()
	for _, i := range res.Issues {
		if i.Number == n {
			return i
		}
	}
	t.Fatalf("Issue #%d is not classified: %+v", n, res.Issues)
	var none board.Issue
	return none
}

func stateOf(t *testing.T, f *fx, n int) board.State {
	t.Helper()
	return find(t, classify(t, f), n).State
}

func actionsOf(res board.Result, kind string) []int {
	var out []int
	for _, a := range res.Actions {
		if a.Kind == kind {
			out = append(out, a.Issue)
		}
	}
	return out
}

func noteKeys(res board.Result) []string {
	keys := make([]string, 0, len(res.Notifications))
	for _, n := range res.Notifications {
		keys = append(keys, n.Key)
	}
	return keys
}

func TestClosedIssuesAreDone(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "CLOSED"), leaf(2, "OPEN", blocker(1, "CLOSED")))
	res := classify(t, f)
	if find(t, res, 1).State != board.Done || find(t, res, 2).State != board.Ready {
		t.Errorf("states = %+v, want #1 done and #2 ready", res.Issues)
	}
}

func TestReadyAndWaiting(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN"), leaf(2, "OPEN", blocker(1, "OPEN")), leaf(3, "OPEN", blocker(99, "OPEN")), leaf(4, "OPEN", blocker(98, "CLOSED")))
	res := classify(t, f)
	want := map[int]board.State{1: board.Ready, 2: board.Waiting, 3: board.Waiting, 4: board.Ready}
	for n, st := range want {
		if got := find(t, res, n).State; got != st {
			t.Errorf("#%d = %s, want %s", n, got, st)
		}
	}
	if got := find(t, res, 2).WaitingOn; !slices.Equal(got, []int{1}) {
		t.Errorf("#2 waits on %v, want [1]", got)
	}
	// A blocker outside the Epic that is still open is not done; one that is closed is.
	if got := find(t, res, 3).WaitingOn; !slices.Equal(got, []int{99}) {
		t.Errorf("#3 waits on %v, want [99]", got)
	}
}

func TestInProgressNeedsEvidenceOfWork(t *testing.T) {
	t.Parallel()

	tests := map[string]*fx{
		"a state comment":          newFx().with(leaf(1, "OPEN")).state(1, newState(1)),
		"a local or remote branch": newFx().with(leaf(1, "OPEN")).branch("feat/issue-1"),
	}
	for name, f := range tests {
		if got := stateOf(t, f, 1); got != board.InProgress {
			t.Errorf("%s: state = %s, want in-progress", name, got)
		}
	}
	// A start note is only a human-facing note, never evidence of work.
	f := newFx().with(leaf(1, "OPEN"))
	f.b.Notes[1] = map[string]bool{"start:1:feat/issue-1": true}
	if got := stateOf(t, f, 1); got != board.Ready {
		t.Errorf("state = %s, want ready", got)
	}
}

func TestInProgressWinsOverAnOpenDependency(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN"), leaf(2, "OPEN", blocker(1, "OPEN"))).state(2, newState(2))
	if got := stateOf(t, f, 2); got != board.InProgress {
		t.Errorf("state = %s, want in-progress", got)
	}
}

func TestParked(t *testing.T) {
	t.Parallel()

	blocked := newState(1)
	blocked.UnresolvedBlockers = []string{"secret screen hit"}
	dropped := newState(1)
	dropped.Decision = &state.Decision{Command: "epic-drop", CommentID: 5, RedoBranch: ""}
	retried := newState(1)
	retried.Decision = &state.Decision{Command: "epic-retry", CommentID: 5, RedoBranch: ""}
	findings := newState(1)
	findings.PendingFindings = []string{"rename x"}

	tests := map[string]struct {
		f    *fx
		want board.State
	}{
		"unresolved blockers": {newFx().with(leaf(1, "OPEN")).state(1, blocked), board.Parked},
		"a drop":              {newFx().with(leaf(1, "OPEN")).state(1, dropped), board.Parked},
		"blockers on an open PR": {
			newFx().with(leaf(1, "OPEN")).state(1, blocked).pr(9, "feat/issue-1", "OPEN", headSHA), board.Parked,
		},
		"a later retry replaced the drop":      {newFx().with(leaf(1, "OPEN")).state(1, retried), board.InProgress},
		"pending findings never park an Issue": {newFx().with(leaf(1, "OPEN")).state(1, findings), board.InProgress},
		"several open PRs on one branch": {
			newFx().with(leaf(1, "OPEN")).pr(8, "feat/issue-1", "OPEN", headSHA).pr(9, "feat/issue-1", "OPEN", headSHA), board.Parked,
		},
	}
	for name, tc := range tests {
		if got := stateOf(t, tc.f, 1); got != tc.want {
			t.Errorf("%s: state = %s, want %s", name, got, tc.want)
		}
	}
}

func TestAMergedPRWithTheIssueStillOpenIsNeverRedispatched(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN")).pr(9, "feat/issue-1", "MERGED", headSHA).branch("feat/issue-1")
	res := classify(t, f)
	i := find(t, res, 1)
	if i.State != board.Parked || i.MergedPR != 9 {
		t.Errorf("Issue = %+v, want parked with merged PR 9", i)
	}
	if got := actionsOf(res, board.ActionDispatch); len(got) != 0 {
		t.Errorf("dispatch proposed for %v, want none", got)
	}
	if keys := noteKeys(res); !slices.Equal(keys, []string{"merged-open:1:9"}) {
		t.Errorf("notes = %v, want merged-open:1:9", keys)
	}
}

func TestRejected(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN")).
		pr(7, "feat/issue-1", "CLOSED", headSHA).pr(9, "feat/issue-1", "CLOSED", otherSHA).branch("feat/issue-1")
	res := classify(t, f)
	if i := find(t, res, 1); i.State != board.Rejected || i.PR != 9 {
		t.Errorf("Issue = %+v, want rejected at PR 9", i)
	}
	if keys := noteKeys(res); !slices.Equal(keys, []string{"rejected:1:9"}) {
		t.Errorf("notes = %v, want rejected:1:9", keys)
	}
	if len(res.Actions) != 0 {
		t.Errorf("actions = %+v, want none for a rejected Issue", res.Actions)
	}
}

func TestAnAppliedRedoLeavesTheRejectedBranchBehind(t *testing.T) {
	t.Parallel()

	st := newState(1)
	st.Branch = "feat/issue-1-2"
	st.Decision = &state.Decision{Command: "epic-redo", CommentID: 5, RedoBranch: "feat/issue-1-2"}
	f := newFx().with(leaf(1, "OPEN")).state(1, st).pr(7, "feat/issue-1", "CLOSED", headSHA)
	if got := stateOf(t, f, 1); got != board.InProgress {
		t.Errorf("state = %s, want in-progress on the fresh branch", got)
	}
}

func TestOpenPRStates(t *testing.T) {
	t.Parallel()

	good := func() *fx {
		return newFx().with(leaf(1, "OPEN")).state(1, approved(newState(1), baseSHA)).pr(9, "feat/issue-1", "OPEN", headSHA)
	}
	noEvidence := approved(newState(1), baseSHA)
	noEvidence.Approval.ReviewEvidence.Criteria = nil
	disagrees := approved(newState(1), baseSHA)
	other := otherSHA
	disagrees.HeadSHA = &other

	tests := map[string]struct {
		f    *fx
		want board.State
	}{
		"the bound pair holds":              {good(), board.AwaitingMerge},
		"the PR head moved":                 {newFx().with(leaf(1, "OPEN")).state(1, approved(newState(1), baseSHA)).pr(9, "feat/issue-1", "OPEN", otherSHA), board.Reverify},
		"the default branch moved":          {newFx().with(leaf(1, "OPEN")).state(1, approved(newState(1), otherSHA)).pr(9, "feat/issue-1", "OPEN", headSHA), board.Reverify},
		"the evidence is not present":       {newFx().with(leaf(1, "OPEN")).state(1, noEvidence).pr(9, "feat/issue-1", "OPEN", headSHA), board.Reverify},
		"the recorded head disagrees":       {newFx().with(leaf(1, "OPEN")).state(1, disagrees).pr(9, "feat/issue-1", "OPEN", headSHA), board.Reverify},
		"no approval":                       {newFx().with(leaf(1, "OPEN")).state(1, newState(1)).pr(9, "feat/issue-1", "OPEN", headSHA), board.Reverify},
		"no state at all":                   {newFx().with(leaf(1, "OPEN")).pr(9, "feat/issue-1", "OPEN", headSHA), board.Reverify},
		"a reopened PR beside a closed one": {newFx().with(leaf(1, "OPEN")).state(1, approved(newState(1), baseSHA)).pr(7, "feat/issue-1", "CLOSED", headSHA).pr(9, "feat/issue-1", "OPEN", headSHA), board.AwaitingMerge},
	}
	for name, tc := range tests {
		if got := stateOf(t, tc.f, 1); got != tc.want {
			t.Errorf("%s: state = %s, want %s", name, got, tc.want)
		}
	}
}

func TestAStaleVerdictIsNeverMergeReady(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN")).state(1, approved(newState(1), baseSHA)).pr(9, "feat/issue-1", "OPEN", otherSHA)
	res := classify(t, f)
	if got := actionsOf(res, board.ActionLand); len(got) != 0 {
		t.Errorf("land proposed for %v, want none", got)
	}
	if got := actionsOf(res, board.ActionReverify); !slices.Equal(got, []int{1}) {
		t.Errorf("reverify = %v, want [1]", got)
	}
	if keys := noteKeys(res); !slices.Equal(keys, []string{"stale:1:" + otherSHA + ":" + baseSHA}) {
		t.Errorf("notes = %v, want one stale note", keys)
	}
}

func TestAwaitingMergeProposesALand(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN")).state(1, approved(newState(1), baseSHA)).pr(9, "feat/issue-1", "OPEN", headSHA)
	res := classify(t, f)
	if len(res.Actions) != 1 || res.Actions[0].Kind != board.ActionLand || res.Actions[0].PR != 9 || res.Actions[0].Head != headSHA {
		t.Errorf("actions = %+v, want one land of PR 9 at %s", res.Actions, headSHA)
	}
}

func TestAContainerIsDoneOnlyWhenEveryGrandchildIs(t *testing.T) {
	t.Parallel()

	// #5 is a container, closed on its own, with one unfinished grandchild. #9 depends on it.
	f := newFx().with(
		container(5, "CLOSED", "", leaf(51, "CLOSED"), leaf(52, "OPEN")),
		leaf(9, "OPEN", blocker(5, "CLOSED")),
	)
	res := classify(t, f)
	if i := find(t, res, 9); i.State != board.Waiting || !slices.Equal(i.WaitingOn, []int{5}) {
		t.Errorf("#9 = %+v, want waiting on container 5", i)
	}
	if len(res.Containers) != 1 || res.Containers[0].Done || !slices.Equal(res.Containers[0].Children, []int{51, 52}) {
		t.Errorf("containers = %+v, want #5 unfinished", res.Containers)
	}
	if got := find(t, res, 51).Container; got != 5 {
		t.Errorf("#51 container = %d, want 5", got)
	}
}

// TestAContainerThatDependsOnAnotherThemeMakesEverySubIssueWait: create-github-issues puts a
// cross-theme dependency on the container, never on its sub-issues.
func TestAContainerThatDependsOnAnotherThemeMakesEverySubIssueWait(t *testing.T) {
	t.Parallel()

	c := container(5, "OPEN", "", leaf(51, "OPEN"), leaf(52, "OPEN", blocker(51, "OPEN")))
	c.Blockers = []snapshot.Blocker{blocker(2, "OPEN")}
	res := classify(t, newFx().with(leaf(2, "OPEN"), c))
	for _, n := range []int{51, 52} {
		if i := find(t, res, n); i.State != board.Waiting || !slices.Contains(i.WaitingOn, 2) {
			t.Errorf("#%d = %+v, want waiting on the container's dependency #2", n, i)
		}
	}
	if got := actionsOf(res, board.ActionDispatch); !slices.Equal(got, []int{2}) {
		t.Errorf("dispatch = %v, want only #2", got)
	}

	// Once #2 is done, the sub-issues are ready again, in their own order.
	c.Blockers = []snapshot.Blocker{blocker(2, "CLOSED")}
	res = classify(t, newFx().with(leaf(2, "CLOSED"), c))
	if find(t, res, 51).State != board.Ready || find(t, res, 52).State != board.Waiting {
		t.Errorf("issues = %+v, want #51 ready and #52 waiting on #51", res.Issues)
	}
}

func TestAContainerDependingOnItsOwnSubIssueIsACycle(t *testing.T) {
	t.Parallel()

	c := container(5, "OPEN", "", leaf(51, "OPEN"))
	c.Blockers = []snapshot.Blocker{blocker(51, "OPEN")}
	res := classify(t, newFx().with(c))
	if keys := noteKeys(res); !slices.Equal(keys, []string{"dep-cycle:51"}) {
		t.Errorf("notes = %v, want dep-cycle:51", keys)
	}
}

func TestAContainerIsNeverAUnitOfWork(t *testing.T) {
	t.Parallel()

	res := classify(t, newFx().with(container(5, "OPEN", "", leaf(51, "OPEN"))))
	for _, i := range res.Issues {
		if i.Number == 5 {
			t.Errorf("the container itself was classified: %+v", i)
		}
	}
	for _, a := range res.Actions {
		if a.Issue == 5 {
			t.Errorf("action %+v targets the container", a)
		}
	}
}

func TestOnceTheLastGrandchildClosesTheContainerIsDone(t *testing.T) {
	t.Parallel()

	f := newFx().with(
		container(5, "OPEN", "", leaf(51, "CLOSED"), leaf(52, "CLOSED")),
		leaf(9, "OPEN", blocker(5, "OPEN")),
	)
	res := classify(t, f)
	if find(t, res, 9).State != board.Ready || !res.Containers[0].Done {
		t.Errorf("result = %+v, want #9 ready under a done container", res)
	}
}

func TestADependencyCycleProposesNoDispatchAndOneNotification(t *testing.T) {
	t.Parallel()

	f := newFx().with(
		leaf(1, "OPEN", blocker(2, "OPEN")),
		leaf(2, "OPEN", blocker(3, "OPEN")),
		leaf(3, "OPEN", blocker(1, "OPEN")),
		leaf(4, "OPEN"),
		leaf(5, "OPEN", blocker(1, "OPEN")),
	).state(2, newState(2)).branch("feat/issue-3")
	res := classify(t, f)
	for _, n := range []int{1, 2, 3} {
		if i := find(t, res, n); i.State != board.Waiting || !strings.Contains(i.Reason, "dependency cycle") {
			t.Errorf("#%d = %+v, want waiting in a cycle, even with work in flight", n, i)
		}
	}
	if got := actionsOf(res, board.ActionDispatch); !slices.Equal(got, []int{4}) {
		t.Errorf("dispatch = %v, want only #4", got)
	}
	if keys := noteKeys(res); !slices.Equal(keys, []string{"dep-cycle:1,2,3"}) {
		t.Errorf("notes = %v, want one dep-cycle:1,2,3", keys)
	}
}

func TestADependencySelfLoopAndACycleThroughAContainer(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN", blocker(1, "OPEN")))
	if keys := noteKeys(classify(t, f)); !slices.Equal(keys, []string{"dep-cycle:1"}) {
		t.Errorf("self loop notes = %v, want dep-cycle:1", keys)
	}

	// #7 waits on container 5, whose grandchild #52 waits on #7.
	f = newFx().with(
		container(5, "OPEN", "", leaf(51, "OPEN"), leaf(52, "OPEN", blocker(7, "OPEN"))),
		leaf(7, "OPEN", blocker(5, "OPEN")),
	)
	res := classify(t, f)
	if keys := noteKeys(res); !slices.Equal(keys, []string{"dep-cycle:7,52"}) {
		t.Errorf("notes = %v, want dep-cycle:7,52", keys)
	}
	if got := actionsOf(res, board.ActionDispatch); !slices.Equal(got, []int{51}) {
		t.Errorf("dispatch = %v, want only #51", got)
	}
}

func TestClosedIssuesNeverFormACycle(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "CLOSED", blocker(2, "OPEN")), leaf(2, "OPEN", blocker(1, "CLOSED")))
	res := classify(t, f)
	if len(res.Notifications) != 0 || find(t, res, 2).State != board.Ready {
		t.Errorf("result = %+v, want no cycle and #2 ready", res)
	}
}

func TestLeftoverTokens(t *testing.T) {
	t.Parallel()

	f := newFx().with(
		container(5, "OPEN", "plan: {{T3.2}} and {{T3.1}} and {{T3.2}}", leaf(51, "OPEN")),
		container(6, "OPEN", "clean body", leaf(61, "OPEN")),
		leaf(7, "OPEN"),
	)
	f.b.EpicBody = "tasks {{T9}}"
	res := classify(t, f)
	if len(res.Notifications) != 2 {
		t.Fatalf("notes = %v, want two token notes", noteKeys(res))
	}
	for _, n := range res.Notifications {
		if n.Kind != board.NoteLeftoverToken {
			t.Errorf("note %+v, want a leftover-token note", n)
		}
		if parts := strings.Split(n.Key, ":"); len(parts) != 3 || parts[0] != "leftover-token" || len(parts[2]) != 12 {
			t.Errorf("key = %q, want leftover-token:<issue>:<12 hex>", n.Key)
		}
	}
	wantTokens(t, res, epic, []string{"{{T9}}"})
	wantTokens(t, res, 5, []string{"{{T3.1}}", "{{T3.2}}"})
}

func wantTokens(t *testing.T, res board.Result, on int, tokens []string) {
	t.Helper()
	for _, n := range res.Notifications {
		if n.On == on {
			if !slices.Equal(n.Tokens, tokens) {
				t.Errorf("tokens on #%d = %v, want %v", on, n.Tokens, tokens)
			}
			return
		}
	}
	t.Errorf("no token note on #%d in %v", on, noteKeys(res))
}

// TestTheSetOfTokensMakesTheKey: the text around the tokens does not change the dedup key.
func TestTheSetOfTokensMakesTheKey(t *testing.T) {
	t.Parallel()

	keys := func(body string) []string {
		return noteKeys(classify(t, newFx().with(container(5, "OPEN", body, leaf(51, "OPEN")))))
	}
	if a, b := keys("{{T3.1}} {{T3.2}}"), keys("other words {{T3.2}} {{T3.1}}"); !slices.Equal(a, b) || len(a) != 1 {
		t.Errorf("keys differ for the same tokens: %v vs %v", a, b)
	}
	if a, b := keys("{{T3.1}}"), keys("{{T3.1}} {{T3.2}}"); slices.Equal(a, b) {
		t.Errorf("keys equal for different tokens: %v", a)
	}
}

func TestLease(t *testing.T) {
	t.Parallel()

	lease := func(token string, pid int) *state.Lease {
		env := envelope("lease")
		env.Entity = state.EntityLease
		return &state.Lease{Envelope: env, Token: token, Host: "h", PID: pid, StartedAt: "", RenewedAt: "now"}
	}
	tests := map[string]struct {
		lease *state.Lease
		token string
		code  exitcode.Code
	}{
		"none":                 {nil, "", exitcode.OK},
		"released":             {lease("a", 0), "", exitcode.OK},
		"held by this session": {lease("a", 42), "a", exitcode.OK},
		"held by another":      {lease("a", 42), "b", exitcode.Coordination},
		"held, and no token":   {lease("a", 42), "", exitcode.Coordination},
	}
	for name, tc := range tests {
		f := newFx().with(leaf(1, "OPEN"))
		f.b.Lease = tc.lease
		_, err := board.Classify(f.b, board.Options{LeaseToken: tc.token, MaxParallel: 0})
		if got := exitcode.CodeOf(err); got != tc.code {
			t.Errorf("%s: exit %d, want %d (%v)", name, got, tc.code, err)
		}
	}
}

func zeroCounters() state.Counters {
	var c state.Counters
	return c
}

func recordFor(issue, pr int) *snapshot.PostMergeRecord {
	env := envelope("post-merge")
	env.Entity = state.EntityPostMerge
	return &snapshot.PostMergeRecord{CommentID: 10, State: state.PostMerge{
		Envelope: env, PR: pr, Issue: issue, ReviewedSHA: headSHA, VerifiedBase: baseSHA,
		Phase: state.PhaseMerged, MergeSHA: "m111", RequestedAt: "",
	}}
}

// mergedPull is PR 7, merged at 00:00, whose merge commit has reported no checks yet.
func mergedPull() *snapshot.MergePull {
	st, merged, oid := "MERGED", "2026-10-19T00:00:00Z", "m111"
	return &snapshot.MergePull{Number: 7, State: &st, MergedAt: &merged, MergeCommit: &snapshot.MergeCommit{OID: &oid, StatusCheckRollup: nil}}
}

func TestVerifyingIssueBlocksItsDependents(t *testing.T) {
	t.Parallel()

	// The merge closed #1 one minute ago, with no check reported yet.
	f := newFx().with(leaf(1, "CLOSED"), leaf(2, "OPEN", blocker(1, "CLOSED")), leaf(3, "OPEN", blocker(1, "CLOSED")), leaf(4, "CLOSED"))
	f.b.PostMerge = recordFor(1, 7)
	f.b.PostMergePull = mergedPull()
	f.b.Now = time.Date(2026, 10, 19, 0, 1, 0, 0, time.UTC)
	res := classify(t, f)
	if res.Health.Status != health.Pending {
		t.Fatalf("health = %+v, want pending", res.Health)
	}
	if got := find(t, res, 1).State; got != board.Verifying {
		t.Errorf("#1 = %s, want verifying", got)
	}
	if got := find(t, res, 4).State; got != board.Done {
		t.Errorf("#4 = %s, want done: only the recorded Issue verifies", got)
	}
	for _, n := range []int{2, 3} {
		if i := find(t, res, n); i.State != board.Waiting || !slices.Equal(i.WaitingOn, []int{1}) {
			t.Errorf("#%d = %+v, want waiting on the verifying #1", n, i)
		}
	}
}

func TestUnreadableHealthStopsClassification(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN"))
	f.b.PostMerge = recordFor(1, 7)
	f.b.PostMergePull = nil
	_, err := board.Classify(f.b, board.Options{LeaseToken: "", MaxParallel: 0})
	if exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("exit = %d (%v), want %d", exitcode.CodeOf(err), err, exitcode.Unreadable)
	}
}

func TestAFrozenEpicProposesNoWork(t *testing.T) {
	t.Parallel()

	env := envelope("ledger")
	env.Entity = state.EntityLedger
	f := newFx().with(leaf(1, "OPEN"), leaf(2, "OPEN")).state(2, approved(newState(2), baseSHA)).pr(9, "feat/issue-2", "OPEN", headSHA)
	f.b.Ledger = &state.Ledger{
		Envelope: env, N: 2, Counters: zeroCounters(), FreezeSeq: 1, ReleaseWatermark: 0,
		Freeze: &state.Freeze{Seq: 1, Reason: "bound exceeded", MergeSHA: "", Health: "", Released: false},
	}
	res := classify(t, f)
	if !res.Frozen || len(res.Actions) != 0 {
		t.Errorf("frozen = %v, actions = %+v, want a frozen Epic with no actions", res.Frozen, res.Actions)
	}
	if keys := noteKeys(res); !slices.Equal(keys, []string{"freeze:1"}) {
		t.Errorf("notes = %v, want freeze:1", keys)
	}
}

func TestDispatchesResumeBeforeStartAndEveryActionIsAProposal(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN"), leaf(2, "OPEN"), leaf(3, "OPEN")).state(3, newState(3))
	res := classify(t, f)
	got := make([]int, 0, len(res.Actions))
	for _, a := range res.Actions {
		if a.Kind != board.ActionDispatch {
			t.Errorf("action %+v, want only dispatches", a)
		}
		got = append(got, a.Issue)
	}
	if !slices.Equal(got, []int{3, 1, 2}) {
		t.Errorf("dispatch order = %v, want the resumed #3 first", got)
	}
	if !res.Actions[0].Resume || res.Actions[1].Resume {
		t.Errorf("actions = %+v, want only #3 marked as a resume", res.Actions)
	}
}

func TestMaxParallelCapsReverifyAndDispatchTogether(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN"), leaf(2, "OPEN"), leaf(3, "OPEN")).state(3, newState(3))
	res, err := board.Classify(f.b, board.Options{LeaseToken: "", MaxParallel: 1})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Actions) != 1 || res.Actions[0].Kind != board.ActionDispatch || res.Actions[0].Issue != 3 || !res.Actions[0].Resume {
		t.Errorf("actions = %+v, want only the first prioritized reverify/dispatch action (resume #3)", res.Actions)
	}
}

func TestReleasedFreezeIsHistoryNotAnActiveFreeze(t *testing.T) {
	t.Parallel()

	env := envelope("ledger")
	env.Entity = state.EntityLedger
	f := newFx().with(leaf(1, "OPEN"))
	f.b.Ledger = &state.Ledger{Envelope: env, N: 1, Counters: zeroCounters(), FreezeSeq: 1, ReleaseWatermark: 0,
		Freeze: &state.Freeze{Seq: 1, Reason: "health", MergeSHA: "merge1", Health: "FAIL", Released: true}}
	res := classify(t, f)
	if res.Frozen {
		t.Fatal("released freeze still marks board frozen")
	}
	if got := actionsOf(res, board.ActionDispatch); !slices.Equal(got, []int{1}) {
		t.Errorf("dispatch = %v, want #1 while retaining freeze for health history", got)
	}
}

func TestExternalBlockerDoesNotResolveToSameNumberInEpic(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(5, "CLOSED"), leaf(6, "OPEN", snapshot.Blocker{Number: 5, State: "OPEN", Repo: "other/repo"}))
	if got := find(t, classify(t, f), 6); got.State != board.Waiting || !slices.Equal(got.WaitingOn, []int{5}) {
		t.Errorf("external blocker classified as %+v, want waiting on outside #5", got)
	}
}

func TestSignalsPastTheWatermarkAreProposedNotApplied(t *testing.T) {
	t.Parallel()

	blocked := newState(1)
	blocked.UnresolvedBlockers = []string{"needs a human"}
	blocked.SignalWatermark = 100
	f := newFx().with(leaf(1, "OPEN")).state(1, blocked).
		comment(90, "OWNER", "epic-retry").          // before the watermark: consumed
		comment(110, "OWNER", "the fix landed").     // context
		comment(120, "OWNER", "epic-retry").         // a decision
		comment(130, "NONE", "epic-drop").           // untrusted
		comment(140, "OWNER", "orchestrate-epic: x") // the loop's own
	res := classify(t, f)
	i := find(t, res, 1)
	if i.State != board.Parked || i.PendingDecision != "epic-retry" {
		t.Errorf("Issue = %+v, want still parked with a pending epic-retry", i)
	}
	if got := actionsOf(res, board.ActionApplySignals); !slices.Equal(got, []int{1}) {
		t.Errorf("apply_signals = %v, want [1]", got)
	}
	if got := actionsOf(res, board.ActionDispatch); len(got) != 0 {
		t.Errorf("dispatch = %v, want none until the decision is applied", got)
	}
}

func TestTheHighestIDDecisionWins(t *testing.T) {
	t.Parallel()

	blocked := newState(1)
	blocked.UnresolvedBlockers = []string{"x"}
	f := newFx().with(leaf(1, "OPEN")).state(1, blocked).comment(5, "OWNER", "epic-drop").comment(9, "MEMBER", "epic-redo")
	if got := find(t, classify(t, f), 1).PendingDecision; got != "epic-redo" {
		t.Errorf("pending decision = %q, want epic-redo", got)
	}
}

func TestStaleStart(t *testing.T) {
	t.Parallel()

	f := newFx().with(leaf(1, "OPEN")).state(1, newState(1))
	f.b.Notes[1] = map[string]bool{"start:1:feat/issue-1": true, "start:1:feat/issue-1-2": true}
	if keys := noteKeys(classify(t, f)); !slices.Equal(keys, []string{"stale-start:1:feat/issue-1"}) {
		t.Errorf("notes = %v, want stale-start:1:feat/issue-1", keys)
	}
	f.branch("feat/issue-1")
	if keys := noteKeys(classify(t, f)); len(keys) != 0 {
		t.Errorf("notes = %v, want none while the branch exists", keys)
	}
}
