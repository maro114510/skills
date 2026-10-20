package checks

import (
	"slices"
	"testing"
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
