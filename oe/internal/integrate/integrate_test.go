package integrate_test

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/integrate"
	"github.com/maro114510/skills/oe/internal/runner"
)

const branch = "feat/issue-7"

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, append([]string{"-C", dir}, args...))
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("git %v: %v, exit %d\n%s", args, err, res.ExitCode, res.Stderr)
	}
	return strings.TrimSpace(string(res.Stdout))
}

func write(t *testing.T, dir, file, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, file), []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func commit(t *testing.T, dir, file, text string) string {
	t.Helper()
	write(t, dir, file, text)
	git(t, dir, "add", file)
	git(t, dir, "-c", "core.hooksPath="+os.DevNull, "-c", "commit.gpgSign=false", "commit", "-q", "-m", file+" "+text)
	return git(t, dir, "rev-parse", "HEAD")
}

// repo is a repository whose main advanced past the commit the worker's branch started from.
// It is hostile to an unattended merge, since every hook fails, commits must be signed by a failing program, and rerere is on.
type repo struct {
	main, wt string
	base     string
	recorded string
	hookRan  string
}

func newRepo(t *testing.T, worker, upstream [2]string) repo {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := repo{main: filepath.Join(root, "r"), wt: filepath.Join(root, "r-wt", branch), base: "", recorded: "", hookRan: filepath.Join(root, "hook-ran")}
	git(t, root, "init", "-q", "-b", "main", r.main)
	for k, v := range map[string]string{"user.name": "t", "user.email": "t@example.com"} {
		git(t, r.main, "config", k, v)
	}
	start := commit(t, r.main, "a.txt", "one\n")
	git(t, r.main, "worktree", "add", "-q", "-b", branch, r.wt, start)
	r.recorded = commit(t, r.wt, worker[0], worker[1])
	r.base = commit(t, r.main, upstream[0], upstream[1])
	hooks := filepath.Join(root, "hooks")
	if err := os.MkdirAll(hooks, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{"pre-merge-commit", "commit-msg", "prepare-commit-msg", "post-merge", "pre-commit"} {
		script := "#!/bin/sh\ntouch " + r.hookRan + "\nexit 1\n"
		if err := os.WriteFile(filepath.Join(hooks, h), []byte(script), 0o700); err != nil { //nolint:gosec // A hook must be executable.
			t.Fatal(err)
		}
	}
	for k, v := range map[string]string{
		"core.hooksPath": hooks, "commit.gpgSign": "true", "gpg.program": "false", "rerere.enabled": "true",
		"rerere.autoUpdate": "true", "core.editor": "false", "merge.autoStash": "true",
	} {
		git(t, r.main, "config", k, v)
	}
	return r
}

func client() *gh.Client { return gh.New(runner.Exec{}, false) }

func (r repo) req() integrate.Request {
	return integrate.Request{Worktree: r.wt, Branch: branch, Recorded: r.recorded, Base: r.base}
}

// TestIntegrationIsAPlainMergeCommitWithoutHooksOrSigning shows that oe makes a two-parent merge commit on top of the recorded head and never rebases, so the branch only moves forward.
// No hook runs and no signature is asked for, even in a repository that demands both.
func TestIntegrationIsAPlainMergeCommitWithoutHooksOrSigning(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
	res, err := integrate.Integrate(t.Context(), client(), r.req())
	if err != nil {
		t.Fatalf("integrate: %v", err)
	}
	if !res.Merged || res.Recovered != integrate.RecoveredNone || len(res.Conflicts) != 0 || len(res.Dirty) != 0 {
		t.Fatalf("result = %+v", res)
	}
	wantMergedOnTop(t, r, res)
	again, err := integrate.Integrate(t.Context(), client(), integrate.Request{Worktree: r.wt, Branch: branch, Recorded: res.Head, Base: r.base})
	if err != nil || again.Merged || again.Head != res.Head {
		t.Errorf("an integrated base merged again: %+v, %v", again, err)
	}
}

// wantMergedOnTop checks the merge commit, its parents, its subject, that no hook ran, and that the worktree is clean.
func wantMergedOnTop(t *testing.T, r repo, res integrate.Result) {
	t.Helper()
	checks := map[string][2]string{
		"HEAD":    {git(t, r.wt, "rev-parse", "HEAD"), res.Head},
		"parents": {git(t, r.wt, "log", "-1", "--format=%P", res.Head), r.recorded + " " + r.base},
		"subject": {git(t, r.wt, "log", "-1", "--format=%s", res.Head), integrate.Message(r.base, branch)},
		"status":  {git(t, r.wt, "status", "--porcelain"), ""},
	}
	for name, gw := range checks {
		if gw[0] != gw[1] {
			t.Errorf("%s = %q, want %q", name, gw[0], gw[1])
		}
	}
	if _, err := os.Stat(r.hookRan); err == nil {
		t.Error("a hook ran")
	}
}

// TestConflictAbortsAndRestoresTheWorktree shows that a conflict merges nothing and names the conflicting paths.
// HEAD stays at the recorded head with a clean tree and no merge in progress.
func TestConflictAbortsAndRestoresTheWorktree(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"a.txt", "worker\n"}, [2]string{"a.txt", "upstream\n"})
	res, err := integrate.Integrate(t.Context(), client(), r.req())
	if err != nil {
		t.Fatalf("integrate: %v", err)
	}
	if res.Merged || !slices.Equal(res.Conflicts, []string{"a.txt"}) || res.Head != r.recorded {
		t.Fatalf("result = %+v", res)
	}
	if got := git(t, r.wt, "rev-parse", "HEAD"); got != r.recorded {
		t.Errorf("HEAD %s, want %s", got, r.recorded)
	}
	if status := git(t, r.wt, "status", "--porcelain"); status != "" {
		t.Errorf("worktree not restored: %q", status)
	}
	if _, err := os.Stat(filepath.Join(git(t, r.wt, "rev-parse", "--absolute-git-dir"), "MERGE_HEAD")); err == nil {
		t.Error("a merge is still in progress")
	}
}

