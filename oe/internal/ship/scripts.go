package ship

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/runner"
)

// The create-pr skill's scripts, by file name.
const (
	createScript = "create-linked-pr.sh"
	refsScript   = "issue-refs.sh"
)

// Scripts are the create-pr skill's scripts.
type Scripts struct {
	Create string
	Refs   string
}

// ResolveScripts finds both scripts in the create-pr skill's scripts directory.
// The directory is an absolute path, since the scripts run from the worktree.
func ResolveScripts(dir string) (Scripts, error) {
	if !filepath.IsAbs(dir) {
		return Scripts{Create: "", Refs: ""}, exitcode.New(exitcode.Refused, "--create-pr-scripts must be the absolute path of the create-pr skill's scripts directory")
	}
	s := Scripts{Create: filepath.Join(dir, createScript), Refs: filepath.Join(dir, refsScript)}
	for _, p := range []string{s.Create, s.Refs} {
		if st, err := os.Stat(p); err != nil || !st.Mode().IsRegular() {
			return Scripts{Create: "", Refs: ""}, exitcode.New(exitcode.Refused, "the create-pr scripts directory lacks "+filepath.Base(p))
		}
	}
	return s, nil
}

// CreateArgs are the arguments that open a pull request.
func CreateArgs(repo, head, base, title, bodyFile string) []string {
	return []string{"--repo", repo, "--head", head, "--base", base, "--title", title, "--body-file", bodyFile}
}

// LinkArgs are the arguments that link an existing pull request to its Issues.
func LinkArgs(repo string, pr int) []string {
	return []string{"--repo", repo, "--link", strconv.Itoa(pr)}
}

// Script is one script run: its path, arguments, and working directory.
type Script struct {
	Path string
	Args []string
	Dir  string
}

// ScriptResult is a finished script. A non-zero ExitCode is a result, not an error.
type ScriptResult struct {
	ExitCode int
	Stdout   string
	Stderr   string
}

// ScriptRunner runs a script. Exec runs a real process.
type ScriptRunner interface {
	RunScript(ctx context.Context, s Script) (ScriptResult, error)
}

// Exec runs a script with bash, as an argv array and never through a shell string.
type Exec struct{}

// RunScript implements ScriptRunner. It returns an error only when the process cannot run.
func (Exec) RunScript(ctx context.Context, s Script) (ScriptResult, error) {
	cmd := exec.CommandContext(ctx, "bash", append([]string{s.Path}, s.Args...)...) //nolint:gosec // G204: a fixed program, and the script is a resolved create-pr script.
	cmd.Dir = s.Dir
	cmd.Env = runner.Environ()
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	res := ScriptResult{ExitCode: 0, Stdout: "", Stderr: ""}
	err := cmd.Run()
	res.Stdout, res.Stderr = stdout.String(), stderr.String()
	if err != nil {
		if exitErr, ok := errors.AsType[*exec.ExitError](err); ok {
			res.ExitCode = exitErr.ExitCode()
			return res, nil
		}
		return res, fmt.Errorf("run %s: %w", filepath.Base(s.Path), err)
	}
	return res, nil
}
