package scan_test

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/runner"
	"github.com/maro114510/skills/oe/internal/scan"
)

// gitArgs isolates test repositories from the developer's hooks, signing, and identity.
func gitArgs(dir string, args ...string) []string {
	return append([]string{
		"-C", dir, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
		"-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main",
	}, args...)
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, gitArgs(dir, args...))
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("git %v: err %v, exit %d, stderr %s", args, err, res.ExitCode, res.Stderr)
	}
	return strings.TrimSpace(string(res.Stdout))
}

// write puts a file under dir through os.Root, which cannot leave dir, so no linter has to be told the name is safe.
func write(t *testing.T, dir, name, body string) {
	t.Helper()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = root.Close() }()
	rel := filepath.FromSlash(name)
	if err := root.MkdirAll(filepath.Dir(rel), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := root.WriteFile(rel, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func commitAll(t *testing.T, dir, msg string) string {
	t.Helper()
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "--no-verify", "--allow-empty", "-m", msg)
	return git(t, dir, "rev-parse", "HEAD")
}

// newBranch makes a repository with one commit on main and a checkout on feature.
func newBranch(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	git(t, dir, "init", "-q")
	write(t, dir, "README.md", "hello\n")
	commitAll(t, dir, "init")
	git(t, dir, "switch", "-q", "-c", "feature")
	return dir
}

func outgoing(t *testing.T, dir string) scan.OutgoingReport {
	t.Helper()
	r, err := scan.Outgoing(t.Context(), gh.New(runner.Exec{}, false), dir, "main")
	if err != nil {
		t.Fatalf("Outgoing() error = %v", err)
	}
	return r
}

func TestOutgoingFindsAKeyAddedThenDeleted(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "config.yaml", "region: x\naws: "+awsKey()+"\n")
	added := commitAll(t, dir, "add config")
	write(t, dir, "config.yaml", "region: x\n")
	commitAll(t, dir, "drop the key")

	r := outgoing(t, dir)
	want := []scan.Finding{{Rule: scan.RuleAWSKey, Where: scan.WhereCommitContent, Commit: added, Path: "config.yaml", Line: 2}}
	if r.Clean || !slices.Equal(r.Findings, want) || len(r.Commits) != 2 {
		t.Errorf("Outgoing() = %+v; want findings %+v over 2 commits", r, want)
	}
}

func TestOutgoingFindsATokenInACommitMessage(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "a.txt", "a\n")
	sha := commitAll(t, dir, "subject\n\nuse "+githubToken()+" to push")

	r := outgoing(t, dir)
	want := []scan.Finding{{Rule: scan.RuleGitHubToken, Where: scan.WhereCommitMessage, Commit: sha, Path: "", Line: 3}}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() = %+v; want %+v", r, want)
	}
}

func TestOutgoingNeverEchoesTheValue(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "a.txt", githubToken()+"\n")
	commitAll(t, dir, "msg "+skKey())
	write(t, dir, "b.txt", awsKey()+"\n")

	r := outgoing(t, dir)
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if r.Clean || len(r.Findings) != 3 {
		t.Fatalf("Outgoing() = %+v; want 3 findings", r)
	}
	for _, s := range []string{githubToken(), skKey(), awsKey()} {
		if strings.Contains(string(data), s) {
			t.Errorf("report %s echoes a matched value", data)
		}
	}
}

func TestOutgoingUnreadableObjectFailsClosed(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "data.txt", "unique payload for this test\n")
	commitAll(t, dir, "add data")
	blob := git(t, dir, "rev-parse", "HEAD:data.txt")
	// Git reads a blob from a matching worktree file, so change the file first.
	write(t, dir, "data.txt", "changed\n")
	commitAll(t, dir, "change data")
	if err := os.Remove(filepath.Join(dir, ".git", "objects", blob[:2], blob[2:])); err != nil {
		t.Fatal(err)
	}

	_, err := scan.Outgoing(t.Context(), gh.New(runner.Exec{}, false), dir, "main")
	if exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("Outgoing() error = %v; want exit 1", err)
	}
}

// TestOutgoingShallowHistoryFailsClosed hides the commit that adds a key behind a shallow boundary.
// The visible commit only deletes the key, so a scan of it alone would report clean.
func TestOutgoingShallowHistoryFailsClosed(t *testing.T) {
	t.Parallel()

	origin := newBranch(t)
	write(t, origin, "config.yaml", awsKey()+"\n")
	commitAll(t, origin, "add key")
	write(t, origin, "config.yaml", "none\n")
	commitAll(t, origin, "drop key")

	clone := filepath.Join(t.TempDir(), "clone")
	git(t, origin, "clone", "-q", "--depth", "1", "--no-single-branch", "file://"+origin, clone)
	git(t, clone, "switch", "-q", "feature")

	r, err := scan.Outgoing(t.Context(), gh.New(runner.Exec{}, false), clone, "origin/main")
	if exitcode.CodeOf(err) != exitcode.Unreadable || r.Clean {
		t.Errorf("Outgoing() = %+v, %v; want exit 1 and not clean", r, err)
	}
}