// TestInterruptedMergeIsRecovered shows that a merge left in progress is aborted and redone.
// A merge commit that oe made but never recorded is adopted and never made twice.
func TestInterruptedMergeIsRecovered(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
	git(t, r.wt, "-c", "core.hooksPath="+os.DevNull, "merge", "--no-ff", "--no-commit", "--no-autostash", r.base)
	res, err := integrate.Integrate(t.Context(), client(), r.req())
	if err != nil || !res.Merged || res.Recovered != integrate.RecoveredAborted {
		t.Fatalf("leftover MERGE_HEAD: %+v, %v", res, err)
	}

	r2 := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
	git(t, r2.wt, "-c", "core.hooksPath="+os.DevNull, "-c", "commit.gpgSign=false", "merge", "--no-ff", "--no-autostash",
		"-m", integrate.Message(r2.base, branch), r2.base)
	made := git(t, r2.wt, "rev-parse", "HEAD")
	res, err = integrate.Integrate(t.Context(), client(), r2.req())
	if err != nil || res.Merged || res.Recovered != integrate.RecoveredAdopted || res.Head != made {
		t.Fatalf("unrecorded merge: %+v, %v", res, err)
	}
}

// TestForeignHeadIsRefused shows that any other head than the recorded one or oe's merge on top of it is a divergence for a person, and nothing is merged.
func TestForeignHeadIsRefused(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
	foreign := commit(t, r.wt, "x.txt", "someone\n")
	_, err := integrate.Integrate(t.Context(), client(), r.req())
	if exitcode.CodeOf(err) != exitcode.Refused || git(t, r.wt, "rev-parse", "HEAD") != foreign {
		t.Errorf("err %v", err)
	}
}

