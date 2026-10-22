package checks_test

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/runner"
)

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, append([]string{"-C", dir}, args...))
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("git %v: err %v, exit %d, stderr %s", args, err, res.ExitCode, res.Stderr)
	}
}

func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	runGit(t, dir, "init", "-q")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "tracked.txt"), []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, dir, "add", "tracked.txt")
	runGit(t, dir, "commit", "-q", "-m", "init")
	return dir
}

func headRevision(t *testing.T, dir string) string {
	t.Helper()
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, []string{"-C", dir, "rev-parse", "HEAD"})
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("rev-parse HEAD: err %v, exit %d", err, res.ExitCode)
	}
	return strings.TrimSpace(string(res.Stdout))
}

func testEntry(command string, runnable bool) checks.Entry {
	return checks.Entry{
		File: "test.yml", Job: "test", Step: "step", StepIndex: 0, Kind: "run",
		Command: command, Action: "", WorkingDirectory: "", Env: map[string]string{},
		Shell: "", Runnable: runnable, RequiresRunnerReason: "",
	}
}

func testSet(t *testing.T, dir string, entries ...checks.Entry) checks.Set {
	t.Helper()
	return checks.Set{
		Ref: "HEAD", Base: "main", Revision: headRevision(t, dir),
		DefaultBranchPush: "none", Entries: entries,
	}
}

func runSet(t *testing.T, dir string, set checks.Set) checks.Report {
	t.Helper()
	report, err := checks.RunSet(t.Context(), gh.New(runner.Exec{}, false), checks.Exec{}, dir, set)
	if err != nil {
		t.Fatalf("RunSet() error = %v", err)
	}
	return report
}

func TestRunSetUsesCapturedShellEnvAndDirectory(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	entry := testEntry("if [ -n \"${BASH_VERSION:-}\" ]; then echo bash; else echo sh; fi\nprintf '%s\\n' \"$FOO\"\npwd", true)
	entry.WorkingDirectory = "sub"
	entry.Shell = "sh"
	entry.Env = map[string]string{"FOO": "from-captured-env"}
	set := testSet(t, dir, entry)
	report := runSet(t, dir, set)
	if !report.OK || len(report.Results) != 1 {
		t.Fatalf("report = %+v, want one passing result", report)
	}
	checkCapturedRun(t, report.Results[0], entry, dir)
}

func checkCapturedRun(t *testing.T, result checks.Result, entry checks.Entry, dir string) {
	t.Helper()
	if !result.Passed || result.ExitCode != 0 {
		t.Fatalf("result = %+v, want a pass", result)
	}
	wantDir := filepath.Join(dir, "sub")
	if !strings.Contains(result.Stdout, "from-captured-env") {
		t.Errorf("stdout = %q, want the captured env exported", result.Stdout)
	}
	if !strings.Contains(result.Stdout, wantDir) {
		t.Errorf("stdout = %q, want the captured working directory %s", result.Stdout, wantDir)
	}
	if result.File != entry.File || result.Job != entry.Job || result.Step != entry.Step || result.StepIndex != entry.StepIndex {
		t.Errorf("result = %+v, want the entry identity", result)
	}
}

func TestRunSetNeverExecutesRequiresRunner(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	marker := filepath.Join(dir, "should-not-exist")
	skipped := testEntry("touch "+marker, false)
	skipped.RequiresRunnerReason = "global-scope package flag"
	set := testSet(t, dir, skipped)
	report := runSet(t, dir, set)
	if len(report.Results) != 0 {
		t.Errorf("results = %+v, want a requires-runner entry never executed", report.Results)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Errorf("requires-runner entry created %s", marker)
	}
}

func TestRunSetReportsWorktreeChange(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	set := testSet(t, dir, testEntry("printf 'two\\n' >> tracked.txt", true))
	report := runSet(t, dir, set)
	if !report.OK || len(report.Results) != 1 {
		t.Fatalf("report = %+v, want one passing result", report)
	}
	if !slices.Contains(report.ChangedPaths, "tracked.txt") {
		t.Errorf("ChangedPaths = %v, want tracked.txt", report.ChangedPaths)
	}
	if !slices.Contains(report.Results[0].ChangedPaths, "tracked.txt") {
		t.Errorf("result ChangedPaths = %v, want tracked.txt", report.Results[0].ChangedPaths)
	}
}