func TestOutgoingUnknownBaseFailsClosed(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	r, err := scan.Outgoing(t.Context(), gh.New(runner.Exec{}, false), dir, "origin/nope")
	if exitcode.CodeOf(err) != exitcode.Unreadable || r.Clean {
		t.Errorf("Outgoing() = %+v, %v; want exit 1 and not clean", r, err)
	}
}

// TestOutgoingMergeReportsOnlyItsOwnLines merges a base that holds a key and resolves the conflict with one more line.
// The key is already published, so only the new line is a finding.
func TestOutgoingMergeReportsOnlyItsOwnLines(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	git(t, dir, "init", "-q")
	write(t, dir, "f.txt", "a\nb\n")
	commitAll(t, dir, "init")
	git(t, dir, "switch", "-q", "-c", "feature")
	write(t, dir, "f.txt", "a\nb\nfeat\n")
	commitAll(t, dir, "feature")
	git(t, dir, "switch", "-q", "main")
	write(t, dir, "f.txt", "a\nb\n"+awsKey()+"\n")
	write(t, dir, "base.txt", awsKey()+"\n")
	commitAll(t, dir, "base")
	git(t, dir, "switch", "-q", "feature")
	// The merge conflicts and exits 1, and the resolution below completes it.
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, gitArgs(dir, "merge", "-q", "--no-commit", "main"))
	if err != nil || res.ExitCode != 1 {
		t.Fatalf("merge: err %v, exit %d; want a conflict", err, res.ExitCode)
	}
	write(t, dir, "f.txt", "a\nb\nfeat\n"+awsKey()+"\n"+githubToken()+"\n")
	merge := commitAll(t, dir, "merge main")

	r := outgoing(t, dir)
	want := []scan.Finding{{Rule: scan.RuleGitHubToken, Where: scan.WhereCommitContent, Commit: merge, Path: "f.txt", Line: 5}}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() = %+v; want %+v", r, want)
	}
}

func TestOutgoingFlagsSecretPaths(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, ".env", "")
	write(t, dir, "tls/server.crt", "cert\n")
	first := commitAll(t, dir, "empty env and a cert")
	git(t, dir, "mv", "tls/server.crt", "tls/server.pem")
	second := commitAll(t, dir, "rename")

	r := outgoing(t, dir)
	want := []scan.Finding{
		{Rule: scan.RulePathEnv, Where: scan.WhereCommitPath, Commit: first, Path: ".env", Line: 0},
		{Rule: scan.RulePathPEM, Where: scan.WhereCommitPath, Commit: second, Path: "tls/server.pem", Line: 0},
	}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() = %+v; want %+v", r, want)
	}
}

// TestOutgoingPathWithASpace covers the tab git puts after a path that holds a space.
func TestOutgoingPathWithASpace(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "prod key.pem", "cert\n")
	sha := commitAll(t, dir, "add cert")
	write(t, dir, "prod key.pem", "cert\nmore\n")

	r := outgoing(t, dir)
	want := []scan.Finding{
		{Rule: scan.RulePathPEM, Where: scan.WhereCommitPath, Commit: sha, Path: "prod key.pem", Line: 0},
		{Rule: scan.RulePathPEM, Where: scan.WhereWorktreePath, Commit: "", Path: "prod key.pem", Line: 0},
	}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() = %+v; want %+v", r.Findings, want)
	}
}

// TestOutgoingFromASubdirectoryScansTheWholeWorktree finds an untracked file outside the subdirectory the scan starts in.
func TestOutgoingFromASubdirectoryScansTheWholeWorktree(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "sub/a.txt", "a\n")
	commitAll(t, dir, "sub")
	write(t, dir, "top.txt", githubToken()+"\n")

	r, err := scan.Outgoing(t.Context(), gh.New(runner.Exec{}, false), filepath.Join(dir, "sub"), "main")
	want := []scan.Finding{{Rule: scan.RuleGitHubToken, Where: scan.WhereWorktreeContent, Commit: "", Path: "top.txt", Line: 1}}
	if err != nil || r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() = %+v, %v; want %+v", r.Findings, err, want)
	}
}

// TestOutgoingSubmoduleLogConfig keeps a user's submodule diff format from breaking the parser.
func TestOutgoingSubmoduleLogConfig(t *testing.T) {
	t.Parallel()

	sub := newBranch(t)
	dir := newBranch(t)
	git(t, dir, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sub")
	commitAll(t, dir, "add submodule")
	write(t, sub, "more.txt", "more\n")
	commitAll(t, sub, "more")
	git(t, filepath.Join(dir, "sub"), "-c", "protocol.file.allow=always", "pull", "-q", "origin", "feature")
	git(t, dir, "config", "diff.submodule", "log")

	r, err := scan.Outgoing(t.Context(), gh.New(runner.Exec{}, false), dir, "main")
	if err != nil || !r.Clean {
		t.Errorf("Outgoing() = %+v, %v; want clean", r, err)
	}
}

func TestOutgoingWithholdsASecretPath(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "notes-"+githubToken()+".txt", "x\n")
	commitAll(t, dir, "odd name")

	r := outgoing(t, dir)
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if r.Clean || len(r.Findings) != 1 || r.Findings[0].Path != scan.Withheld || strings.Contains(string(data), githubToken()) {
		t.Errorf("Outgoing() = %s; want one finding with a withheld path", data)
	}
}