// TestDirtyWorktreeIsNeverMerged shows that an untracked file or a staged change stops the merge and is reported, so review never runs over uncommitted content.
func TestDirtyWorktreeIsNeverMerged(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
	write(t, r.wt, "new.txt", "untracked\n")
	write(t, r.wt, "w.txt", "edited\n")
	git(t, r.wt, "add", "w.txt")
	res, err := integrate.Integrate(t.Context(), client(), r.req())
	if err != nil || res.Merged || !slices.Equal(res.Dirty, []string{"new.txt", "w.txt"}) {
		t.Errorf("result %+v, %v", res, err)
	}
	if got := git(t, r.wt, "rev-parse", "HEAD"); got != r.recorded {
		t.Errorf("HEAD moved to %s", got)
	}
}

// TestBranchMergeOptionsCannotSkipTheCommit shows that a branch configured to merge with --no-commit still gets oe's merge commit and never reports a merge that did not happen.
func TestBranchMergeOptionsCannotSkipTheCommit(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
	git(t, r.main, "config", "branch."+branch+".mergeOptions", "--no-commit")
	res, err := integrate.Integrate(t.Context(), client(), r.req())
	if err != nil || !res.Merged {
		t.Fatalf("result %+v, %v", res, err)
	}
	wantMergedOnTop(t, r, res)
}

// TestBranchMergeStrategyCannotDropTheBase shows that a branch configured to keep its own side still gets the base's content merged in.
func TestBranchMergeStrategyCannotDropTheBase(t *testing.T) {
	t.Parallel()

	for _, opts := range []string{"-s ours", "-X ours"} {
		r := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
		git(t, r.main, "config", "branch."+branch+".mergeOptions", opts)
		res, err := integrate.Integrate(t.Context(), client(), r.req())
		if err != nil || !res.Merged {
			t.Fatalf("%s: result %+v, %v", opts, res, err)
		}
		if got := git(t, r.wt, "show", res.Head+":b.txt"); got != "upstream" {
			t.Errorf("%s: b.txt = %q; the base's content was dropped", opts, got)
		}
	}
}

// TestBranchStrategyOptionCannotResolveAConflict shows that a configured -X ours never resolves a conflict silently; the conflict still goes to a worker.
func TestBranchStrategyOptionCannotResolveAConflict(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"a.txt", "worker\n"}, [2]string{"a.txt", "upstream\n"})
	git(t, r.main, "config", "branch."+branch+".mergeOptions", "-X ours")
	res, err := integrate.Integrate(t.Context(), client(), r.req())
	if err != nil || res.Merged || !slices.Equal(res.Conflicts, []string{"a.txt"}) {
		t.Errorf("result %+v, %v", res, err)
	}
}

// TestIntegrationNeedsTheBranchCheckedOut shows that a worktree on another branch or a detached HEAD at the recorded commit is refused, so no other ref is ever advanced.
func TestIntegrationNeedsTheBranchCheckedOut(t *testing.T) {
	t.Parallel()

	r := newRepo(t, [2]string{"w.txt", "worker\n"}, [2]string{"b.txt", "upstream\n"})
	git(t, r.wt, "switch", "-q", "--detach")
	_, err := integrate.Integrate(t.Context(), client(), r.req())
	if exitcode.CodeOf(err) != exitcode.Refused || git(t, r.wt, "rev-parse", "HEAD") != r.recorded {
		t.Errorf("detached: %v", err)
	}
	git(t, r.wt, "switch", "-q", "-c", "other")
	_, err = integrate.Integrate(t.Context(), client(), r.req())
	if exitcode.CodeOf(err) != exitcode.Refused || git(t, r.wt, "rev-parse", "HEAD") != r.recorded {
		t.Errorf("other branch: %v", err)
	}
	req := r.req()
	req.Branch = "feat/issue-7-x.foo=bar"
	if _, err := integrate.Integrate(t.Context(), client(), req); exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("a branch with = : %v", err)
	}
}
