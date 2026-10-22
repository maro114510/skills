package review_test

import (
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/review"
)

// TestReviewerPromptPinsThePairAndTheDefaultBranch shows that the reviewer gets the default branch by name, the pinned head, CHECKS_SET, and a diff against the pinned base commit.
// The brief has no field for a worker report, so the reviewer never sees one.
func TestReviewerPromptPinsThePairAndTheDefaultBranch(t *testing.T) {
	t.Parallel()

	b := review.Brief{
		Repo: "o/r", Epic: 277, Issue: 7, Branch: "feat/issue-7", Worktree: "/w/feat/issue-7", DefaultBranch: "trunk",
		Base: base, Head: head, ChecksRevision: base,
		Checks: []checks.Entry{{File: "ci.yml", Job: "test", Step: "go test", StepIndex: 0, Kind: "run", Command: "go test ./...",
			Action: "", WorkingDirectory: "oe", Env: map[string]string{"CGO_ENABLED": "0"}, Shell: "bash", Runnable: true, RequiresRunnerReason: ""}},
	}
	p := review.Render(b)
	for _, want := range []string{
		"Default branch: trunk", "git -C /w/feat/issue-7 diff " + base + " " + head, "REVIEW_HEAD: " + head,
		"go test ./...", "CGO_ENABLED=0", "REVIEWED_BASE: " + base, "CHECKS_REVISION: " + base, "never shown the worker's report",
		"Never edit, stage, commit",
	} {
		if !strings.Contains(p, want) {
			t.Errorf("prompt lacks %q", want)
		}
	}
	for _, unwanted := range []string{"origin/main", "HEAD_SHA:", "STATUS:"} {
		if strings.Contains(p, unwanted) {
			t.Errorf("prompt holds %q", unwanted)
		}
	}
}

// TestPromptQuotesTheWorktreePath shows that a worktree path with spaces stays one argument in every command the reviewer runs.
func TestPromptQuotesTheWorktreePath(t *testing.T) {
	t.Parallel()

	p := review.Render(review.Brief{Repo: "o/r", Epic: 1, Issue: 7, Branch: "b", Worktree: "/My Repo-wt/b", DefaultBranch: "main",
		Base: "b1", Head: "h1", ChecksRevision: "b1", Checks: nil})
	if !strings.Contains(p, "git -C '/My Repo-wt/b' diff b1 h1") || strings.Contains(p, "git -C /My Repo") {
		t.Errorf("prompt = %s", p)
	}
}
