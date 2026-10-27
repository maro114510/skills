package round_test

import (
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/round"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

const loopLogin = "loop"

func leafIssue(n int, st, title string) snapshot.Issue {
	return snapshot.Issue{Number: n, State: st, Title: title, Body: "", CreatedAt: "", Blockers: nil, Children: nil}
}

func epicBoard(children ...snapshot.Issue) *snapshot.Board {
	var b snapshot.Board
	b.Repo, b.Epic, b.Me, b.Children = "o/r", 277, loopLogin, children
	return &b
}

func classified(n int, st board.State, title string) board.Issue {
	return board.Issue{
		Number: n, Title: title, Container: 0, State: st, Reason: "reason of " + string(st),
		Branch: "", PR: 0, MergedPR: 0, WaitingOn: nil, PendingDecision: "",
	}
}

func result(issues ...board.Issue) board.Result {
	var r board.Result
	r.Epic, r.Issues = 277, issues
	return r
}

func noteComment(id int64, key, text string) snapshot.Comment {
	return snapshot.Comment{ID: id, CreatedAt: "", Author: loopLogin, Association: "OWNER", Body: "<!-- oe:v2 note " + key + " -->\n" + text}
}

func issueState(t *testing.T, id int64, n int, edit func(*state.Issue)) snapshot.Comment {
	t.Helper()
	var st state.Issue
	st.Entity, st.Key, st.Revision, st.UpdatedBy = state.EntityIssue, state.IssueKey(n), 1, "earlier"
	st.Branch = "feat/issue-" + strconv.Itoa(n)
	st.PendingFindings, st.UnresolvedBlockers, st.Context = []string{}, []string{}, []state.Context{}
	edit(&st)
	body, err := protocol.EncodeState(&st)
	if err != nil {
		t.Fatal(err)
	}
	return snapshot.Comment{ID: id, CreatedAt: "", Author: loopLogin, Association: "OWNER", Body: body}
}

func assess(t *testing.T, res board.Result, b *snapshot.Board, comments map[int][]snapshot.Comment) round.Report {
	t.Helper()
	rep, err := round.Assess(res, b, comments)
	if err != nil {
		t.Fatalf("Assess: %v", err)
	}
	return rep
}

func TestAnEpicWhoseIssuesAreAllDoneIsCompleteAndNamesWhatMerged(t *testing.T) {
	t.Parallel()

	b := epicBoard(leafIssue(3, "CLOSED", "Add the flag"), leafIssue(4, "CLOSED", "Document the flag"))

	rep := assess(t, result(classified(3, board.Done, "Add the flag"), classified(4, board.Done, "Document the flag")), b, nil)

	if !rep.Complete() || len(rep.Unfinished) != 0 {
		t.Fatalf("report = %+v, want complete", rep)
	}
	text := rep.Text()
	for _, want := range []string{"Epic #277", "#3", "Add the flag", "#4", "Document the flag"} {
		if !strings.Contains(text, want) {
			t.Errorf("completion text lacks %q:\n%s", want, text)
		}
	}
}

func TestAnIssueTheLoopCanStillMoveKeepsTheEpicFromCompleting(t *testing.T) {
	t.Parallel()

	for _, st := range []board.State{
		board.Ready, board.InProgress, board.Reverify, board.AwaitingMerge, board.Verifying, board.Waiting, board.Parked, board.Rejected,
	} {
		b := epicBoard(leafIssue(3, "CLOSED", "done one"), leafIssue(4, "OPEN", "other"))

		rep := assess(t, result(classified(3, board.Done, "done one"), classified(4, st, "other")), b, nil)

		if rep.Complete() {
			t.Errorf("%s: complete, want unfinished", st)
			continue
		}
		if len(rep.Unfinished) != 1 || rep.Unfinished[0].Issue != 4 || rep.Unfinished[0].State != string(st) {
			t.Errorf("%s: unfinished = %+v, want Issue 4 in that state", st, rep.Unfinished)
		}
	}
}

func TestAnEpicWithNoDispatchableIssueIsNotComplete(t *testing.T) {
	t.Parallel()

	rep := assess(t, result(), epicBoard(), nil)

	if rep.Epic != 277 {
		t.Errorf("the report names Epic %d, want 277", rep.Epic)
	}
	if rep.Complete() {
		t.Error("an Epic with nothing to dispatch is complete, want not: an empty board is more likely misread than finished")
	}
}

func TestAParkedIssueCountsOnlyOnceAnEpicDropWasApplied(t *testing.T) {
	t.Parallel()

	b := epicBoard(leafIssue(3, "CLOSED", "done one"), leafIssue(6, "OPEN", "capped"))
	parked := classified(6, board.Parked, "capped")
	issues := result(classified(3, board.Done, "done one"), parked)

	if rep := assess(t, issues, b, nil); rep.Complete() {
		t.Fatal("complete with a parked Issue that has no drop decision")
	}
	pending := parked
	pending.PendingDecision = "epic-drop"
	if rep := assess(t, result(classified(3, board.Done, "done one"), pending), b, nil); rep.Complete() {
		t.Fatal("complete with a drop that is not applied to the state yet")
	}

	comments := map[int][]snapshot.Comment{6: {issueState(t, 10, 6, func(s *state.Issue) {
		s.UnresolvedBlockers = []string{"fix cycle cap reached: a nit remains"}
		s.Decision = &state.Decision{Command: "epic-drop", CommentID: 99, RedoBranch: ""}
	})}}
	rep := assess(t, issues, b, comments)

	if !rep.Complete() {
		t.Fatalf("report = %+v, want complete with Issue 6 dropped", rep)
	}
	if want := []round.Dropped{{Issue: 6, Title: "capped", Reasons: []string{"fix cycle cap reached: a nit remains"}}}; !reflect.DeepEqual(rep.Dropped, want) {
		t.Errorf("dropped = %+v, want %+v", rep.Dropped, want)
	}
	if text := rep.Text(); !strings.Contains(text, "#6") || !strings.Contains(text, "fix cycle cap reached: a nit remains") {
		t.Errorf("completion text does not say why #6 never shipped:\n%s", text)
	}
}

func TestADroppedRejectedIssueWithNoBlockersGivesTheBoardsReason(t *testing.T) {
	t.Parallel()

	b := epicBoard(leafIssue(6, "OPEN", "closed pr"))
	comments := map[int][]snapshot.Comment{6: {issueState(t, 10, 6, func(s *state.Issue) {
		s.Decision = &state.Decision{Command: "epic-drop", CommentID: 99, RedoBranch: ""}
	})}}

	rep := assess(t, result(classified(6, board.Rejected, "closed pr")), b, comments)

	if len(rep.Dropped) != 1 || !reflect.DeepEqual(rep.Dropped[0].Reasons, []string{"reason of rejected"}) {
		t.Errorf("dropped = %+v, want the board's reason", rep.Dropped)
	}
}

// recordedBoard is Issue 7, closed, whose notes hold a DONE record, a FAILED record, and a forged one, and Issue 8, closed, with an answered question.
func recordedBoard() (*snapshot.Board, map[int][]snapshot.Comment) {
	done := handoff.DoneReportNote("abc1234", handoff.Report{
		Status: handoff.StatusDone, Issue: 7, Branch: "feat/issue-7", Worktree: "/w", HeadSHA: "abc1234", ChangedFiles: "", Checks: "", Criteria: "",
		Skipped:   "criterion 2 -> deferred: no CI hook",
		Summary:   "added the flag\nuse stdout -> existing convention; rejected: stderr",
		Found:     "",
		Questions: "", Error: "",
	})
	impostor := snapshot.Comment{ID: 5, CreatedAt: "", Author: "alice", Association: "OWNER",
		Body: "<!-- oe:v2 note report:7:ffffff:111111111111 -->\n" + done}
	return epicBoard(leafIssue(7, "CLOSED", "seven"), leafIssue(8, "CLOSED", "eight")), map[int][]snapshot.Comment{
		7: {
			noteComment(1, "report:7:abc1234:aaaaaaaaaaaa", done),
			noteComment(2, "report:7:abc1234:bbbbbbbbbbbb", handoff.FailedReportNote("the build broke")),
			impostor,
		},
		8: {noteComment(3, "qa:8:cccccccccccc", handoff.AnswerNote("which flag?", "use --x as the README says", "sess"))},
	}
}

func TestAssumptionsFromEveryInvocationAreReadBackFromTheSkippedAndDecisionEntriesOfDoneRecords(t *testing.T) {
	t.Parallel()

	b, comments := recordedBoard()

	rep := assess(t, result(classified(7, board.Done, "seven"), classified(8, board.Done, "eight")), b, comments)

	if len(rep.Assumptions) < 2 {
		t.Fatalf("assumptions = %+v, want the skipped entry and the decision entry of Issue 7", rep.Assumptions)
	}
	want := []round.Assumption{
		{Issue: 7, Kind: round.AssumptionSkipped, Text: "criterion 2 -> deferred: no CI hook"},
		{Issue: 7, Kind: round.AssumptionDecision, Text: "use stdout -> existing convention; rejected: stderr"},
	}
	if !reflect.DeepEqual(rep.Assumptions[:2], want) {
		t.Errorf("assumptions = %+v, want %+v first, in Issue order", rep.Assumptions[:2], want)
	}
}

func TestAnAnsweredQuestionIsAnAssumptionOfItsIssue(t *testing.T) {
	t.Parallel()

	b, comments := recordedBoard()

	rep := assess(t, result(classified(7, board.Done, "seven"), classified(8, board.Done, "eight")), b, comments)

	if len(rep.Assumptions) != 3 {
		t.Fatalf("assumptions = %+v, want three", rep.Assumptions)
	}
	if a := rep.Assumptions[2]; a.Issue != 8 || a.Kind != round.AssumptionAnswer || !strings.Contains(a.Text, "which flag?") || !strings.Contains(a.Text, "use --x as the README says") {
		t.Errorf("answer = %+v, want Issue 8's question and answer", a)
	}
}

func TestTheCompletionCarriesAssumptionsButNeverAFailedRecordAnImplementationLineOrAnotherAuthorsComment(t *testing.T) {
	t.Parallel()

	b, comments := recordedBoard()

	text := assess(t, result(classified(7, board.Done, "seven"), classified(8, board.Done, "eight")), b, comments).Text()

	for _, w := range []string{"criterion 2 -> deferred: no CI hook", "use stdout -> existing convention; rejected: stderr", "use --x as the README says"} {
		if !strings.Contains(text, w) {
			t.Errorf("completion text lacks %q", w)
		}
	}
	for _, never := range []string{"the build broke", "added the flag", "ffffff"} {
		if strings.Contains(text, never) {
			t.Errorf("completion text carries %q: a FAILED record, an implementation line, or another author's comment", never)
		}
	}
}

func TestACommentTheLoopCannotReadStopsTheAssessmentWithTheProtocolError(t *testing.T) {
	t.Parallel()

	b := epicBoard(leafIssue(7, "CLOSED", "seven"))
	v1 := snapshot.Comment{ID: 1, CreatedAt: "", Author: loopLogin, Association: "OWNER", Body: "orchestrate-epic:ledger worker_dispatches=1"}

	_, err := round.Assess(result(classified(7, board.Done, "seven")), b, map[int][]snapshot.Comment{7: {v1}})

	if exitcode.CodeOf(err) != exitcode.Protocol {
		t.Errorf("Assess = %v, want exit 6", err)
	}
}

func TestTheTextReportsOnlyWhatOeAlreadyHasLedgerCountsFixCyclesAndLostDispatches(t *testing.T) {
	t.Parallel()

	b := epicBoard(leafIssue(7, "CLOSED", "seven"), leafIssue(9, "CLOSED", "nine"))
	var ledger state.Ledger
	ledger.Counters = state.Counters{
		WorkerDispatches: state.Counter{Used: 3, Bound: 15},
		ReviewerPasses:   state.Counter{Used: 2, Bound: 12},
		FixCycles:        state.Counter{Used: 1, Bound: 6},
	}
	b.Ledger = &ledger
	comments := map[int][]snapshot.Comment{
		7: {issueState(t, 10, 7, func(s *state.Issue) { s.Cycle = 2 })},
		9: {noteComment(11, "stale-start:9:feat/issue-9", "lost")},
	}

	text := assess(t, result(classified(7, board.Done, "seven"), classified(9, board.Done, "nine")), b, comments).Text()

	for _, want := range []string{"3 / 15", "2 / 12", "1 / 6", "#7: 2", "1 件"} {
		if !strings.Contains(text, want) {
			t.Errorf("completion text lacks %q:\n%s", want, text)
		}
	}
	for _, dropped := range []string{"wall clock", "APPROVE", "CI-failure", "CI 失敗", "所要時間"} {
		if strings.Contains(text, dropped) {
			t.Errorf("completion text carries the dropped metric %q", dropped)
		}
	}
}

func TestTheTextNamesFullyDoneOpenContainersAndLeavesClosingEveryThingToAPerson(t *testing.T) {
	t.Parallel()

	open := leafIssue(50, "OPEN", "theme")
	open.Children = []snapshot.Issue{leafIssue(51, "CLOSED", "a"), leafIssue(52, "CLOSED", "b")}
	closed := leafIssue(60, "CLOSED", "old theme")
	closed.Children = []snapshot.Issue{leafIssue(61, "CLOSED", "c")}
	b := epicBoard(open, closed)
	res := result(classified(51, board.Done, "a"), classified(52, board.Done, "b"), classified(61, board.Done, "c"))
	res.Containers = []board.Container{
		{Number: 50, Title: "theme", Done: true, Children: []int{51, 52}},
		{Number: 60, Title: "old theme", Done: true, Children: []int{61}},
	}

	rep := assess(t, res, b, nil)

	if !reflect.DeepEqual(rep.DoneContainers, []int{50}) {
		t.Errorf("done containers = %v, want only the open one, #50", rep.DoneContainers)
	}
	text := rep.Text()
	for _, want := range []string{"#50", "Epic #277", "閉じ"} {
		if !strings.Contains(text, want) {
			t.Errorf("completion text lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "#60") {
		t.Error("completion text names the container that is already closed")
	}
}

func TestAnOversizedRecordFallsBackToACountSoTheCompletionCanStillBePosted(t *testing.T) {
	t.Parallel()

	long := strings.Repeat("あ", 300)
	var rep round.Report
	rep.Epic, rep.Merged = 277, []board.Issue{classified(3, board.Done, "Add the flag")}
	for i := range 400 {
		rep.Assumptions = append(rep.Assumptions, round.Assumption{Issue: 3, Kind: round.AssumptionDecision, Text: long + strconv.Itoa(i)})
	}

	text := rep.Text()

	if len(text) > 100_000 {
		t.Errorf("the completion is %d bytes, over the 100000 the comment writer can take", len(text))
	}
	for _, want := range []string{"Epic #277", "#3 Add the flag", "400 件"} {
		if !strings.Contains(text, want) {
			t.Errorf("the compact completion lacks %q", want)
		}
	}
}

func TestARecordThatFitsIsNeverShortened(t *testing.T) {
	t.Parallel()

	var rep round.Report
	rep.Epic, rep.Merged = 277, []board.Issue{classified(3, board.Done, "Add the flag")}
	rep.Assumptions = []round.Assumption{{Issue: 3, Kind: round.AssumptionSkipped, Text: "criterion 2 -> deferred"}}

	if text := rep.Text(); !strings.Contains(text, "criterion 2 -> deferred") {
		t.Errorf("a record that fits was shortened:\n%s", text)
	}
}

func TestAnAsciiRecordIsCountedBeforeItPassesTheWritersCharacterLimit(t *testing.T) {
	t.Parallel()

	var rep round.Report
	rep.Epic, rep.Merged = 277, []board.Issue{classified(3, board.Done, "Add the flag")}
	for i := range 250 {
		rep.Assumptions = append(rep.Assumptions, round.Assumption{Issue: 3, Kind: round.AssumptionDecision, Text: strings.Repeat("a", 300) + strconv.Itoa(i)})
	}

	text := rep.Text()

	if n := utf8.RuneCountInString(text); n > 65536-1024 {
		t.Errorf("the completion is %d characters, over the 65536 the comment writer takes once its marker line is added", n)
	}
	if !strings.Contains(text, "250 件") {
		t.Error("the compact completion does not count the assumptions")
	}
}

func TestADroppedIssueWithANewerDecisionPendingIsUnfinished(t *testing.T) {
	t.Parallel()

	b := epicBoard(leafIssue(6, "OPEN", "capped"))
	comments := map[int][]snapshot.Comment{6: {issueState(t, 10, 6, func(s *state.Issue) {
		s.UnresolvedBlockers = []string{"fix cycle cap reached"}
		s.Decision = &state.Decision{Command: "epic-drop", CommentID: 99, RedoBranch: ""}
	})}}
	parked := classified(6, board.Parked, "capped")
	parked.PendingDecision = "epic-retry"

	rep := assess(t, result(parked), b, comments)

	if rep.Complete() || len(rep.Dropped) != 0 || len(rep.Unfinished) != 1 || rep.Unfinished[0].Issue != 6 {
		t.Errorf("report = %+v, want Issue 6 unfinished: a person's newer retry has not been applied yet", rep)
	}
}

func TestEveryRenderingOfALargeRecordFitsTheWritersLimits(t *testing.T) {
	t.Parallel()

	for name, unit := range map[string]string{"ASCII": strings.Repeat("a", 400), "Japanese": strings.Repeat("あ", 400)} {
		var rep round.Report
		rep.Epic, rep.Cycles = 277, map[int]int{}
		for i := 1; i <= 4000; i++ {
			rep.Merged = append(rep.Merged, classified(i, board.Done, unit))
			rep.Dropped = append(rep.Dropped, round.Dropped{Issue: 10000 + i, Title: unit, Reasons: []string{unit, unit}})
			rep.Cycles[i] = 2
			rep.DoneContainers = append(rep.DoneContainers, 20000+i)
		}

		text := rep.Text()

		if n := utf8.RuneCountInString(text); n > 60_000 || len(text) > 100_000 {
			t.Errorf("%s: the completion is %d characters and %d bytes, over the limits the comment writer takes", name, n, len(text))
		}
		if !strings.Contains(text, "Epic #277") || !strings.Contains(text, "4000") {
			t.Errorf("%s: the smallest completion lacks the Epic or the counts", name)
		}
	}
}

func TestAHeadingInsideFreeFormNoteTextDoesNotCutTheRecord(t *testing.T) {
	t.Parallel()

	done := handoff.DoneReportNote("abc1234", handoff.Report{
		Status: handoff.StatusDone, Issue: 7, Branch: "feat/issue-7", Worktree: "/w", HeadSHA: "abc1234", ChangedFiles: "", Checks: "", Criteria: "",
		Skipped:   "criterion 2 -> deferred\n### Notes\nthe CI hook is missing",
		Summary:   "added the flag\n### Rationale\nuse stdout -> existing convention; rejected: stderr",
		Found:     "",
		Questions: "", Error: "",
	})
	b := epicBoard(leafIssue(7, "CLOSED", "seven"))
	comments := map[int][]snapshot.Comment{7: {noteComment(1, "report:7:abc1234:aaaaaaaaaaaa", done)}}

	rep := assess(t, result(classified(7, board.Done, "seven")), b, comments)

	var texts []string
	for _, a := range rep.Assumptions {
		texts = append(texts, a.Text)
	}
	for _, want := range []string{"criterion 2 -> deferred", "### Notes", "the CI hook is missing", "use stdout -> existing convention; rejected: stderr"} {
		if !slices.Contains(texts, want) {
			t.Errorf("assumptions = %q lack %q: a heading inside free-form text ended its section early", texts, want)
		}
	}
}
