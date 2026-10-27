package round

import (
	"bytes"
	"cmp"
	"context"
	"slices"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/worktree"
)

// Target is a branch of an Issue that is closed with a merged pull request.
type Target struct {
	Issue  int    `json:"issue"`
	Branch string `json:"branch"`
}

// Removed is a worktree or branch cleanup took away.
type Removed struct {
	Issue         int    `json:"issue"`
	Branch        string `json:"branch"`
	Worktree      string `json:"worktree,omitempty"`
	BranchDeleted bool   `json:"branch_deleted"`
}

// Kept is a worktree or branch cleanup left in place, and why.
type Kept struct {
	Issue    int    `json:"issue"`
	Branch   string `json:"branch"`
	Worktree string `json:"worktree,omitempty"`
	Reason   string `json:"reason"`
}

// CleanupResult is what cleanup did.
type CleanupResult struct {
	Removed []Removed `json:"removed"`
	Kept    []Kept    `json:"kept"`
}

// Targets are the branches of the Issues that are done and whose pull request merged: every
// merged pull request on a loop branch of such an Issue, listed once, in Issue order.
func Targets(res board.Result, prs []snapshot.PR) []Target {
	done := map[int]bool{}
	for _, i := range res.Issues {
		if i.State == board.Done {
			done[i.Number] = true
		}
	}
	out := []Target{}
	for _, pr := range prs {
		n, ok := snapshot.IssueOfBranch(pr.Branch)
		t := Target{Issue: n, Branch: pr.Branch}
		if pr.State == snapshot.StateMerged && ok && done[n] && !slices.Contains(out, t) {
			out = append(out, t)
		}
	}
	slices.SortFunc(out, func(a, b Target) int {
		return cmp.Or(cmp.Compare(a.Issue, b.Issue), cmp.Compare(a.Branch, b.Branch))
	})
	return out
}

// Cleanup removes the worktree of each target and deletes its local branch. A worktree git
// refuses to remove, such as one with uncommitted changes, is reported and kept, and so is a
// branch `git branch -d` refuses as unmerged. Nothing is forced, and the shared checkout is
// never touched.
func Cleanup(ctx context.Context, g worktree.Git, dir string, targets []Target) (CleanupResult, error) {
	res := CleanupResult{Removed: []Removed{}, Kept: []Kept{}}
	for _, t := range targets {
		// A worktree removed for an earlier target changes the list.
		entries, err := worktree.List(ctx, g, dir)
		if err != nil {
			return res, err
		}
		cleanOne(ctx, g, dir, entries, t, &res)
	}
	return res, nil
}

// cleanOne removes one target's worktree, then its branch, reporting whatever it leaves.
func cleanOne(ctx context.Context, g worktree.Git, dir string, entries []worktree.Entry, t Target, res *CleanupResult) {
	keep := func(path, reason string) {
		res.Kept = append(res.Kept, Kept{Issue: t.Issue, Branch: t.Branch, Worktree: path, Reason: reason})
	}
	path := ""
	if i := slices.IndexFunc(entries, func(e worktree.Entry) bool { return !e.Detached && e.Branch == "refs/heads/"+t.Branch }); i == 0 {
		keep(entries[0].Path, "the branch is checked out in the shared checkout, which cleanup never touches")
		return
	} else if i > 0 {
		path = entries[i].Path
		if why := removeWorktree(ctx, g, dir, path); why != "" {
			keep(path, why)
			return
		}
	}
	removed := Removed{Issue: t.Issue, Branch: t.Branch, Worktree: path, BranchDeleted: false}
	record := func() {
		if path != "" || removed.BranchDeleted {
			res.Removed = append(res.Removed, removed)
		}
	}
	defer record()
	out, err := g.Git(ctx, "-C", dir, "for-each-ref", "--format=%(refname)", "refs/heads/"+t.Branch)
	if err != nil {
		keep("", "the local branch could not be read: "+oneLine(err.Error()))
		return
	}
	if len(bytes.TrimSpace(out)) == 0 {
		return
	}
	// -d refuses an unmerged branch, which is the point: it is never forced.
	if _, err := g.GitWrite(ctx, "-C", dir, "branch", "-d", t.Branch); err != nil {
		keep("", "git branch -d refused: "+oneLine(err.Error()))
		return
	}
	removed.BranchDeleted = true
}

// removeWorktree removes a clean worktree and returns why it did not, or "" when it did.
func removeWorktree(ctx context.Context, g worktree.Git, dir, path string) string {
	dirty, err := worktree.Dirty(ctx, g, path)
	if err != nil {
		return "the worktree could not be read: " + oneLine(err.Error())
	}
	if dirty {
		return "the worktree has uncommitted changes or untracked files, so it is kept"
	}
	if _, err := g.GitWrite(ctx, "-C", dir, "worktree", "remove", path); err != nil {
		return "git worktree remove refused: " + oneLine(err.Error())
	}
	return ""
}

// oneLine bounds a message from git to one line.
func oneLine(s string) string { return clip(s) }
