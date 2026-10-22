package worktree_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/runner"
	"github.com/maro114510/skills/oe/internal/worktree"
)

// repo is a shared checkout on main whose origin is a local bare repository.
type repo struct {
	t      *testing.T
	root   string
	shared string
	origin string
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	ident := []string{"-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir}
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, append(ident, args...))
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("git %v: %v, exit %d\n%s", args, err, res.ExitCode, res.Stderr)
	}
	return strings.TrimSpace(string(res.Stdout))
}

func newRepo(t *testing.T) *repo {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := &repo{t: t, root: root, shared: filepath.Join(root, "r"), origin: filepath.Join(root, "origin.git")}
	git(t, root, "init", "-q", "--bare", "-b", "main", r.origin)
	git(t, root, "init", "-q", "-b", "main", r.shared)
	r.commit(r.shared, "a.txt", "one")
	git(t, r.shared, "remote", "add", "origin", r.origin)
	git(t, r.shared, "push", "-q", "origin", "main")
	git(t, r.shared, "fetch", "-q", "origin")
	return r
}

func (r *repo) commit(dir, file, text string) string {
	r.t.Helper()
	if err := os.WriteFile(filepath.Join(dir, file), []byte(text), 0o600); err != nil {
		r.t.Fatal(err)
	}
	git(r.t, dir, "add", file)
	git(r.t, dir, "commit", "-q", "-m", text)
	return git(r.t, dir, "rev-parse", "HEAD")
}

// sharedState is what the shared checkout must keep: HEAD, branch, and status.
func (r *repo) sharedState() string {
	r.t.Helper()
	return git(r.t, r.shared, "rev-parse", "HEAD") + "|" + git(r.t, r.shared, "branch", "--show-current") + "|" +
		git(r.t, r.shared, "status", "--porcelain", "--untracked-files=all")
}

func client() *gh.Client { return gh.New(runner.Exec{}, false) }

func (r *repo) req(branch string, recorded *string) worktree.Request {
	return worktree.Request{Dir: r.shared, Branch: branch, DefaultBranch: "main", Recorded: recorded}
}

func wantRefused(t *testing.T, err error) {
	t.Helper()
	if exitcode.CodeOf(err) != exitcode.Refused {
		t.Fatalf("code %d (%v), want 8", exitcode.CodeOf(err), err)
	}
}

