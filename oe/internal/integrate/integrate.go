// Package integrate merges the pinned default-branch commit into a worker's branch.
//
// oe makes this merge so that the model never commits.
//   - It is always a plain merge commit and never a rebase.
//   - Hooks, signing, the editor, rerere, and autostash are disabled.
//   - A conflict is aborted and left to a worker.
//   - The next run recovers an interrupted merge.
package integrate

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// Git runs git through a client whose Git method reads and whose GitWrite method changes local state.
type Git interface {
	Git(ctx context.Context, args ...string) ([]byte, error)
	GitWrite(ctx context.Context, args ...string) ([]byte, error)
}

// The ways Integrate recovered an interrupted merge.
const (
	// RecoveredNone is a worktree with nothing to recover.
	RecoveredNone = ""
	// RecoveredAborted is a leftover MERGE_HEAD, aborted before the merge is redone.
	RecoveredAborted = "aborted"
	// RecoveredAdopted is a merge commit oe made whose head was never recorded.
	RecoveredAdopted = "adopted"
)

// Request names the worktree and branch, the head the state records, and the default-branch commit read once for this pass.
type Request struct {
	Worktree string
	Branch   string
	Recorded string
	Base     string
}

// Result is the worktree after the integration.
// When Dirty or Conflicts is set, nothing was merged and the worktree is unchanged.
type Result struct {
	Head      string   `json:"head"`
	Base      string   `json:"base"`
	Merged    bool     `json:"merged"`
	Recovered string   `json:"recovered"`
	Dirty     []string `json:"dirty"`
	Conflicts []string `json:"conflicts"`
}

// Integrate brings Base into the branch.
//   - It first recovers an interrupted merge.
//   - It refuses a head other than the recorded one.
//   - It leaves a dirty worktree untouched.
//   - It merges only when Base is not yet an ancestor of the head.
func Integrate(ctx context.Context, g Git, req Request) (Result, error) {
	res := Result{Head: "", Base: req.Base, Merged: false, Recovered: RecoveredNone, Dirty: []string{}, Conflicts: []string{}}
	if err := onBranch(ctx, g, req); err != nil {
		return res, err
	}
	var err error
	if res.Head, res.Recovered, err = recoverHead(ctx, g, req); err != nil {
		return res, err
	}
	if res.Dirty, err = DirtyPaths(ctx, g, req.Worktree); err != nil || len(res.Dirty) > 0 {
		return res, err
	}
	integrated, err := Ancestor(ctx, g, req.Worktree, req.Base, res.Head)
	if err != nil || integrated {
		return res, err
	}
	return merge(ctx, g, req, res)
}

// onBranch refuses a worktree that does not have the branch checked out, so the merge never advances another ref.
// A branch name holding = is refused too, since -c would split the mergeOptions key at it.
func onBranch(ctx context.Context, g Git, req Request) error {
	if req.Worktree == "" || req.Branch == "" || req.Recorded == "" || req.Base == "" {
		return exitcode.New(exitcode.Refused, "an integration needs the worktree, branch, recorded head, and base")
	}
	if strings.Contains(req.Branch, "=") {
		return exitcode.New(exitcode.Refused, "branch "+req.Branch+" holds =, which git -c cannot name")
	}
	out, err := g.Git(ctx, "-C", req.Worktree, "rev-parse", "--symbolic-full-name", "HEAD")
	if err != nil {
		return err
	}
	if got := strings.TrimSpace(string(out)); got != "refs/heads/"+req.Branch {
		return exitcode.New(exitcode.Refused, fmt.Sprintf("the worktree %s has %q checked out, not %s", req.Worktree, got, req.Branch))
	}
	return nil
}

// recoverHead aborts a merge in progress and adopts a merge commit that oe made but never recorded.
// It returns the head to integrate onto.
func recoverHead(ctx context.Context, g Git, req Request) (string, string, error) {
	recovered := RecoveredNone
	aborted, err := abortLeftover(ctx, g, req.Worktree)
	if err != nil {
		return "", recovered, err
	}
	if aborted {
		recovered = RecoveredAborted
	}
	head, err := Rev(ctx, g, req.Worktree, "HEAD")
	if err != nil || head == req.Recorded {
		return head, recovered, err
	}
	if err := adoptable(ctx, g, req, head); err != nil {
		return "", recovered, err
	}
	return head, RecoveredAdopted, nil
}

// Message is the subject of the merge commit oe makes.
func Message(base, branch string) string { return "Merge " + base + " into " + branch }

// noHooks disables everything that could run code or wait for a person during a merge.
func noHooks(dir string, args ...string) []string {
	return append([]string{
		"-c", "core.hooksPath=" + os.DevNull, "-c", "commit.gpgSign=false", "-c", "core.editor=true",
		"-c", "rerere.enabled=false", "-c", "merge.autoStash=false", "-C", dir,
	}, args...)
}

func merge(ctx context.Context, g Git, req Request, res Result) (Result, error) {
	// The branch's own merge options are blanked, since a configured --no-commit, -s ours, or -X ours could skip the commit, drop the base, or resolve a conflict silently.
	args := append([]string{"-c", "branch." + req.Branch + ".mergeOptions=", "-c", "pull.twohead=ort"},
		noHooks(req.Worktree, "merge", "--strategy=ort", "--no-ff", "--commit", "--no-squash", "--no-edit", "--no-verify", "--no-gpg-sign",
			"--no-verify-signatures", "--no-rerere-autoupdate", "--no-autostash", "-m", Message(req.Base, req.Branch), req.Base)...)
	_, mergeErr := g.GitWrite(ctx, args...)
	if mergeErr == nil {
		return made(ctx, g, req, res)
	}
	conflicts, err := unmerged(ctx, g, req.Worktree)
	if err != nil {
		return res, err
	}
	if err := restore(ctx, g, req.Worktree, res.Head); err != nil {
		return res, err
	}
	if len(conflicts) == 0 {
		return res, exitcode.Wrap(exitcode.Unreadable, mergeErr, "the integration merge failed without a conflict; the worktree was restored")
	}
	res.Conflicts = conflicts
	return res, nil
}