func TestRunSetReportsChangeToAPreexistingUntrackedFile(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	untracked := filepath.Join(dir, "scratch.txt")
	if err := os.WriteFile(untracked, []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	report := runSet(t, dir, testSet(t, dir, testEntry("printf 'two\\n' >> scratch.txt", true)))
	if !report.OK || len(report.Results) != 1 {
		t.Fatalf("report = %+v, want one passing result", report)
	}
	if !slices.Contains(report.ChangedPaths, "scratch.txt") {
		t.Errorf("ChangedPaths = %v, want the modified untracked file", report.ChangedPaths)
	}
}

func TestRunSetReportsIndexChange(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	set := testSet(t, dir, testEntry("printf 'two\\n' >> tracked.txt\ngit add tracked.txt", true))
	report := runSet(t, dir, set)
	if !report.OK {
		t.Fatalf("report = %+v, want a pass", report)
	}
	if !slices.Contains(report.ChangedPaths, "tracked.txt") {
		t.Errorf("ChangedPaths = %v, want tracked.txt for an index change", report.ChangedPaths)
	}
}

func TestRunSetReportsFailure(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	set := testSet(t, dir, testEntry("exit 7", true))
	report := runSet(t, dir, set)
	if report.OK {
		t.Errorf("report.OK = true, want false")
	}
	if len(report.Results) != 1 || report.Results[0].ExitCode != 7 || report.Results[0].Passed {
		t.Errorf("results = %+v, want exit 7 and not passed", report.Results)
	}
}

func TestRunSetMissingWorkingDirectoryFailsTheEntry(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	entry := testEntry("echo should-not-run", true)
	entry.WorkingDirectory = "absent"
	report := runSet(t, dir, testSet(t, dir, entry))
	if report.OK || len(report.Results) != 1 {
		t.Fatalf("report = %+v, want one failing result", report)
	}
	if report.Results[0].Error == "" || report.Results[0].ExitCode != -1 {
		t.Errorf("result = %+v, want a not-run error", report.Results[0])
	}
}

func TestRunSetRejectsWorkingDirectoryEscape(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	entry := testEntry("echo should-not-run", true)
	entry.WorkingDirectory = "../../.."
	report := runSet(t, dir, testSet(t, dir, entry))
	if report.OK || len(report.Results) != 1 || report.Results[0].Error == "" {
		t.Fatalf("report = %+v, want a refused entry", report)
	}
}

func TestRunSetStaleRevision(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	set := testSet(t, dir, testEntry("true", true))
	set.Revision = "0000000000000000000000000000000000000000"
	_, err := checks.RunSet(t.Context(), gh.New(runner.Exec{}, false), checks.Exec{}, dir, set)
	if err == nil {
		t.Fatal("RunSet() error = nil, want a stale error")
	}
	if code := exitcode.CodeOf(err); code != exitcode.Stale {
		t.Errorf("exit code = %d, want stale (%d): %v", code, exitcode.Stale, err)
	}
	if msg := err.Error(); !strings.Contains(msg, "from "+set.Revision[:12]) || !strings.Contains(msg, "to ") {
		t.Errorf("error = %q, want the old revision as the origin and HEAD as the destination", msg)
	}
}

func TestRunSetCarriesRevision(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	set := testSet(t, dir, testEntry("true", true))
	report := runSet(t, dir, set)
	if report.Revision != set.Revision || report.Ref != set.Ref {
		t.Errorf("report = %+v, want revision %s and ref %s", report, set.Revision, set.Ref)
	}
}

type recordingRunner struct {
	commands []checks.Command
	result   checks.CommandResult
}

func (r *recordingRunner) RunCheck(_ context.Context, cmd checks.Command) (checks.CommandResult, error) {
	r.commands = append(r.commands, cmd)
	return r.result, nil
}

func TestRunSetPassesCapturedCommandToTheRunner(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	entry := testEntry("go test ./...", true)
	entry.Env = map[string]string{"A": "b"}
	entry.Shell = "bash"
	entry.WorkingDirectory = "sub"
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	rec := &recordingRunner{commands: nil, result: checks.CommandResult{ExitCode: 0, Stdout: "", Stderr: "", StartError: ""}}
	report, err := checks.RunSet(t.Context(), gh.New(runner.Exec{}, false), rec, dir, testSet(t, dir, entry))
	if err != nil {
		t.Fatalf("RunSet() error = %v", err)
	}
	if !report.OK || len(rec.commands) != 1 {
		t.Fatalf("report = %+v, commands = %+v", report, rec.commands)
	}
	got := rec.commands[0]
	if got.Script != "go test ./..." || got.Shell != "bash" || got.Env["A"] != "b" || !strings.HasSuffix(got.Dir, "sub") {
		t.Errorf("command = %+v, want the captured script, env, shell, and directory", got)
	}
}

func TestRunSetToleratesAnUntrackedSymlink(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	target := filepath.Join(dir, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	report := runSet(t, dir, testSet(t, dir, testEntry("true", true)))
	if !report.OK || len(report.Results) != 1 {
		t.Errorf("report = %+v, want the symlink not to abort the run", report)
	}
}

func TestRunSetReportsChangeToAPreexistingDirtyFile(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "tracked.txt"), []byte("dirty\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	report := runSet(t, dir, testSet(t, dir, testEntry("printf 'more\\n' >> tracked.txt", true)))
	if !report.OK {
		t.Fatalf("report = %+v, want a pass", report)
	}
	if !slices.Contains(report.ChangedPaths, "tracked.txt") {
		t.Errorf("ChangedPaths = %v, want the further-modified dirty file", report.ChangedPaths)
	}
}

func TestRunSetRejectsAWorkingDirectorySymlinkEscape(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dir, "escape")); err != nil {
		t.Fatal(err)
	}
	entry := testEntry("echo should-not-run", true)
	entry.WorkingDirectory = "escape"
	report := runSet(t, dir, testSet(t, dir, entry))
	if report.OK || len(report.Results) != 1 || report.Results[0].Error == "" {
		t.Errorf("report = %+v, want the symlinked directory refused", report)
	}
}

func TestRunSetPinsGHHostAndDropsGHRepo(t *testing.T) {
	t.Parallel()

	dir := newRepo(t)
	entry := testEntry(`printf '%s|%s' "${GH_HOST:-}" "${GH_REPO:-}"`, true)
	report := runSet(t, dir, testSet(t, dir, entry))
	if !report.OK || len(report.Results) != 1 {
		t.Fatalf("report = %+v, want one pass", report)
	}
	if got := report.Results[0].Stdout; got != "github.com|" {
		t.Errorf("stdout = %q, want GH_HOST pinned and GH_REPO absent", got)
	}
}
