package cmd_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/cmd"
	"github.com/maro114510/skills/oe/internal/runner"
	"github.com/maro114510/skills/oe/internal/scan"
)

// fakeToken is assembled at run time so this file never matches the rule it tests.
func fakeToken() string { return "gh" + "p_" + strings.Repeat("Zz9", 8) }

func runIn(stdin string, args ...string) result {
	var out, errOut bytes.Buffer
	code := cmd.Main(args, cmd.Env{
		Stdin: strings.NewReader(stdin), Stdout: &out, Stderr: &errOut, Exec: runner.Exec{}, Version: "v1.2.3",
	})
	return result{code: code, stdout: out.String(), stderr: errOut.String()}
}

func scanRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	g := func(args ...string) {
		t.Helper()
		argv := append([]string{
			"-C", dir, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
			"-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main",
		}, args...)
		res, err := runner.Exec{}.Run(t.Context(), runner.Git, argv)
		if err != nil || res.ExitCode != 0 {
			t.Fatalf("git %v: err %v, exit %d, stderr %s", args, err, res.ExitCode, res.Stderr)
		}
	}
	g("init", "-q")
	g("commit", "-q", "--no-verify", "--allow-empty", "-m", "init")
	g("switch", "-q", "-c", "feature")
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte(fakeToken()+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	g("add", "notes.txt")
	g("commit", "-q", "--no-verify", "-m", "add notes")
	return dir
}

func TestScanTextCleanExitsZero(t *testing.T) {
	t.Parallel()

	r := runIn("## Summary\nAll checks pass.\n", "scan", "text", "--source", "pr-body")
	want := `{"clean":true,"source":"pr-body","findings":[]}` + "\n"
	if r.code != 0 || r.stdout != want || r.stderr != "" {
		t.Errorf("exit %d, stdout %q, stderr %q; want 0, %q", r.code, r.stdout, r.stderr, want)
	}
}

func TestScanTextFindingRefusesWithoutTheValue(t *testing.T) {
	t.Parallel()

	r := runIn("evidence\n"+fakeToken()+"\n", "scan", "text", "--source", "evidence")
	var report scan.TextReport
	if err := json.Unmarshal([]byte(r.stdout), &report); err != nil {
		t.Fatalf("stdout %q is not one JSON payload: %v", r.stdout, err)
	}
	if r.code != 8 || report.Clean || len(report.Findings) != 1 || report.Findings[0].Line != 2 {
		t.Errorf("exit %d, report %+v; want 8 and one finding on line 2", r.code, report)
	}
	if strings.Contains(r.stdout+r.stderr, fakeToken()) {
		t.Errorf("output echoes the matched value: stdout %q, stderr %q", r.stdout, r.stderr)
	}
}

func TestScanTextReadsAFile(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "body.md")
	if err := os.WriteFile(path, []byte(fakeToken()), 0o600); err != nil {
		t.Fatal(err)
	}
	if r := runIn("", "scan", "text", "--file", path); r.code != 8 {
		t.Errorf("exit %d, stdout %q; want 8", r.code, r.stdout)
	}
	r := runIn("", "scan", "text", "--file", filepath.Join(t.TempDir(), "missing"))
	wantOneLine(t, r, 1, "unreadable: scan cannot read the text")
}

func TestScanOutgoingFindingRefusesWithoutTheValue(t *testing.T) {
	t.Parallel()

	dir := scanRepo(t)
	r := runIn("", "scan", "outgoing", "--worktree", dir, "--base", "main")
	var report scan.OutgoingReport
	if err := json.Unmarshal([]byte(r.stdout), &report); err != nil {
		t.Fatalf("stdout %q is not one JSON payload: %v", r.stdout, err)
	}
	if r.code != 8 || report.Clean || len(report.Findings) != 1 || report.Findings[0].Path != "notes.txt" {
		t.Errorf("exit %d, report %+v; want 8 and one finding in notes.txt", r.code, report)
	}
	if strings.Contains(r.stdout+r.stderr, fakeToken()) {
		t.Errorf("output echoes the matched value: stdout %q, stderr %q", r.stdout, r.stderr)
	}
}

func TestScanOutgoingCleanExitsZero(t *testing.T) {
	t.Parallel()

	dir := scanRepo(t)
	r := runIn("", "scan", "outgoing", "--worktree", dir, "--base", "feature")
	if r.code != 0 || !strings.Contains(r.stdout, `"clean":true`) {
		t.Errorf("exit %d, stdout %q; want 0 and clean", r.code, r.stdout)
	}
}

func TestScanOutgoingUnreadableNeverReportsClean(t *testing.T) {
	t.Parallel()

	r := runIn("", "scan", "outgoing", "--worktree", t.TempDir(), "--base", "main")
	wantOneLine(t, r, 1, "unreadable: scan cannot")
	if strings.Contains(r.stdout, "clean") {
		t.Errorf("stdout %q reports a scan result", r.stdout)
	}
}

func TestScanOutgoingRefusesSnapshot(t *testing.T) {
	t.Parallel()

	s := newSpy(nil)
	r := run(s, "--snapshot", writeSnapshot(t, nil), "scan", "outgoing")
	wantOneLine(t, r, 8, "refused: --snapshot cannot scan")
	if s.count() != 0 {
		t.Errorf("calls = %v; want none", s.calls)
	}
}

func TestScanUsageErrors(t *testing.T) {
	t.Parallel()

	for name, args := range map[string][]string{
		"bare group":     {"scan"},
		"stray argument": {"scan", "text", "extra"},
		"option as base": {"scan", "outgoing", "--base", "--output=x"},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			wantOneLine(t, runIn("", args...), 2, "usage:")
		})
	}
}
