package round_test

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/round"
	"github.com/maro114510/skills/oe/internal/runner"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	ident := []string{"-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir}
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, append(ident, args...))
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("git %v: %v, exit %d\n%s", args, err, res.ExitCode, res.Stderr)
	}
	return strings.TrimSpace(string(res.Stdout))
}

// checkout is a shared checkout on main with one commit.
type checkout struct {
	t      *testing.T
	root   string
	shared string
}

func newCheckout(t *testing.T) *checkout {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	c := &checkout{t: t, root: root, shared: filepath.Join(root, "r")}
	git(t, root, "init", "-q", "-b", "main", c.shared)
	c.write(c.shared, "a.txt", "one")
	git(t, c.shared, "add", "a.txt")
	git(t, c.shared, "commit", "-q", "-m", "one")
	return c
}

func (c *checkout) write(dir, file, text string) {
	c.t.Helper()
	if err := os.WriteFile(filepath.Join(dir, file), []byte(text), 0o600); err != nil {
		c.t.Fatal(err)
	}
}

// issueWorktree is a worktree on a new branch with one commit of its own, and returns its path.
func (c *checkout) issueWorktree(branch string) string {
	c.t.Helper()
	path := filepath.Join(c.root, "r-wt", filepath.FromSlash(branch))
	git(c.t, c.shared, "worktree", "add", "-q", "-b", branch, path)
	file := "work-" + filepath.Base(branch) + ".txt"
	c.write(path, file, branch)
	git(c.t, path, "add", file)
	git(c.t, path, "commit", "-q", "-m", branch)
	return path
}

// merged merges the branch into main in the shared checkout, as a merged pull request would.
func (c *checkout) merged(branch string) {
	git(c.t, c.shared, "merge", "-q", "--no-ff", "-m", "merge "+branch, branch)
}

func (c *checkout) hasBranch(branch string) bool {
	return git(c.t, c.shared, "branch", "--list", branch) != ""
}

func (c *checkout) sharedState() string {
	return git(c.t, c.shared, "rev-parse", "HEAD") + "|" + git(c.t, c.shared, "branch", "--show-current") + "|" +
		git(c.t, c.shared, "status", "--porcelain", "--untracked-files=all")
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// recordingGit runs real git and remembers every write.
type recordingGit struct {
	c      *gh.Client
	writes [][]string
}

func newRecordingGit() *recordingGit {
	return &recordingGit{c: gh.New(runner.Exec{}, false), writes: nil}
}

func (g *recordingGit) Git(ctx context.Context, args ...string) ([]byte, error) {
	return g.c.Git(ctx, args...)
}

func (g *recordingGit) GitWrite(ctx context.Context, args ...string) ([]byte, error) {
	g.writes = append(g.writes, args)
	return g.c.GitWrite(ctx, args...)
}

func TestACleanWorktreeOfAnIssueClosedWithAMergedPRIsRemovedAndItsMergedBranchDeleted(t *testing.T) {
	t.Parallel()

	c := newCheckout(t)
	path := c.issueWorktree("feat/issue-7")
	c.merged("feat/issue-7")

	res, err := round.Cleanup(t.Context(), newRecordingGit(), c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}})

	if err != nil {
		t.Fatal(err)
	}
	want := []round.Removed{{Issue: 7, Branch: "feat/issue-7", Worktree: path, BranchDeleted: true}}
	if !reflect.DeepEqual(res.Removed, want) || len(res.Kept) != 0 {
		t.Errorf("result = %+v, want %+v removed and nothing kept", res, want)
	}
	if exists(path) || c.hasBranch("feat/issue-7") {
		t.Errorf("worktree exists %v, branch exists %v; want both gone", exists(path), c.hasBranch("feat/issue-7"))
	}
}

// dirtyAndClean is Issue 7, merged, with an uncommitted file in its worktree, and Issue 8, merged and clean.
func dirtyAndClean(t *testing.T) (c *checkout, dirty, clean string, res round.CleanupResult) {
	t.Helper()
	c = newCheckout(t)
	dirty = c.issueWorktree("feat/issue-7")
	c.write(dirty, "scratch.txt", "not committed")
	clean = c.issueWorktree("feat/issue-8")
	c.merged("feat/issue-7")
	c.merged("feat/issue-8")
	res, err := round.Cleanup(t.Context(), newRecordingGit(), c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}, {Issue: 8, Branch: "feat/issue-8"}})
	if err != nil {
		t.Fatal(err)
	}
	return c, dirty, clean, res
}

