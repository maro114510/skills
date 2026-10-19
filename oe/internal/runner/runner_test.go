package runner_test

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/runner"
)

// TestExecPassesArgvWithoutShell proves arguments reach the program as one argv element each:
// shell metacharacters arrive verbatim instead of being expanded.
func TestExecPassesArgvWithoutShell(t *testing.T) {
	t.Parallel()

	hostile := "$(echo pwned); `id` | cat > /tmp/x"
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, []string{"rev-parse", "--sq-quote", hostile})
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("exit = %d, stderr = %s", res.ExitCode, res.Stderr)
	}
	if got, want := strings.TrimSpace(string(res.Stdout)), "'"+hostile+"'"; got != want {
		t.Errorf("stdout = %q, want %q", got, want)
	}
}

func TestExecReportsNonZeroExit(t *testing.T) {
	t.Parallel()

	res, err := runner.Exec{}.Run(t.Context(), runner.Git, []string{"no-such-subcommand-oe"})
	if err != nil {
		t.Fatalf("Run() error = %v, want nil with a non-zero exit", err)
	}
	if res.ExitCode == 0 {
		t.Error("exit = 0, want non-zero")
	}
}

func TestExecRejectsUnknownProgram(t *testing.T) {
	t.Parallel()

	_, err := runner.Exec{}.Run(t.Context(), runner.Program("sh"), []string{"-c", "true"})
	if !errors.Is(err, runner.ErrUnknownProgram) {
		t.Errorf("Run(sh) error = %v, want ErrUnknownProgram", err)
	}
}

func writeSnapshot(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "snapshot.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSnapshotReplaysRecordedCall(t *testing.T) {
	t.Parallel()

	path := writeSnapshot(t, `{"calls":[{"argv":["gh","api","user"],"stdout":"{\"login\":\"me\"}","stderr":"","exit_code":0}]}`)
	snap, err := runner.LoadSnapshot(path)
	if err != nil {
		t.Fatalf("LoadSnapshot() error = %v", err)
	}
	for range 2 {
		res, err := snap.Run(t.Context(), runner.GH, []string{"api", "user"})
		if err != nil {
			t.Fatalf("Run() error = %v", err)
		}
		if string(res.Stdout) != `{"login":"me"}` || res.ExitCode != 0 {
			t.Errorf("Run() = %+v, want the recorded call", res)
		}
	}
}

func TestSnapshotUnrecordedCallFails(t *testing.T) {
	t.Parallel()

	snap := runner.NewSnapshot(nil)
	_, err := snap.Run(t.Context(), runner.GH, []string{"api", "user"})
	if !errors.Is(err, runner.ErrNotRecorded) {
		t.Errorf("Run() error = %v, want ErrNotRecorded", err)
	}
}

func TestLoadSnapshotRejectsBadFiles(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"malformed JSON":  `{"calls":[`,
		"unknown field":   `{"calls":[],"extra":1}`,
		"empty argv":      `{"calls":[{"argv":[],"stdout":"","stderr":"","exit_code":0}]}`,
		"unknown program": `{"calls":[{"argv":["sh","-c","x"],"stdout":"","stderr":"","exit_code":0}]}`,
		"duplicate argv": `{"calls":[{"argv":["gh","api","user"],"stdout":"a","stderr":"","exit_code":0},` +
			`{"argv":["gh","api","user"],"stdout":"b","stderr":"","exit_code":0}]}`,
		"trailing data": `{"calls":[]} {}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := runner.LoadSnapshot(writeSnapshot(t, body)); err == nil {
				t.Error("LoadSnapshot() error = nil, want an error")
			}
		})
	}
}

func TestLoadSnapshotMissingFile(t *testing.T) {
	t.Parallel()

	if _, err := runner.LoadSnapshot(filepath.Join(t.TempDir(), "absent.json")); err == nil {
		t.Error("LoadSnapshot(absent) error = nil, want an error")
	}
}
