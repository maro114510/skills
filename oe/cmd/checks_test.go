package cmd_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/runner"
)

func gitCall(argv []string, stdout string) runner.Call {
	return runner.Call{Argv: argv, Stdout: stdout, Stderr: "", ExitCode: 0}
}

func deriveSnapshot(t *testing.T, files map[string]string) string {
	t.Helper()
	paths := make([]string, 0, len(files))
	calls := make([]runner.Call, 0, len(files)+2)
	calls = append(calls, gitCall([]string{"git", "rev-parse", "--verify", "origin/main^{commit}"}, testRevision+"\n"))
	for path := range files {
		paths = append(paths, path)
	}
	calls = append(calls, gitCall(
		[]string{"git", "ls-tree", "-r", "--full-tree", "--name-only", "origin/main", "--", ":(top).github/workflows"},
		strings.Join(paths, "\n")+"\n",
	))
	for path, body := range files {
		calls = append(calls, gitCall([]string{"git", "show", "origin/main:" + path}, body))
	}
	return snapshotPath(t, calls)
}

const testRevision = "0123456789abcdef0123456789abcdef01234567"

func snapshotPath(t *testing.T, calls []runner.Call) string {
	t.Helper()
	data, err := json.Marshal(map[string]any{"calls": calls})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "snapshot.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestChecksDerivePrintsSet(t *testing.T) {
	t.Parallel()

	snapshot := deriveSnapshot(t, map[string]string{
		".github/workflows/test.yml": "on: pull_request\njobs:\n  test:\n    steps:\n      - run: go test ./...\n",
	})
	r := run(runner.Exec{}, "checks", "derive", "--base", "main", "--ref", "origin/main", "--snapshot", snapshot)
	if r.code != 0 {
		t.Fatalf("exit = %d, stderr = %q, stdout = %q", r.code, r.stderr, r.stdout)
	}
	var set checks.Set
	if err := json.Unmarshal([]byte(r.stdout), &set); err != nil {
		t.Fatalf("stdout is not a CHECKS_SET payload: %v; %q", err, r.stdout)
	}
	if set.Revision != testRevision || len(set.Entries) != 1 || !set.Entries[0].Runnable {
		t.Errorf("set = %+v, want the derived revision and one runnable entry", set)
	}
}

func TestChecksDeriveRejectsUnparseableYAML(t *testing.T) {
	t.Parallel()

	snapshot := deriveSnapshot(t, map[string]string{".github/workflows/bad.yml": "on: [push\n"})
	r := run(runner.Exec{}, "checks", "derive", "--base", "main", "--ref", "origin/main", "--snapshot", snapshot)
	if r.code == 0 {
		t.Fatalf("exit = 0, want non-zero; stdout = %q", r.stdout)
	}
	if strings.Count(r.stdout, "\n") != 1 || !strings.Contains(r.stdout, "unreadable") {
		t.Errorf("stdout = %q, want one unreadable verdict and no set", r.stdout)
	}
	if strings.Contains(r.stdout, `"entries"`) {
		t.Errorf("stdout = %q, want no set on an unparseable workflow", r.stdout)
	}
}

func TestChecksRunRefusesSnapshot(t *testing.T) {
	t.Parallel()

	r := run(runner.Exec{}, "checks", "run", "--snapshot", "recorded.json", "--set", "set.json")
	if r.code != 8 {
		t.Errorf("exit = %d, want 8; stdout = %q", r.code, r.stdout)
	}
	if !strings.Contains(r.stdout, "refused") {
		t.Errorf("stdout = %q, want a refused verdict", r.stdout)
	}
}

func TestChecksRunNeedsSet(t *testing.T) {
	t.Parallel()

	r := run(runner.Exec{}, "checks", "run")
	if r.code != 2 {
		t.Errorf("exit = %d, want 2; stdout = %q", r.code, r.stdout)
	}
	if !strings.Contains(r.stdout, "--set") {
		t.Errorf("stdout = %q, want the missing --set named", r.stdout)
	}
}

func newTestRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Test"},
	} {
		runGit(t, dir, args...)
	}
	if err := os.WriteFile(filepath.Join(dir, "tracked.txt"), []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, dir, "add", "tracked.txt")
	runGit(t, dir, "commit", "-q", "-m", "init")
	return dir
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, append([]string{"-C", dir}, args...))
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("git %v: err %v, exit %d, stderr %s", args, err, res.ExitCode, res.Stderr)
	}
}

func headSHA(t *testing.T, dir string) string {
	t.Helper()
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, []string{"-C", dir, "rev-parse", "HEAD"})
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("rev-parse HEAD: err %v, exit %d", err, res.ExitCode)
	}
	return strings.TrimSpace(string(res.Stdout))
}

func writeSet(t *testing.T, set checks.Set) string {
	t.Helper()
	data, err := json.Marshal(set)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "set.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestChecksRunStaleRevision(t *testing.T) {
	t.Parallel()

	dir := newTestRepo(t)
	set := checks.Set{
		Ref: "HEAD", Base: "main", Revision: strings.Repeat("0", 40),
		DefaultBranchPush: "none", Entries: []checks.Entry{},
	}
	r := run(runner.Exec{}, "checks", "run", "--set", writeSet(t, set), "--worktree", dir)
	if r.code != 3 {
		t.Errorf("exit = %d, want 3; stdout = %q", r.code, r.stdout)
	}
	if !strings.Contains(r.stdout, "stale") {
		t.Errorf("stdout = %q, want a stale verdict", r.stdout)
	}
}

func TestChecksRunPrintsReportWhenACheckFails(t *testing.T) {
	t.Parallel()

	dir := newTestRepo(t)
	set := checks.Set{
		Ref: "HEAD", Base: "main", Revision: headSHA(t, dir), DefaultBranchPush: "none",
		Entries: []checks.Entry{{
			File: "test.yml", Job: "test", Step: "fails", StepIndex: 0, Kind: "run",
			Command: "exit 5", Action: "", WorkingDirectory: "", Env: map[string]string{},
			Shell: "", Runnable: true, RequiresRunnerReason: "",
		}},
	}
	r := run(runner.Exec{}, "checks", "run", "--set", writeSet(t, set), "--worktree", dir)
	if r.code != 4 {
		t.Fatalf("exit = %d, want 4; stdout = %q", r.code, r.stdout)
	}
	var report checks.Report
	if err := json.Unmarshal([]byte(r.stdout), &report); err != nil {
		t.Fatalf("stdout is not a report payload: %v; %q", err, r.stdout)
	}
	if report.OK || len(report.Results) != 1 || report.Results[0].ExitCode != 5 {
		t.Errorf("report = %+v, want one failing result", report)
	}
}