func TestADirtyWorktreeIsReportedAndKeptWithItsBranch(t *testing.T) {
	t.Parallel()

	c, dirty, _, res := dirtyAndClean(t)

	if len(res.Kept) != 1 || res.Kept[0].Issue != 7 || res.Kept[0].Worktree != dirty || !strings.Contains(res.Kept[0].Reason, "uncommitted") {
		t.Fatalf("kept = %+v, want Issue 7's dirty worktree with its reason", res.Kept)
	}
	if !exists(dirty) || !c.hasBranch("feat/issue-7") {
		t.Error("the dirty worktree or its branch was taken away")
	}
}

func TestADirtyWorktreeNeverStopsTheCleanupOfTheOthers(t *testing.T) {
	t.Parallel()

	c, _, clean, res := dirtyAndClean(t)

	if exists(clean) || c.hasBranch("feat/issue-8") || len(res.Removed) != 1 || res.Removed[0].Issue != 8 {
		t.Errorf("Issue 8: worktree exists %v, branch exists %v, removed %+v; want it cleaned up", exists(clean), c.hasBranch("feat/issue-8"), res.Removed)
	}
}

func TestABranchGitCallsUnmergedIsKeptAfterItsWorktreeIsRemoved(t *testing.T) {
	t.Parallel()

	c := newCheckout(t)
	path := c.issueWorktree("feat/issue-7")

	res, err := round.Cleanup(t.Context(), newRecordingGit(), c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}})

	if err != nil {
		t.Fatal(err)
	}
	if exists(path) || !c.hasBranch("feat/issue-7") {
		t.Errorf("worktree exists %v, branch exists %v; want the worktree gone and the unmerged branch kept", exists(path), c.hasBranch("feat/issue-7"))
	}
	if len(res.Removed) != 1 || res.Removed[0].BranchDeleted {
		t.Errorf("removed = %+v, want the worktree removed and the branch not deleted", res.Removed)
	}
	if len(res.Kept) != 1 || res.Kept[0].Branch != "feat/issue-7" || res.Kept[0].Reason == "" {
		t.Errorf("kept = %+v, want the branch with git's refusal", res.Kept)
	}
}

func TestACleanupNeverForcesAnything(t *testing.T) {
	t.Parallel()

	c := newCheckout(t)
	c.issueWorktree("feat/issue-7")
	c.write(c.issueWorktree("feat/issue-8"), "scratch.txt", "not committed")
	c.merged("feat/issue-7")
	g := newRecordingGit()

	if _, err := round.Cleanup(t.Context(), g, c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}, {Issue: 8, Branch: "feat/issue-8"}}); err != nil {
		t.Fatal(err)
	}

	if len(g.writes) == 0 {
		t.Fatal("cleanup changed nothing, so there is nothing to check")
	}
	for _, w := range g.writes {
		for _, forbidden := range []string{"--force", "-f", "-ff", "-D", "--delete", "--prune"} {
			if slices.Contains(w, forbidden) {
				t.Errorf("git %v carries %s", w, forbidden)
			}
		}
	}
}

func TestAWorktreeGitRefusesToRemoveIsReportedAndKept(t *testing.T) {
	t.Parallel()

	c := newCheckout(t)
	path := c.issueWorktree("feat/issue-7")
	c.merged("feat/issue-7")
	git(t, c.shared, "worktree", "lock", path)

	res, err := round.Cleanup(t.Context(), newRecordingGit(), c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}})

	if err != nil {
		t.Fatal(err)
	}
	if !exists(path) || !c.hasBranch("feat/issue-7") {
		t.Error("a locked worktree or its branch was taken away")
	}
	if len(res.Kept) != 1 || res.Kept[0].Worktree != path || len(res.Removed) != 0 {
		t.Errorf("result = %+v, want the worktree kept with git's reason", res)
	}
}