// made checks that the merge left exactly oe's merge commit, the old head then the base as parents, and nothing in progress.
// A merge that exited 0 without that commit is restored and exits 1, so it is never reported as merged.
func made(ctx context.Context, g Git, req Request, res Result) (Result, error) {
	out, err := g.Git(ctx, "-C", req.Worktree, "log", "-1", "--format=%H %P")
	if err != nil {
		return res, err
	}
	fields := strings.Fields(string(out))
	if len(fields) == 3 && fields[1] == res.Head && fields[2] == req.Base {
		if aborted, err := abortLeftover(ctx, g, req.Worktree); err != nil || aborted {
			return res, errors.Join(err, exitcode.New(exitcode.Unreadable, "a merge was still in progress after oe's merge commit"))
		}
		res.Head, res.Merged = fields[0], true
		return res, nil
	}
	if err := restore(ctx, g, req.Worktree, res.Head); err != nil {
		return res, err
	}
	return res, exitcode.New(exitcode.Unreadable, "git merge exited 0 without making oe's merge commit; the worktree was restored")
}

// restore aborts a merge left in progress and checks the worktree is exactly as it was.
func restore(ctx context.Context, g Git, wt, head string) error {
	if _, err := abortLeftover(ctx, g, wt); err != nil {
		return err
	}
	now, err := Rev(ctx, g, wt, "HEAD")
	if err != nil {
		return err
	}
	dirty, err := DirtyPaths(ctx, g, wt)
	if err != nil {
		return err
	}
	if now != head || len(dirty) > 0 {
		return exitcode.New(exitcode.Unreadable, fmt.Sprintf("the worktree %s was not restored to %s after a failed merge; a person must restore it", wt, head))
	}
	return nil
}

// abortLeftover aborts a merge in progress, reporting whether there was one.
func abortLeftover(ctx context.Context, g Git, wt string) (bool, error) {
	out, err := g.Git(ctx, "-C", wt, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return false, err
	}
	_, err = os.Stat(filepath.Join(strings.TrimSpace(string(out)), "MERGE_HEAD"))
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return false, nil
	case err != nil:
		return false, exitcode.Wrap(exitcode.Unreadable, err, "cannot tell whether a merge is in progress in "+wt)
	}
	if _, err := g.GitWrite(ctx, noHooks(wt, "merge", "--abort")...); err != nil {
		return true, err
	}
	return true, nil
}

// adoptable accepts only an unrecorded merge commit that oe made on top of the recorded head.
//   - It has two parents.
//   - The first parent is the recorded head.
//   - The base contains the second parent.
//   - The subject is the one oe writes.
//
// Any other head is a divergence for a person, since the worktree is never the source of truth.
func adoptable(ctx context.Context, g Git, req Request, head string) error {
	out, err := g.Git(ctx, "-C", req.Worktree, "log", "-1", "--format=%P%n%s", head)
	if err != nil {
		return err
	}
	parentsLine, subject, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	parents := strings.Fields(parentsLine)
	diverged := exitcode.New(exitcode.Refused, fmt.Sprintf("the worktree's HEAD %s diverged from the recorded head %s; a person must decide which is right",
		head, req.Recorded))
	if len(parents) != 2 || parents[0] != req.Recorded || subject != Message(parents[1], req.Branch) {
		return diverged
	}
	inBase, err := Ancestor(ctx, g, req.Worktree, parents[1], req.Base)
	if err != nil {
		return err
	}
	if !inBase {
		return diverged
	}
	return nil
}

// Rev reads the commit a revision names in a worktree.
func Rev(ctx context.Context, g Git, wt, rev string) (string, error) {
	out, err := g.Git(ctx, "-C", wt, "rev-parse", "--verify", rev+"^{commit}")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// Ancestor reports whether a is b or an ancestor of b.
// It counts the commits that b lacks, because the exit 1 of merge-base --is-ancestor would read as a failed read.
func Ancestor(ctx context.Context, g Git, wt, a, b string) (bool, error) {
	out, err := g.Git(ctx, "-C", wt, "rev-list", "--count", b+".."+a)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) == "0", nil
}

// DirtyPaths lists every path changed in the index or the worktree, including untracked files that are not ignored.
func DirtyPaths(ctx context.Context, g Git, wt string) ([]string, error) {
	out, err := g.Git(ctx, "-C", wt, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	paths := []string{}
	entries := strings.Split(strings.TrimRight(string(out), "\x00"), "\x00")
	for i := 0; i < len(entries); i++ {
		e := entries[i]
		if len(e) < len("XY p") {
			continue
		}
		paths = append(paths, e[3:])
		// A rename or copy is followed by its source path.
		if e[0] == 'R' || e[0] == 'C' {
			i++
		}
	}
	slices.Sort(paths)
	return paths, nil
}

func unmerged(ctx context.Context, g Git, wt string) ([]string, error) {
	out, err := g.Git(ctx, "-C", wt, "diff", "--name-only", "--diff-filter=U", "-z")
	if err != nil {
		return nil, err
	}
	var paths []string
	for p := range strings.SplitSeq(strings.TrimRight(string(out), "\x00"), "\x00") {
		if p != "" {
			paths = append(paths, p)
		}
	}
	return paths, nil
}
