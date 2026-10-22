// Package worktree gives each worker its worktree, contract §16. A worktree is added with plain
// `git worktree add`, a new branch starts from the pinned default-branch commit, and the shared
// checkout oe runs from is never switched, pulled, or written: only `.git` gains the worktree,
// the branch, and, for a branch only on origin, its remote-tracking ref.
package worktree

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

// Git runs git. *gh.Client satisfies it: Git reads, GitWrite changes local state.
type Git interface {
	Git(ctx context.Context, args ...string) ([]byte, error)
	GitWrite(ctx context.Context, args ...string) ([]byte, error)
}

// Source says how Ensure came by a worktree.
type Source string

// The sources of a worktree.
const (
	// Reused is a worktree that already had the branch checked out.
	Reused Source = "reused"
	// LocalBranch is a new worktree for a branch that existed locally.
	LocalBranch Source = "local-branch"
	// RemoteBranch is a new worktree for a branch that existed only on origin.
	RemoteBranch Source = "remote-branch"
	// NewBranch is a new branch started from the pinned default-branch commit.
	NewBranch Source = "new-branch"
)

// Entry is one registered worktree.
type Entry struct {
	Path     string
	Head     string
	Branch   string
	Detached bool
	Bare     bool
	Prunable bool
}

// Request is what Ensure needs: the shared checkout, the branch the Issue state records, the
// default branch, and the head the state records, nil when none.
type Request struct {
	Dir           string
	Branch        string
	DefaultBranch string
	Recorded      *string
}

// Result is the worktree a worker gets.
type Result struct {
	Branch   string `json:"branch"`
	Worktree string `json:"worktree"`
	Head     string `json:"head"`
	// Base is the default-branch commit a new branch started from; empty for any other source.
	Base   string `json:"base"`
	Source Source `json:"source"`
}

// branchRe is every branch the loop records: feat/issue-<n>, its redo branches, and the slugged
// form a person may have started by hand.
var branchRe = regexp.MustCompile(`^` + regexp.QuoteMeta(snapshot.BranchPrefix) + `[1-9][0-9]*(-[A-Za-z0-9_]+)*$`)

// rootSuffix names the directory beside the shared checkout that holds every worktree, the
// layout git-wt uses, so a worktree made either way is found by its branch.
const rootSuffix = "-wt"

func refused(format string, args ...any) error {
	return exitcode.New(exitcode.Refused, fmt.Sprintf(format, args...))
}

// noHooks keeps a repository's checkout hooks from running inside oe.
func noHooks(dir string, args ...string) []string {
	return append([]string{"-c", "core.hooksPath=" + os.DevNull, "-C", dir}, args...)
}

// Ensure returns the worktree for req.Branch, creating it only when none exists: it reuses a
// worktree that has the branch, adds one for a local branch, recovers a branch only on origin,
// or starts a new branch at the pinned commit of origin/<default>. A worktree or branch whose
// head is not the recorded head stops it, since the worktree is never the source of truth.
func Ensure(ctx context.Context, g Git, req Request) (Result, error) {
	if !branchRe.MatchString(req.Branch) {
		return Result{}, refused("branch %q is not a loop branch", req.Branch)
	}
	list, err := List(ctx, g, req.Dir)
	if err != nil {
		return Result{}, err
	}
	if e, i, ok := byBranch(list, req.Branch); ok {
		return reuse(e, i, req)
	}
	path := filepath.Join(filepath.Dir(list[0].Path), filepath.Base(list[0].Path)+rootSuffix, filepath.FromSlash(req.Branch))
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		return Result{}, refused("%s already exists and is no worktree of %s; a person must move it", path, req.Branch)
	}
	res, err := add(ctx, g, req, path)
	if err != nil {
		return Result{}, err
	}
	e, err := Verify(ctx, g, req.Dir, path, req.Branch)
	if err != nil {
		return Result{}, err
	}
	res.Worktree, res.Head = e.Path, e.Head
	return res, nil
}

func reuse(e Entry, i int, req Request) (Result, error) {
	switch {
	case i == 0 || canonical(e.Path) == canonical(req.Dir):
		return Result{}, refused("the shared checkout has %s checked out; oe never works in it", req.Branch)
	case e.Prunable:
		return Result{}, refused("the worktree of %s at %s is missing; a person must prune it", req.Branch, e.Path)
	}
	if err := sameHead(req, e.Head, "its worktree"); err != nil {
		return Result{}, err
	}
	return Result{Branch: req.Branch, Worktree: e.Path, Head: e.Head, Base: "", Source: Reused}, nil
}

func add(ctx context.Context, g Git, req Request, path string) (Result, error) {
	res := Result{Branch: req.Branch, Worktree: "", Head: "", Base: "", Source: ""}
	local, err := ref(ctx, g, req.Dir, "refs/heads/"+req.Branch)
	if err != nil {
		return res, err
	}
	if local != "" {
		if err := sameHead(req, local, "the local branch"); err != nil {
			return res, err
		}
		res.Source = LocalBranch
		_, err = g.GitWrite(ctx, noHooks(req.Dir, "worktree", "add", path, req.Branch)...)
		return res, err
	}
	remote, err := remoteHead(ctx, g, req.Dir, req.Branch)
	if err != nil {
		return res, err
	}
	if remote != "" {
		if err := sameHead(req, remote, "origin's branch"); err != nil {
			return res, err
		}
		res.Source = RemoteBranch
		return res, recoverRemote(ctx, g, req, path, remote)
	}
	if req.Recorded != nil {
		return res, refused("%s is recorded at %s but exists nowhere, locally or on origin; a person must decide", req.Branch, *req.Recorded)
	}
	base, err := ref(ctx, g, req.Dir, "refs/remotes/origin/"+req.DefaultBranch)
	if err != nil {
		return res, err
	}
	if base == "" {
		return res, refused("origin/%s is missing; fetch origin %s once before creating worktrees", req.DefaultBranch, req.DefaultBranch)
	}
	res.Source, res.Base = NewBranch, base
	// The commit, not the ref name, is the start point, so a fetch racing this call cannot move it.
	_, err = g.GitWrite(ctx, noHooks(req.Dir, "worktree", "add", "--no-track", "-b", req.Branch, path, base)...)
	return res, err
}