func TestABranchCheckedOutInTheSharedCheckoutIsNeverTouched(t *testing.T) {
	t.Parallel()

	c := newCheckout(t)
	git(t, c.shared, "switch", "-q", "-c", "feat/issue-7")
	before := c.sharedState()

	res, err := round.Cleanup(t.Context(), newRecordingGit(), c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}})

	if err != nil {
		t.Fatal(err)
	}
	if len(res.Kept) != 1 || !strings.Contains(res.Kept[0].Reason, "shared checkout") || len(res.Removed) != 0 {
		t.Errorf("result = %+v, want the branch kept because the shared checkout has it", res)
	}
	if after := c.sharedState(); after != before {
		t.Errorf("the shared checkout changed: %q -> %q", before, after)
	}
}

func TestAnIssueWithNeitherAWorktreeNorABranchLeavesNothingToReport(t *testing.T) {
	t.Parallel()

	c := newCheckout(t)

	res, err := round.Cleanup(t.Context(), newRecordingGit(), c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}})

	if err != nil || res.Removed == nil || res.Kept == nil || len(res.Removed) != 0 || len(res.Kept) != 0 {
		t.Errorf("Cleanup = %+v, %v; want empty non-nil lists", res, err)
	}
}

func prOn(n int, state, branch string) snapshot.PR {
	return snapshot.PR{Number: n, State: state, Branch: branch, HeadSHA: "", CreatedAt: ""}
}

func TestTargetsAreTheMergedBranchesOfDoneIssuesAndNothingElse(t *testing.T) {
	t.Parallel()

	res := result(
		classified(7, board.Done, "seven"), classified(8, board.Done, "eight"), classified(9, board.Parked, "nine"),
		classified(10, board.Verifying, "ten"), classified(11, board.Done, "eleven"),
	)
	prs := []snapshot.PR{
		prOn(31, snapshot.StateMerged, "feat/issue-7"), prOn(32, snapshot.StateMerged, "feat/issue-7-2"),
		prOn(33, snapshot.StateClosed, "feat/issue-8"),
		prOn(34, snapshot.StateMerged, "feat/issue-9"),
		prOn(35, snapshot.StateMerged, "feat/issue-10"),
		prOn(36, snapshot.StateMerged, "someone/else"),
		prOn(37, snapshot.StateMerged, "feat/issue-12"),
		prOn(38, snapshot.StateMerged, "feat/issue-7"),
	}

	got := round.Targets(res, prs)

	want := []round.Target{{Issue: 7, Branch: "feat/issue-7"}, {Issue: 7, Branch: "feat/issue-7-2"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("targets = %+v, want %+v: Issue 8's PR closed unmerged, 9 is parked, 10 is still verifying, 12 is not in the Epic", got, want)
	}
}

func TestAnEditThatAnIndexFlagHidesFromStatusIsNeverRemoved(t *testing.T) {
	t.Parallel()

	for _, flag := range []string{"--assume-unchanged", "--skip-worktree"} {
		c := newCheckout(t)
		path := c.issueWorktree("feat/issue-7")
		c.merged("feat/issue-7")
		tracked := filepath.Join(path, "work-issue-7.txt")
		git(t, path, "update-index", flag, "work-issue-7.txt")
		c.write(path, "work-issue-7.txt", "an edit that status no longer shows")
		if status := git(t, path, "status", "--porcelain", "--untracked-files=all"); status != "" {
			t.Fatalf("%s: status = %q, want the edit hidden, or this proves nothing", flag, status)
		}

		res, err := round.Cleanup(t.Context(), newRecordingGit(), c.shared, []round.Target{{Issue: 7, Branch: "feat/issue-7"}})

		if err != nil {
			t.Fatal(err)
		}
		if !exists(tracked) || !c.hasBranch("feat/issue-7") {
			t.Errorf("%s: the worktree or its branch was taken away with an unsaved edit", flag)
		}
		if len(res.Kept) != 1 || !strings.Contains(res.Kept[0].Reason, "index") || len(res.Removed) != 0 {
			t.Errorf("%s: result = %+v, want the worktree kept because an index flag hides its edits", flag, res)
		}
	}
}
