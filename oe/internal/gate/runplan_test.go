package gate_test

import (
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/gate"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

func issue(n int, title string, s board.State, waitingOn ...int) board.Issue {
	return board.Issue{
		Number: n, Title: title, Container: 0, State: s, Reason: "", Branch: "", PR: 0, MergedPR: 0,
		WaitingOn: waitingOn, PendingDecision: "",
	}
}

func entry(file, job, step, command, action, workdir, reason string, runnable bool) checks.Entry {
	kind := "run"
	if command == "" {
		kind = "action"
	}
	return checks.Entry{
		File: file, Job: job, Step: step, StepIndex: 0, Kind: kind, Command: command, Action: action,
		WorkingDirectory: workdir, Env: map[string]string{}, Shell: "bash", Runnable: runnable, RequiresRunnerReason: reason,
	}
}

func samplePlan() gate.Plan {
	return gate.Plan{
		Epic: 277, DefaultBranch: "main",
		Protection: snapshot.Protection{Configured: false, RequiredChecks: []string{}, RequiredReviewers: 0},
		Checks: checks.Set{
			Ref: "origin/main", Base: "main", Revision: "0123456789abcdef", DefaultBranchPush: checks.PushRuns,
			Entries: []checks.Entry{
				entry(".github/workflows/ci.yml", "test", "go test", "go test ./...\ngo vet ./...", "", "oe", "", true),
				entry(".github/workflows/ci.yml", "lint", "", "", "golangci/golangci-lint-action@v9", "", "marketplace action", false),
			},
		},
		Issues: []board.Issue{
			issue(278, "Fix | pipes", board.Done),
			issue(286, "Gate", board.Ready),
			issue(287, "Handoff", board.Waiting, 286),
		},
		MaxParallel: 3,
		Budget:      coord.NewLedger(2),
	}
}

// TestRunPlanStatesTheFactsAndBounds guards the Run Plan requirement and RF-04, RF-05, BN-01,
// BN-03, and GL-15: it states branch protection, CHECKS_SET split into runnable and runner-only
// entries, the push-trigger and health limitation, the per-Issue worst case, and the Epic-wide
// budget, with no time or token limit.
func TestRunPlanStatesTheFactsAndBounds(t *testing.T) {
	t.Parallel()

	text := gate.Render(samplePlan())
	for _, want := range []string{
		"## Run Plan — Epic #277",
		"branch protection (`main`): なし",
		"ruleset は読み取っていません",
		"`.github/workflows/` の `0123456789ab` から derive",
		"  - 実行可能:\n    - .github/workflows/ci.yml / test / go test: `go test ./... go vet ./...`（working directory: `oe`）",
		"  - ローカル検証不可（このループは実行しない）:\n    - .github/workflows/ci.yml / lint / step 1: `golangci/golangci-lint-action@v9` — marketplace action",
		"[!] required checks も required reviewers も未設定です",
		"| #278 | Fix \\| pipes | done | - | - |",
		"| #286 | Gate | ready | - | main |",
		"| #287 | Handoff | waiting | #286 | main |",
		"- max-parallel: 3",
		"fix-cycle cap: Issue あたり 2",
		"worker 最大 5 回",
		"reviewer 最大 4 回",
		"N = 2",
		"worker dispatch 10 回（使用 0）、reviewer 実行 8 回（使用 0。staleness 再検証は数えません）、fix cycle 4 回（使用 0）",
		"wall-clock やトークン消費量による自動停止はありません",
		"ラベルは読み取りも付与もしません",
		"`epic-approve` とだけ書いたコメント",
		"`epic-auto-merge` とだけ書いたコメント",
		"60 秒間隔で最大 30 回",
		"10 分経ってもチェックが 1 件も報告されない場合、60 分経っても終わらないチェックがある場合",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("Run Plan lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "push で動く workflow") {
		t.Errorf("a default branch with an unfiltered push workflow carries no push warning:\n%s", text)
	}
	if text != gate.Render(samplePlan()) {
		t.Error("Render is not deterministic")
	}
}

func TestRunPlanWarnsWhenNoPushCanConfirmAMerge(t *testing.T) {
	t.Parallel()

	for push, want := range map[string]string{
		checks.PushNone:     "default branch への push で動く workflow がありません",
		checks.PushFiltered: "`paths` / `paths-ignore` で絞られています",
	} {
		p := samplePlan()
		p.Checks.DefaultBranchPush = push
		if text := gate.Render(p); !strings.Contains(text, want) {
			t.Errorf("%s: Run Plan lacks %q", push, want)
		}
	}
}

func TestRunPlanStatesConfiguredProtection(t *testing.T) {
	t.Parallel()

	p := samplePlan()
	p.Protection = snapshot.Protection{Configured: true, RequiredChecks: []string{"test"}, RequiredReviewers: 1}
	text := gate.Render(p)
	if !strings.Contains(text, "あり（required checks: `test`、required reviewers: 1 人）") || strings.Contains(text, "未設定です") {
		t.Errorf("Run Plan:\n%s", text)
	}
	p.Protection = snapshot.Protection{Configured: true, RequiredChecks: []string{}, RequiredReviewers: 0}
	if text := gate.Render(p); !strings.Contains(text, "あり（required checks: なし、required reviewers: なし）") || !strings.Contains(text, "未設定です") {
		t.Errorf("protection without a gate:\n%s", text)
	}
}

func TestRunPlanKeepsABacktickCommandInOneSpan(t *testing.T) {
	t.Parallel()

	p := samplePlan()
	p.Checks.Entries = []checks.Entry{entry("w.yml", "j", "s", "echo `date`", "", "", "", true)}
	if text := gate.Render(p); !strings.Contains(text, "w.yml / j / s: `` echo `date` ``（working directory: `.`）") {
		t.Errorf("Run Plan:\n%s", text)
	}
}
