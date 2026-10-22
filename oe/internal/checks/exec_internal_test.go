package checks

import (
	"slices"
	"strings"
	"testing"
	"time"
)

func TestShellArgvUsesTheCapturedShell(t *testing.T) {
	t.Parallel()

	sh := shellArgv(shellSh, "/tmp/check.sh")
	if !slices.Equal(sh, []string{"sh", "-e", "/tmp/check.sh"}) {
		t.Errorf("sh argv = %v", sh)
	}
	bash := shellArgv(shellBash, "/tmp/check.sh")
	if !slices.Equal(bash, []string{"bash", "--noprofile", "--norc", "-eo", "pipefail", "/tmp/check.sh"}) {
		t.Errorf("bash argv = %v", bash)
	}
	fallback := shellArgv("", "/tmp/check.sh")
	if !slices.Equal(fallback, []string{"bash", "-e", "/tmp/check.sh"}) {
		t.Errorf("default argv = %v", fallback)
	}
}

// A check can leave a background process holding its stdout and stderr, as `server &` does. Run
// waits for those pipes, so RunCheck must stop waiting a bounded time after the shell exits, and
// must still report the shell's own exit status: a check that exited 0 passed.
func TestRunCheckDoesNotWaitForABackgroundProcess(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		script   string
		wantExit int
	}{
		"the shell passed":  {"sleep 30 &\necho started\n", 0},
		"the shell failed":  {"sleep 30 &\necho started\nexit 3\n", 3},
		"no background job": {"echo started\n", 0},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			begun := time.Now()
			res, err := runCheck(t.Context(), Command{Dir: t.TempDir(), Env: map[string]string{}, Shell: shellBash, Script: tc.script}, 300*time.Millisecond)
			if err != nil {
				t.Fatalf("runCheck() error = %v", err)
			}
			if took := time.Since(begun); took > 10*time.Second {
				t.Errorf("took %s, want it to stop waiting for the background process", took)
			}
			if res.ExitCode != tc.wantExit || res.StartError != "" {
				t.Errorf("exit = %d, start error = %q; want exit %d and no start error", res.ExitCode, res.StartError, tc.wantExit)
			}
			if !strings.Contains(res.Stdout, "started") {
				t.Errorf("stdout = %q, want what the check printed before it stopped waiting", res.Stdout)
			}
		})
	}
}

// TestRunCheckSaysWhenItStoppedWaiting: a check whose output was cut off says so on stderr, so
// a reader does not take the shortened output for all of it.
func TestRunCheckSaysWhenItStoppedWaiting(t *testing.T) {
	t.Parallel()

	res, err := runCheck(t.Context(), Command{Dir: t.TempDir(), Env: map[string]string{}, Shell: shellBash, Script: "sleep 30 &\n"}, 300*time.Millisecond)
	if err != nil {
		t.Fatalf("runCheck() error = %v", err)
	}
	if !strings.Contains(res.Stderr, "background process") {
		t.Errorf("stderr = %q, want a note that a background process held the output", res.Stderr)
	}
	quiet, err := runCheck(t.Context(), Command{Dir: t.TempDir(), Env: map[string]string{}, Shell: shellBash, Script: "echo hi\n"}, 300*time.Millisecond)
	if err != nil || quiet.Stderr != "" {
		t.Errorf("stderr = %q (err %v), want none for a check that left nothing behind", quiet.Stderr, err)
	}
}
