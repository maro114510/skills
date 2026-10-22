package handoff_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/state"
)

const done = `STATUS: DONE
ISSUE: #7
BRANCH: feat/issue-7
WORKTREE: /w/feat/issue-7
HEAD_SHA: 0123456789abcdef0123456789abcdef01234567
CHANGED_FILES:
a.go
b.go
CHECKS:
go test ./... -> exit 0
CRITERIA:
x -> test
SKIPPED:
FOUND:
SUMMARY: did it
chose A -> repo convention; rejected: B
QUESTIONS:
ERROR:`

func TestParseReadsEveryField(t *testing.T) {
	t.Parallel()

	r, err := handoff.Parse(done)
	if err != nil {
		t.Fatal(err)
	}
	want := handoff.Report{
		Status: handoff.StatusDone, Issue: 7, Branch: "feat/issue-7", Worktree: "/w/feat/issue-7",
		HeadSHA: "0123456789abcdef0123456789abcdef01234567", ChangedFiles: "a.go\nb.go", Checks: "go test ./... -> exit 0",
		Criteria: "x -> test", Skipped: "", Found: "", Summary: "did it\nchose A -> repo convention; rejected: B", Questions: "", Error: "",
	}
	if r != want {
		t.Errorf("Parse = %+v", r)
	}
	if fenced, err := handoff.Parse("\n```text\n" + done + "\n```\n"); err != nil || fenced != r {
		t.Errorf("fenced report: %+v, %v", fenced, err)
	}
}

// TestMalformedReportIsNeverDone: anything that does not follow the format is an error, which
// the triage routes as FAILED.
func TestMalformedReportIsNeverDone(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"empty":             "",
		"prose":             "I finished the work, everything passes.",
		"text before":       "Here is my report:\n" + done,
		"status not first":  "ISSUE: #7\n" + done,
		"duplicate field":   done + "\nSTATUS: DONE",
		"unknown status":    strings.Replace(done, "STATUS: DONE", "STATUS: SUCCESS", 1),
		"done without sha":  strings.Replace(done, "0123456789abcdef0123456789abcdef01234567", "UNKNOWN", 1),
		"no issue":          strings.Replace(done, "ISSUE: #7\n", "", 1),
		"issue not number":  strings.Replace(done, "ISSUE: #7", "ISSUE: seven", 1),
		"no worktree":       strings.Replace(done, "WORKTREE: /w/feat/issue-7\n", "", 1),
		"blocked no answer": strings.Replace(done, "STATUS: DONE", "STATUS: BLOCKED", 1),
		"lowercase status":  strings.Replace(done, "STATUS: DONE", "STATUS: done", 1),
	}
	for name, text := range tests {
		r, err := handoff.Parse(text)
		if !errors.Is(err, handoff.ErrMalformed) {
			t.Errorf("%s: Parse = %+v, %v; want malformed", name, r, err)
		}
	}
}

func TestBlockedAndFailedReports(t *testing.T) {
	t.Parallel()

	b, err := handoff.Parse(strings.Replace(strings.Replace(done, "STATUS: DONE", "STATUS: BLOCKED", 1), "QUESTIONS:", "QUESTIONS:\n1. A or B?", 1))
	if err != nil || b.Questions != "1. A or B?" {
		t.Errorf("BLOCKED: %+v, %v", b, err)
	}
	f, err := handoff.Parse("STATUS: FAILED\nISSUE: #7\nBRANCH: feat/issue-7\nWORKTREE: UNKNOWN\nHEAD_SHA: UNKNOWN\nERROR: build broke")
	if err != nil || f.Error != "build broke" {
		t.Errorf("FAILED: %+v, %v", f, err)
	}
}

