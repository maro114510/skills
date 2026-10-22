package scan

import (
	"bytes"
	"cmp"
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// Git runs read-only git commands. *gh.Client satisfies it.
type Git interface {
	Git(ctx context.Context, args ...string) ([]byte, error)
}

// OutgoingReport is the scan of everything a push from a worktree would publish.
type OutgoingReport struct {
	Clean    bool      `json:"clean"`
	Base     string    `json:"base"`
	Head     string    `json:"head"`
	Commits  []string  `json:"commits"`
	Findings []Finding `json:"findings"`
}

var objectNameRE = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

// Outgoing scans each commit on HEAD that base lacks, then uncommitted and untracked files.
// A scan that cannot finish returns an exit 1 error that never carries git's output.
func Outgoing(ctx context.Context, git Git, worktree, base string) (OutgoingReport, error) {
	r := OutgoingReport{Clean: false, Base: "", Head: "", Commits: []string{}, Findings: []Finding{}}
	if base == "" || strings.HasPrefix(base, "-") {
		return r, exitcode.New(exitcode.Usage, "scan needs a base ref that is not an option")
	}
	s, err := newScanner(ctx, git, worktree)
	if err != nil {
		return r, err
	}
	if r.Base, r.Head, r.Commits, err = s.outgoingRange(base); err != nil {
		return r, err
	}
	var findings []Finding
	for _, c := range r.Commits {
		f, err := s.commit(c)
		if err != nil {
			return r, err
		}
		findings = append(findings, f...)
	}
	f, err := s.worktreeFindings()
	if err != nil {
		return r, err
	}
	r.Findings = append(r.Findings, append(findings, f...)...)
	r.Clean = len(r.Findings) == 0
	return r, nil
}

type scanner struct {
	ctx      context.Context //nolint:containedctx // The context lives as long as one scan.
	git      Git
	worktree string
}

// newScanner moves to the top level, because git lists untracked files below the working directory only.
func newScanner(ctx context.Context, git Git, worktree string) (scanner, error) {
	s := scanner{ctx: ctx, git: git, worktree: worktree}
	top, err := s.run("find the worktree's top level", "rev-parse", "--show-toplevel")
	if err != nil {
		return s, err
	}
	if s.worktree = strings.TrimSpace(string(top)); s.worktree == "" {
		return s, exitcode.New(exitcode.Unreadable, "scan cannot find the worktree's top level")
	}
	return s, nil
}

// outgoingRange resolves base and HEAD and lists the commits between them.
func (s scanner) outgoingRange(base string) (string, string, []string, error) {
	baseSHA, err := s.object("resolve the base "+base, base+"^{commit}")
	if err != nil {
		return "", "", []string{}, err
	}
	head, err := s.object("resolve HEAD", "HEAD^{commit}")
	if err != nil {
		return baseSHA, "", []string{}, err
	}
	commits, err := s.commits(head, baseSHA)
	if err != nil {
		return baseSHA, head, []string{}, err
	}
	return baseSHA, head, commits, nil
}

// run calls git with replace objects off and without writing the index.
func (s scanner) run(what string, args ...string) ([]byte, error) {
	argv := append([]string{
		"--no-replace-objects", "--no-optional-locks", "-c", "core.quotePath=false", "-C", s.worktree,
	}, args...)
	out, err := s.git.Git(s.ctx, argv...)
	if err != nil {
		return nil, exitcode.New(exitcode.Unreadable, "scan cannot "+what)
	}
	return out, nil
}

func (s scanner) object(what, rev string) (string, error) {
	out, err := s.run(what, "rev-parse", "--verify", "--quiet", rev)
	if err != nil {
		return "", err
	}
	sha := strings.TrimSpace(string(out))
	if !objectNameRE.MatchString(sha) {
		return "", exitcode.New(exitcode.Unreadable, "scan cannot "+what)
	}
	return sha, nil
}

// commits lists the range oldest first.
// A shallow boundary inside the range can hide commits, so it stops the scan.
func (s scanner) commits(head, base string) ([]string, error) {
	out, err := s.run("list the outgoing commits", "rev-list", "--reverse", head, "--not", base)
	if err != nil {
		return nil, err
	}
	commits := strings.Fields(string(out))
	for _, c := range commits {
		if !objectNameRE.MatchString(c) {
			return nil, exitcode.New(exitcode.Unreadable, "scan cannot list the outgoing commits")
		}
	}
	shallow, err := s.shallowCommits()
	if err != nil {
		return nil, err
	}
	for _, c := range commits {
		if shallow[c] {
			return nil, exitcode.New(exitcode.Unreadable,
				"scan cannot see the full history: outgoing commit "+c+" is a shallow boundary; fetch with --unshallow")
		}
	}
	return commits, nil
}

func (s scanner) shallowCommits() (map[string]bool, error) {
	out, err := s.run("tell whether the repository is shallow", "rev-parse", "--is-shallow-repository")
	if err != nil {
		return nil, err
	}
	switch strings.TrimSpace(string(out)) {
	case "false":
		return map[string]bool{}, nil
	case "true":
	default:
		return nil, exitcode.New(exitcode.Unreadable, "scan cannot tell whether the repository is shallow")
	}
	out, err = s.run("find the shallow file", "rev-parse", "--path-format=absolute", "--git-path", "shallow")
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(strings.TrimSpace(string(out)))
	if err != nil {
		return nil, exitcode.New(exitcode.Unreadable, "scan cannot read the shallow file")
	}
	set := map[string]bool{}
	for c := range strings.FieldsSeq(string(data)) {
		set[c] = true
	}
	if len(set) == 0 {
		return nil, exitcode.New(exitcode.Unreadable, "scan cannot read the shallow file")
	}
	return set, nil
}

func (s scanner) commit(sha string) ([]Finding, error) {
	raw, err := s.run("read commit "+sha, "cat-file", "commit", sha)
	if err != nil {
		return nil, err
	}
	_, msg, ok := bytes.Cut(raw, []byte("\n\n"))
	if !ok {
		msg = nil // A commit with an empty message has no blank line.
	}
	at := Finding{Rule: "", Where: WhereCommitMessage, Commit: sha, Path: "", Line: 0}
	findings := scanLines(msg, 1, at)
	if line := nulLine(msg); line > 0 {
		at.Rule, at.Line = RuleUnscannable, line
		findings = append(findings, at)
	}
	patch, err := s.run("read the changes of commit "+sha, "diff-tree", "--no-commit-id", "--root", "-r", "-p", "--cc",
		"-U0", "-M", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", sha)
	if err != nil {
		return nil, err
	}
	files, err := parsePatch(patch)
	if err != nil {
		return nil, exitcode.New(exitcode.Unreadable, "scan cannot parse the changes of commit "+sha)
	}
	at = Finding{Rule: "", Where: "", Commit: sha, Path: "", Line: 0}
	return append(findings, fileFindings(files, at, WhereCommitPath, WhereCommitContent)...), nil
}

// fileFindings reports the path rules, binary content, and added lines of each changed file.
func fileFindings(files []fileDiff, at Finding, wherePath, whereContent string) []Finding {
	var out []Finding
	for _, f := range files {
		if f.deleted {
			continue
		}
		out = append(out, pathFindings(f.path, at, wherePath)...)
		at.Path, _ = locate(f.path)
		at.Where = whereContent
		if f.binary {
			u := at
			u.Rule = RuleUnscannable
			out = append(out, u)
		} else if line := firstNULLine(f.added); line > 0 {
			u := at
			u.Rule, u.Line = RuleUnscannable, line
			out = append(out, u)
		}
		for _, l := range f.added {
			for _, rule := range matchLine([]byte(l.text)) {
				hit := at
				hit.Rule, hit.Line = rule, l.line
				out = append(out, hit)
			}
		}
	}
	return out
}

// firstNULLine returns the line of the first added line with a NUL byte, or 0 when there is none.
// Git diffs a file as text when its NUL sits past the prefix it probes for binary content.
func firstNULLine(added []addedLine) int {
	for _, l := range added {
		if strings.IndexByte(l.text, 0) >= 0 {
			return l.line
		}
	}
	return 0
}

func pathFindings(p string, at Finding, where string) []Finding {
	shown, contentRules := locate(p)
	at.Where, at.Path, at.Line = where, shown, 0
	out := make([]Finding, 0, len(contentRules))
	for _, rule := range append(contentRules, MatchPath(p)...) {
		f := at
		f.Rule = rule
		out = append(out, f)
	}
	return out
}

// worktreeFindings scans changes against HEAD and untracked files that are not ignored.
func (s scanner) worktreeFindings() ([]Finding, error) {
	patch, err := s.run("read the worktree changes", "diff", "HEAD", "--no-relative", "-p", "-U0", "-M",
		"--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/")
	if err != nil {
		return nil, err
	}
	files, err := parsePatch(patch)
	if err != nil {
		return nil, exitcode.New(exitcode.Unreadable, "scan cannot parse the worktree changes")
	}
	at := Finding{Rule: "", Where: "", Commit: "", Path: "", Line: 0}
	findings := fileFindings(files, at, WhereWorktreePath, WhereWorktreeContent)
	out, err := s.run("list untracked files", "ls-files", "-z", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	for p := range strings.SplitSeq(strings.TrimSuffix(string(out), "\x00"), "\x00") {
		if p == "" {
			continue
		}
		f, err := s.untracked(p)
		if err != nil {
			return nil, err
		}
		findings = append(findings, f...)
	}
	slices.SortStableFunc(findings, func(a, b Finding) int { return cmp.Compare(a.Path, b.Path) })
	return findings, nil
}

// untracked scans a symlink by its target and a file by its content.
// Anything else, such as a nested repository, is unscannable.
func (s scanner) untracked(p string) ([]Finding, error) {
	at := Finding{Rule: "", Where: WhereWorktreePath, Commit: "", Path: "", Line: 0}
	findings := pathFindings(p, at, WhereWorktreePath)
	at.Path, _ = locate(p)
	at.Where = WhereWorktreeContent
	full := filepath.Join(s.worktree, filepath.FromSlash(strings.TrimSuffix(p, "/")))
	info, err := os.Lstat(full)
	if err != nil {
		return nil, exitcode.New(exitcode.Unreadable, "scan cannot read an untracked file")
	}
	var data []byte
	switch {
	case info.Mode()&fs.ModeSymlink != 0:
		target, err := os.Readlink(full)
		if err != nil {
			return nil, exitcode.New(exitcode.Unreadable, "scan cannot read an untracked symlink")
		}
		data = []byte(target)
	case info.Mode().IsRegular():
		if data, err = os.ReadFile(full); err != nil { //nolint:gosec // G304: a path git listed inside the worktree.
			return nil, exitcode.New(exitcode.Unreadable, "scan cannot read an untracked file")
		}
	default:
		at.Rule = RuleUnscannable
		return append(findings, at), nil
	}
	if nulLine(data) > 0 {
		at.Rule = RuleUnscannable
		return append(findings, at), nil
	}
	return append(findings, scanLines(data, 1, at)...), nil
}