// TestNewBranchStartsAtThePinnedBaseAndLeavesTheSharedCheckoutAlone: a new branch starts from
// origin/main, never the stale or advanced local main, and the shared checkout keeps its HEAD,
// its branch, and its uncommitted changes.
func TestNewBranchStartsAtThePinnedBaseAndLeavesTheSharedCheckoutAlone(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	base := git(t, r.shared, "rev-parse", "origin/main")
	r.commit(r.shared, "local.txt", "local only")
	if err := os.WriteFile(filepath.Join(r.shared, "dirty.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	before := r.sharedState()
	res, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	if err != nil {
		t.Fatal(err)
	}
	if res.Source != worktree.NewBranch || res.Head != base || res.Base != base {
		t.Errorf("Ensure = %+v, want a new branch at %s", res, base)
	}
	if want := filepath.Join(r.root, "r-wt", "feat", "issue-7"); res.Worktree != want {
		t.Errorf("worktree %s, want %s", res.Worktree, want)
	}
	if got := git(t, res.Worktree, "branch", "--show-current"); got != "feat/issue-7" {
		t.Errorf("worktree branch %q", got)
	}
	if after := r.sharedState(); after != before {
		t.Errorf("shared checkout changed: %q -> %q", before, after)
	}
}

// TestExistingWorktreeIsReused: a second call finds the worktree by its branch.
func TestExistingWorktreeIsReused(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	first, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	if err != nil {
		t.Fatal(err)
	}
	head := r.commit(first.Worktree, "w.txt", "worker")
	second, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", &head))
	if err != nil {
		t.Fatal(err)
	}
	if second.Source != worktree.Reused || second.Worktree != first.Worktree || second.Head != head {
		t.Errorf("second Ensure = %+v, want the first worktree reused at %s", second, head)
	}
}

// TestRemoteOnlyBranchIsRecovered: a branch only on origin gets a worktree at origin's commit,
// and the shared checkout's HEAD and working tree are unchanged.
func TestRemoteOnlyBranchIsRecovered(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	other := filepath.Join(r.root, "other")
	git(t, r.root, "clone", "-q", r.origin, other)
	git(t, other, "switch", "-q", "-c", "feat/issue-7")
	pushed := r.commit(other, "b.txt", "from elsewhere")
	git(t, other, "push", "-q", "origin", "feat/issue-7")
	if err := os.WriteFile(filepath.Join(r.shared, "dirty.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	before := r.sharedState()
	res, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", &pushed))
	if err != nil {
		t.Fatal(err)
	}
	if res.Source != worktree.RemoteBranch || res.Head != pushed {
		t.Errorf("Ensure = %+v, want origin's branch at %s", res, pushed)
	}
	if after := r.sharedState(); after != before {
		t.Errorf("shared checkout changed: %q -> %q", before, after)
	}
}

// TestLocalBranchGetsAWorktree: a local branch without a worktree is checked out in a new one.
func TestLocalBranchGetsAWorktree(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	git(t, r.shared, "branch", "feat/issue-7", "origin/main")
	tip := git(t, r.shared, "rev-parse", "feat/issue-7")
	res, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", &tip))
	if err != nil {
		t.Fatal(err)
	}
	if res.Source != worktree.LocalBranch || res.Head != tip {
		t.Errorf("Ensure = %+v", res)
	}
}

// TestRedoBranchIsHonored: the branch an applied epic-redo recorded is the one created, and the
// old branch's worktree is left alone.
func TestRedoBranchIsHonored(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	old, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	if err != nil {
		t.Fatal(err)
	}
	r.commit(old.Worktree, "w.txt", "abandoned")
	res, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7-2", nil))
	if err != nil {
		t.Fatal(err)
	}
	if res.Source != worktree.NewBranch || res.Worktree == old.Worktree || git(t, res.Worktree, "branch", "--show-current") != "feat/issue-7-2" {
		t.Errorf("Ensure = %+v, want feat/issue-7-2 in its own worktree", res)
	}
}

// TestDivergedHeadStops: a worktree, local branch, or origin branch at a head other than the
// recorded one stops with exit 8 and adds nothing.
func TestDivergedHeadStops(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	stranger := strings.Repeat("a", 40)
	if _, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil)); err != nil {
		t.Fatal(err)
	}
	_, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", &stranger))
	wantRefused(t, err)

	git(t, r.shared, "branch", "feat/issue-8", "origin/main")
	_, err = worktree.Ensure(t.Context(), client(), r.req("feat/issue-8", &stranger))
	wantRefused(t, err)

	_, err = worktree.Ensure(t.Context(), client(), r.req("feat/issue-9", &stranger))
	wantRefused(t, err)
	if list := git(t, r.shared, "worktree", "list"); strings.Count(list, "\n") != 1 {
		t.Errorf("worktrees after refusals:\n%s", list)
	}
}

// TestSharedCheckoutBranchAndBadNamesAreRefused: oe never works in the shared checkout, and only
// a loop branch name is accepted.
func TestSharedCheckoutBranchAndBadNamesAreRefused(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	git(t, r.shared, "switch", "-q", "-c", "feat/issue-7")
	_, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	wantRefused(t, err)
	for _, b := range []string{"main", "feat/issue-x", "feat/issue-7/../../x", "feat/issue-7-../../x", "feat/issue-7 x", "feat/issue-7-a..b", "feat/issue-7-x.lock"} {
		_, err := worktree.Ensure(t.Context(), client(), r.req(b, nil))
		wantRefused(t, err)
	}
}

// TestMissingBaseIsRefused: without origin/main, nothing is created from a guess.
func TestMissingBaseIsRefused(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	git(t, r.shared, "update-ref", "-d", "refs/remotes/origin/main")
	_, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	wantRefused(t, err)
}

// TestVerifyAcceptsOnlyAWorkerWorktreeOnItsBranch.
func TestVerifyAcceptsOnlyAWorkerWorktreeOnItsBranch(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	res, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	if err != nil {
		t.Fatal(err)
	}
	if e, err := worktree.Verify(t.Context(), client(), r.shared, res.Worktree, "feat/issue-7"); err != nil || e.Head != res.Head {
		t.Errorf("Verify = %+v, %v", e, err)
	}
	for name, c := range map[string][2]string{
		"shared checkout": {r.shared, "main"},
		"other branch":    {res.Worktree, "feat/issue-8"},
		"relative":        {"r-wt/feat/issue-7", "feat/issue-7"},
		"missing":         {filepath.Join(r.root, "nope"), "feat/issue-7"},
		"foreign":         {r.root, "feat/issue-7"},
		"subdirectory":    {filepath.Join(r.root, "r-wt", "feat"), "feat/issue-7"},
	} {
		if _, err := worktree.Verify(t.Context(), client(), r.shared, c[0], c[1]); exitcode.CodeOf(err) != exitcode.Refused {
			t.Errorf("%s: Verify = %v, want exit 8", name, err)
		}
	}
	git(t, res.Worktree, "switch", "-q", "--detach")
	_, err = worktree.Verify(t.Context(), client(), r.shared, res.Worktree, "feat/issue-7")
	wantRefused(t, err)
}

// TestDirtyReportsUncommittedWork.
func TestDirtyReportsUncommittedWork(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	res, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	if err != nil {
		t.Fatal(err)
	}
	if d, err := worktree.Dirty(t.Context(), client(), res.Worktree); err != nil || d {
		t.Errorf("clean worktree: Dirty = %v, %v", d, err)
	}
	if err := os.WriteFile(filepath.Join(res.Worktree, "new.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if d, err := worktree.Dirty(t.Context(), client(), res.Worktree); err != nil || !d {
		t.Errorf("untracked file: Dirty = %v, %v", d, err)
	}
}

// recorder records every git call a worktree operation makes.
type recorder struct {
	*gh.Client

	calls []string
}

func (r *recorder) Git(ctx context.Context, args ...string) ([]byte, error) {
	r.calls = append(r.calls, strings.Join(args, " "))
	return r.Client.Git(ctx, args...)
}

func (r *recorder) GitWrite(ctx context.Context, args ...string) ([]byte, error) {
	r.calls = append(r.calls, strings.Join(args, " "))
	return r.Client.GitWrite(ctx, args...)
}

// TestEnsureNeverFetchesTheBase: only the Publisher fetches the default branch, once per round;
// a new worktree reads the fetched commit and fetches nothing.
func TestEnsureNeverFetchesTheBase(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	rec := &recorder{Client: client(), calls: nil}
	if _, err := worktree.Ensure(t.Context(), rec, r.req("feat/issue-7", nil)); err != nil {
		t.Fatal(err)
	}
	for _, c := range rec.calls {
		if strings.Contains(c, " fetch ") || strings.Contains(c, " pull") || strings.Contains(c, " switch") || strings.Contains(c, " checkout") {
			t.Errorf("Ensure ran %q", c)
		}
	}
}

// TestLinkedSharedCheckoutIsNeverHandedOut: when the shared checkout is itself a linked
// worktree, the loop's own checkout is never reused or verified as a worker's.
func TestLinkedSharedCheckoutIsNeverHandedOut(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	linked := filepath.Join(r.root, "linked")
	git(t, r.shared, "worktree", "add", "-q", "-b", "feat/issue-7", linked, "origin/main")
	req := r.req("feat/issue-7", nil)
	req.Dir = linked
	_, err := worktree.Ensure(t.Context(), client(), req)
	wantRefused(t, err)
	_, err = worktree.Verify(t.Context(), client(), linked, linked, "feat/issue-7")
	wantRefused(t, err)
}

// TestHandMadeBranchNamesTheBoardAcceptsAreHandedOff: a branch the board classifies as the
// Issue's work, such as feat/issue-7-fix.v2, gets its worktree like any loop branch.
func TestHandMadeBranchNamesTheBoardAcceptsAreHandedOff(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	res, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7-fix.v2", nil))
	if err != nil {
		t.Fatal(err)
	}
	again, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7-fix.v2", &res.Head))
	if err != nil || again.Source != worktree.Reused {
		t.Errorf("second Ensure = %+v, %v; want it reused", again, err)
	}
}

// TestBaseIsMatchedExactly: with origin/main missing and origin/main/legacy present, nothing is
// created from the unrelated ref.
func TestBaseIsMatchedExactly(t *testing.T) {
	t.Parallel()

	r := newRepo(t)
	other := r.commit(r.shared, "o.txt", "unrelated")
	git(t, r.shared, "update-ref", "-d", "refs/remotes/origin/main")
	git(t, r.shared, "update-ref", "refs/remotes/origin/main/legacy", other)
	_, err := worktree.Ensure(t.Context(), client(), r.req("feat/issue-7", nil))
	wantRefused(t, err)
}