func TestOutgoingBinaryIsUnscannable(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "blob.bin", "a\x00b")
	sha := commitAll(t, dir, "binary")

	r := outgoing(t, dir)
	want := []scan.Finding{{Rule: scan.RuleUnscannable, Where: scan.WhereCommitContent, Commit: sha, Path: "blob.bin", Line: 0}}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() = %+v; want %+v", r, want)
	}
}

// TestOutgoingLateNULIsUnscannable places a NUL past the prefix git probes for binary content, so git diffs the file as text.
func TestOutgoingLateNULIsUnscannable(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, "late.dat", strings.Repeat("a", 9000)+"\nx\x00y\n")
	sha := commitAll(t, dir, "late nul")

	r := outgoing(t, dir)
	want := []scan.Finding{{Rule: scan.RuleUnscannable, Where: scan.WhereCommitContent, Commit: sha, Path: "late.dat", Line: 2}}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() = %+v; want %+v", r.Findings, want)
	}
}

func TestOutgoingScansTheWorktree(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	write(t, dir, ".gitignore", "ignored.txt\n")
	commitAll(t, dir, "ignore")
	write(t, dir, "README.md", "hello\n"+awsKey()+"\n")
	write(t, dir, "new/untracked.txt", "one\n"+githubToken()+"\n")
	write(t, dir, "ignored.txt", skKey()+"\n")
	write(t, dir, "id_"+"ed25519", "")
	write(t, dir, "raw.dat", "x\x00y")
	if err := os.Symlink("/nonexistent/"+slackToken(), filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}

	r := outgoing(t, dir)
	want := []scan.Finding{
		{Rule: scan.RuleAWSKey, Where: scan.WhereWorktreeContent, Commit: "", Path: "README.md", Line: 2},
		{Rule: scan.RulePathSSHKey, Where: scan.WhereWorktreePath, Commit: "", Path: "id_" + "ed25519", Line: 0},
		{Rule: scan.RuleSlackToken, Where: scan.WhereWorktreeContent, Commit: "", Path: "link", Line: 1},
		{Rule: scan.RuleGitHubToken, Where: scan.WhereWorktreeContent, Commit: "", Path: "new/untracked.txt", Line: 2},
		{Rule: scan.RuleUnscannable, Where: scan.WhereWorktreeContent, Commit: "", Path: "raw.dat", Line: 0},
	}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Outgoing() findings = %+v; want %+v", r.Findings, want)
	}
}

// TestOutgoingRepresentativeBranchIsClean commits and edits real files from this repository.
func TestOutgoingRepresentativeBranchIsClean(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	root := filepath.Join("..", "..", "..")
	files := []string{
		"skills/orchestrate-epic/SKILL.md",
		"skills/orchestrate-epic/references/commands.md",
		"skills/orchestrate-epic/references/templates.md",
		"skills/commit/SKILL.md",
		"docs/design/orchestrate-epic-v2/contract.md",
		"oe/cmd/root.go",
		"oe/cmd/cmd_test.go",
		"oe/internal/runner/runner.go",
		"oe/internal/scan/text_test.go",
		"oe/internal/scan/outgoing_test.go",
	}
	for _, f := range files {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(f))) //nolint:gosec // G304: a fixed repository file.
		if err != nil {
			t.Fatal(err)
		}
		write(t, dir, f, string(data))
	}
	commitAll(t, dir, "feat(oe): add representative files\n\nRefs #283")
	write(t, dir, "oe/cmd/root.go", "// edited\n")
	commitAll(t, dir, "refactor: trim root.go")

	r := outgoing(t, dir)
	if !r.Clean || len(r.Findings) != 0 || len(r.Commits) != 2 || r.Base == "" || r.Head == "" {
		t.Errorf("Outgoing() = %+v; want clean over 2 commits", r)
	}
}

func TestOutgoingNoCommitsIsClean(t *testing.T) {
	t.Parallel()

	dir := newBranch(t)
	r := outgoing(t, dir)
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Clean || !strings.Contains(string(data), `"commits":[]`) || !strings.Contains(string(data), `"findings":[]`) {
		t.Errorf("Outgoing() = %s; want clean with empty lists", data)
	}
}

func TestOutgoingErrorNeverEchoesGitOutput(t *testing.T) {
	t.Parallel()

	_, err := scan.Outgoing(t.Context(), gh.New(runner.Exec{}, false), t.TempDir(), "main")
	var coded *exitcode.Error
	if !errors.As(err, &coded) || coded.Code != exitcode.Unreadable || coded.Err != nil {
		t.Errorf("Outgoing() error = %#v; want an exit 1 error with no wrapped git output", err)
	}
}