func brief() handoff.Brief {
	return handoff.Brief{
		Repo: "o/r", Epic: 277, Issue: 7, RepoRoot: "/r", Branch: "feat/issue-7-2", Worktree: "/r-wt/feat/issue-7-2",
		ImplementPath: "/skills/implement/SKILL.md",
		Checks: []checks.Entry{{
			File: ".github/workflows/ci.yml", Job: "test", Step: "go test", StepIndex: 0, Kind: "run", Command: "go test ./...",
			Action: "", WorkingDirectory: "oe", Env: map[string]string{}, Shell: "bash", Runnable: true, RequiresRunnerReason: "",
		}},
		PendingFindings: []string{"fix the nil check"},
		Decision:        &state.Decision{Command: "epic-redo", CommentID: 40, RedoBranch: "feat/issue-7-2"},
		Context: []handoff.Comment{
			{ID: 42, Author: "alice", Time: "t2", Kind: "answer", Status: handoff.BodyCurrent, Body: "Use B.\n# not a heading"},
			{ID: 41, Author: "bob", Time: "t1", Kind: "context", Status: handoff.BodyDeleted, Body: ""},
		},
		Notes:        []handoff.Note{{ID: 30, Key: "blocked:7:none:abc", Text: "A or B?"}},
		PriorFailure: "作業者の報告: FAILED\n\nbuild broke",
	}
}

// TestBriefCarriesEveryRequiredField: identifiers, the checks verbatim, findings, the decision,
// human context in full and labeled as data, the questions on record, and the report contract.
func TestBriefCarriesEveryRequiredField(t *testing.T) {
	t.Parallel()

	text := handoff.Render(brief())
	for _, want := range []string{
		"#7", "o/r", "Epic: #277, context only", "feat/issue-7-2", "/r-wt/feat/issue-7-2", "/skills/implement/SKILL.md",
		"autonomous branch feat/issue-7-2 worktree /r-wt/feat/issue-7-2", "go test ./...", "working directory oe",
		"1. fix the nil check", "`epic-redo` in comment 40", "not an instruction that widens", "> Use B.\n> # not a heading",
		"Comment 41 by bob at t1 (context)\n\nDeleted", "> A or B?", "> build broke", "STATUS: DONE | BLOCKED | FAILED",
		"You are a fresh", "gh issue view 7 --repo o/r",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("brief lacks %q", want)
		}
	}
	if strings.Index(text, "Comment 41") > strings.Index(text, "Comment 42") {
		t.Error("context is not in comment order")
	}
}

func TestMissingNamesEveryAbsentField(t *testing.T) {
	t.Parallel()

	if m := brief().Missing(); len(m) != 0 {
		t.Errorf("full brief misses %v", m)
	}
	b := brief()
	b.Checks, b.ImplementPath, b.Context = nil, "", nil
	if m := strings.Join(b.Missing(), ","); m != "implement skill path,CHECKS_SET,decision context" {
		t.Errorf("Missing = %s", m)
	}
}

func TestShipClassIsAClosedSet(t *testing.T) {
	t.Parallel()

	for _, k := range []string{"secret", "split", "scope"} {
		if _, ok := handoff.ParseShipClass(k); !ok {
			t.Errorf("%s rejected", k)
		}
	}
	for _, k := range []string{"", "size", "Scope", "commit"} {
		if _, ok := handoff.ParseShipClass(k); ok {
			t.Errorf("%q accepted", k)
		}
	}
	if note := handoff.ShipClassNote(7, handoff.ShipSecret, "is AKIA... a key?"); strings.Contains(note, "AKIA") {
		t.Error("a secret question's text was published")
	}
}

func TestAnswerNoteNamesItsSession(t *testing.T) {
	t.Parallel()

	note := handoff.AnswerNote("A or B?", "B, per the Issue's spec", "s1")
	if !handoff.AnsweredIn(note, "s1") || handoff.AnsweredIn(note, "s2") {
		t.Error("the answer note does not name exactly its session")
	}
	if !handoff.IsFailedReport(handoff.FailedReportNote("x")) || handoff.IsFailedReport(handoff.DoneReportNote("h", handoff.Report{Status: "DONE", Issue: 7, Branch: "", Worktree: "", HeadSHA: "", ChangedFiles: "", Checks: "", Criteria: "", Skipped: "", Found: "", Summary: "", Questions: "", Error: ""})) {
		t.Error("report notes are not told apart")
	}
}