// recoverRemote fetches only origin's branch into its remote-tracking ref, checks the fetch
// brought the commit ls-remote named, and adds the branch at that commit.
func recoverRemote(ctx context.Context, g Git, req Request, path, sha string) error {
	tracking := "refs/remotes/origin/" + req.Branch
	if _, err := g.GitWrite(ctx, noHooks(req.Dir, "fetch", "--no-tags", "origin", "+refs/heads/"+req.Branch+":"+tracking)...); err != nil {
		return err
	}
	got, err := ref(ctx, g, req.Dir, tracking)
	if err != nil {
		return err
	}
	if got != sha {
		return exitcode.New(exitcode.Stale, fmt.Sprintf("origin's %s moved from %s to %s while it was recovered; run again", req.Branch, sha, got))
	}
	_, err = g.GitWrite(ctx, noHooks(req.Dir, "worktree", "add", "--no-track", "-b", req.Branch, path, sha)...)
	return err
}

func sameHead(req Request, head, where string) error {
	if req.Recorded != nil && *req.Recorded != head {
		return refused("%s of %s is at %s, not the recorded head %s; it diverged from what GitHub records, so a person must decide",
			where, req.Branch, head, *req.Recorded)
	}
	return nil
}

// ref returns the commit a ref names, or "" when there is no such ref.
func ref(ctx context.Context, g Git, dir, name string) (string, error) {
	out, err := g.Git(ctx, "-C", dir, "for-each-ref", "--format=%(objectname)", name)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// remoteHead asks origin for the branch's commit, or "" when origin has no such branch.
func remoteHead(ctx context.Context, g Git, dir, branch string) (string, error) {
	out, err := g.Git(ctx, "-C", dir, "ls-remote", "--heads", "origin", "refs/heads/"+branch)
	if err != nil {
		return "", err
	}
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		sha, name, ok := strings.Cut(line, "\t")
		if ok && name == "refs/heads/"+branch {
			return sha, nil
		}
	}
	return "", nil
}

// Verify checks that path is a registered worktree, not the shared checkout, with branch checked
// out and no detached HEAD, and returns its entry.
func Verify(ctx context.Context, g Git, dir, path, branch string) (Entry, error) {
	if err := existingDir(path); err != nil {
		return Entry{}, err
	}
	list, err := List(ctx, g, dir)
	if err != nil {
		return Entry{}, err
	}
	want := canonical(path)
	i := slices.IndexFunc(list, func(e Entry) bool { return canonical(e.Path) == want })
	switch {
	case i < 0:
		return Entry{}, refused("%s is not a worktree of this repository", path)
	case i == 0 || want == canonical(dir):
		return Entry{}, refused("%s is the shared checkout, never a worker's worktree", path)
	case list[i].Detached || list[i].Branch != "refs/heads/"+branch:
		return Entry{}, refused("worktree %s has %s checked out, not %s", path, describeHead(list[i]), branch)
	}
	return list[i], nil
}

func existingDir(path string) error {
	if path == "" || !filepath.IsAbs(path) {
		return refused("worktree %q is not an absolute path", path)
	}
	if st, err := os.Stat(path); err != nil || !st.IsDir() {
		return refused("worktree %s does not exist", path)
	}
	return nil
}

func describeHead(e Entry) string {
	if e.Detached {
		return "a detached HEAD"
	}
	return strings.TrimPrefix(e.Branch, "refs/heads/")
}

// Dirty reports whether a worktree holds uncommitted changes or untracked files not ignored.
func Dirty(ctx context.Context, g Git, path string) (bool, error) {
	out, err := g.Git(ctx, "-C", path, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return false, err
	}
	return len(bytes.TrimSpace(out)) > 0, nil
}

func canonical(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

func byBranch(list []Entry, branch string) (Entry, int, bool) {
	i := slices.IndexFunc(list, func(e Entry) bool { return !e.Detached && e.Branch == "refs/heads/"+branch })
	if i < 0 {
		return Entry{Path: "", Head: "", Branch: "", Detached: false, Bare: false, Prunable: false}, 0, false
	}
	return list[i], i, true
}

// List reads the registered worktrees, the shared checkout first.
func List(ctx context.Context, g Git, dir string) ([]Entry, error) {
	out, err := g.Git(ctx, "-C", dir, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	list := parse(string(out))
	if len(list) == 0 || list[0].Bare {
		return nil, exitcode.New(exitcode.Refused, "oe needs a non-bare checkout of the repository to make worktrees from")
	}
	return list, nil
}

func parse(out string) []Entry {
	var list []Entry
	for block := range strings.SplitSeq(strings.TrimSpace(out), "\n\n") {
		var e Entry
		for line := range strings.SplitSeq(block, "\n") {
			key, val, _ := strings.Cut(line, " ")
			switch key {
			case "worktree":
				e.Path = val
			case "HEAD":
				e.Head = val
			case "branch":
				e.Branch = val
			case "detached":
				e.Detached = true
			case "bare":
				e.Bare = true
			case "prunable":
				e.Prunable = true
			}
		}
		if e.Path != "" {
			list = append(list, e)
		}
	}
	return list
}
