package checks

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// notRun is an entry that could not start, such as one whose working directory is missing.
const notRun = -1

// statusFieldMin is the shortest `git status --porcelain -z` record: two status characters, a
// space, and at least one path byte.
const statusFieldMin = 4

// Command is one check to run: its script body, working directory, captured environment, and
// captured shell.
type Command struct {
	Dir    string
	Env    map[string]string
	Shell  string
	Script string
}

// CommandResult is a finished check process. StartError is set when it could not start.
type CommandResult struct {
	ExitCode   int
	Stdout     string
	Stderr     string
	StartError string
}

// CommandRunner runs one check command. Exec runs a real process.
type CommandRunner interface {
	RunCheck(ctx context.Context, cmd Command) (CommandResult, error)
}

// Result is one runnable entry's outcome.
type Result struct {
	File             string   `json:"file"`
	Job              string   `json:"job"`
	Step             string   `json:"step"`
	StepIndex        int      `json:"step_index"`
	Command          string   `json:"command"`
	WorkingDirectory string   `json:"working_directory"`
	ExitCode         int      `json:"exit_code"`
	Passed           bool     `json:"passed"`
	Stdout           string   `json:"stdout"`
	Stderr           string   `json:"stderr"`
	Error            string   `json:"error"`
	ChangedPaths     []string `json:"changed_paths"`
}

// Report is the outcome of running every runnable entry in a set. It carries the revision it
// belongs to, so a caller can tell whether it is still valid.
type Report struct {
	Ref          string   `json:"ref"`
	Revision     string   `json:"revision"`
	OK           bool     `json:"ok"`
	Results      []Result `json:"results"`
	ChangedPaths []string `json:"changed_paths"`
}

// worktreeState is the index and worktree as git reports it, used to detect a check's side
// effects.
type worktreeState struct {
	paths    map[string]string
	contents map[string]string
}

// RunSet runs every runnable entry of set in worktree, each in its own process, and reports each
// outcome and every change it made to the worktree or index. A requires-runner entry is never
// executed. RunSet exits Stale when set.Ref no longer resolves to set.Revision.
func RunSet(ctx context.Context, git GitReader, runner CommandRunner, worktree string, set Set) (Report, error) {
	if err := verifyRevision(ctx, git, worktree, set); err != nil {
		return Report{}, err
	}
	state, err := readState(ctx, git, worktree)
	if err != nil {
		return Report{}, err
	}
	report := Report{Ref: set.Ref, Revision: set.Revision, OK: true, Results: []Result{}, ChangedPaths: []string{}}
	changed := map[string]bool{}
	for _, entry := range set.Entries {
		if !entry.Runnable {
			continue
		}
		result, after, paths, err := runEntry(ctx, git, runner, worktree, state, entry)
		if err != nil {
			return Report{}, err
		}
		state = after
		if !result.Passed {
			report.OK = false
		}
		for _, path := range paths {
			changed[path] = true
		}
		report.Results = append(report.Results, result)
	}
	report.ChangedPaths = sortedKeys(changed)
	return report, nil
}

// verifyRevision binds the set to the ref it was derived from. A moved ref invalidates it.
func verifyRevision(ctx context.Context, git GitReader, worktree string, set Set) error {
	if set.Ref == "" || set.Revision == "" {
		return exitcode.New(exitcode.Usage, "CHECKS_SET has no ref or revision")
	}
	head, err := resolveRef(ctx, git, worktree, set.Ref)
	if err != nil {
		return err
	}
	if head != set.Revision {
		return exitcode.New(exitcode.Stale,
			fmt.Sprintf("%s moved from %s to %s since the set was derived; re-derive CHECKS_SET", set.Ref, short(set.Revision), short(head)))
	}
	return nil
}

func resolveRef(ctx context.Context, git GitReader, worktree, ref string) (string, error) {
	out, err := git.Git(ctx, "-C", worktree, "rev-parse", "--verify", ref+"^{commit}")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// runEntry runs one entry and returns its result, the state it left behind, and the paths it
// changed.
func runEntry(ctx context.Context, git GitReader, runner CommandRunner, worktree string, before worktreeState, entry Entry) (Result, worktreeState, []string, error) {
	result := Result{
		File: entry.File, Job: entry.Job, Step: entry.Step, StepIndex: entry.StepIndex,
		Command: entry.Command, WorkingDirectory: entry.WorkingDirectory, ExitCode: notRun,
		Passed: false, Stdout: "", Stderr: "", Error: "", ChangedPaths: []string{},
	}
	dir, err := resolveDir(worktree, entry.WorkingDirectory)
	if err != nil {
		// A missing or escaping directory fails this entry, not the whole run.
		result.Error = err.Error()
		return result, before, nil, nil //nolint:nilerr // The error is reported in the entry result.
	}
	out, err := runner.RunCheck(ctx, Command{Dir: dir, Env: entry.Env, Shell: entry.Shell, Script: entry.Command})
	if err != nil {
		return Result{}, before, nil, err
	}
	result.ExitCode = out.ExitCode
	result.Stdout = out.Stdout
	result.Stderr = out.Stderr
	result.Error = out.StartError
	result.Passed = out.ExitCode == 0 && out.StartError == ""
	after, err := readState(ctx, git, worktree)
	if err != nil {
		return Result{}, before, nil, err
	}
	paths := changedPaths(before, after)
	result.ChangedPaths = paths
	return result, after, paths, nil
}

// resolveDir resolves a captured working directory inside the worktree, rejecting one that is
// absolute or escapes the worktree.
func resolveDir(root, rel string) (string, error) {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("resolve worktree %s: %w", root, err)
	}
	realRoot, err := filepath.EvalSymlinks(absRoot)
	if err != nil {
		return "", fmt.Errorf("resolve worktree %s: %w", root, err)
	}
	if rel == "" {
		return realRoot, nil
	}
	if filepath.IsAbs(rel) {
		return "", fmt.Errorf("working-directory %q is absolute", rel)
	}
	dir, err := filepath.EvalSymlinks(filepath.Join(realRoot, rel))
	if err != nil {
		return "", fmt.Errorf("working-directory %q does not exist", rel)
	}
	if err := inside(realRoot, dir); err != nil {
		return "", fmt.Errorf("working-directory %q escapes the worktree", rel)
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("working-directory %q does not exist", rel)
	}
	return dir, nil
}

// inside reports whether dir stays under root after symlink resolution.
func inside(root, dir string) error {
	back, err := filepath.Rel(root, dir)
	if err != nil || back == ".." || strings.HasPrefix(back, ".."+string(filepath.Separator)) {
		return errors.New("path escapes the worktree")
	}
	return nil
}

func readState(ctx context.Context, git GitReader, dir string) (worktreeState, error) {
	status, err := git.Git(ctx, "-C", dir, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return worktreeState{}, err
	}
	paths := parseStatus(status)
	contents, err := hashContents(dir, paths)
	if err != nil {
		return worktreeState{}, err
	}
	return worktreeState{paths: paths, contents: contents}, nil
}

// hashContents records each listed file's content, so a check that edits an already-dirty or
// already-untracked file is still reported even though its status code does not change.
func hashContents(dir string, paths map[string]string) (map[string]string, error) {
	hashes := map[string]string{}
	for path := range paths {
		hash, err := hashFile(filepath.Join(dir, path))
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				hashes[path] = "deleted"
				continue
			}
			return nil, err
		}
		hashes[path] = hash
	}
	return hashes, nil
}

func hashFile(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("stat %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		target := info.Mode().String()
		if info.Mode()&os.ModeSymlink != 0 {
			if target, err = os.Readlink(path); err != nil {
				return "", fmt.Errorf("readlink %s: %w", path, err)
			}
		}
		sum := sha256.Sum256([]byte(target))
		return hex.EncodeToString(sum[:]), nil
	}
	file, err := os.Open(path) //nolint:gosec // The path comes from git status inside the worktree.
	if err != nil {
		return "", fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()
	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", fmt.Errorf("hash %s: %w", path, err)
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

// parseStatus reads `git status --porcelain=v1 -z` records into path-to-code.
func parseStatus(out []byte) map[string]string {
	paths := map[string]string{}
	fields := bytes.Split(out, []byte{0})
	for i := 0; i < len(fields); i++ {
		field := fields[i]
		if len(field) < statusFieldMin {
			continue
		}
		code := string(field[:2])
		paths[string(field[3:])] = code
		if strings.ContainsAny(code, "RC") {
			i++ // A rename or copy record names its source on the next record.
		}
	}
	return paths
}

// changedPaths reports the paths whose status changed and, when only an already-dirty file's
// content changed, the dirty paths it could be.
func changedPaths(before, after worktreeState) []string {
	changed := map[string]bool{}
	for path, code := range after.paths {
		if before.paths[path] != code {
			changed[path] = true
		}
	}
	for path := range before.paths {
		if _, ok := after.paths[path]; !ok {
			changed[path] = true
		}
	}
	for path, hash := range after.contents {
		if before.contents[path] != hash {
			changed[path] = true
		}
	}
	for path := range before.contents {
		if _, ok := after.contents[path]; !ok {
			changed[path] = true
		}
	}
	return sortedKeys(changed)
}

func sortedKeys(set map[string]bool) []string {
	return slices.Sorted(maps.Keys(set))
}

func short(sha string) string {
	const shortSHA = 12
	if len(sha) <= shortSHA {
		return sha
	}
	return sha[:shortSHA]
}

// pipeWait is how long RunCheck waits for a check's output after its shell has exited. A check
// that starts a background process, as `server &` does, leaves that process holding the output
// pipes, and the shell's exit would otherwise not end the wait.
const pipeWait = 10 * time.Second

// Exec runs each check as a real process through bash or sh.
type Exec struct{}

// RunCheck writes the script to a private temporary file and runs it with the captured shell. The
// command is never interpolated into a shell string.
func (Exec) RunCheck(ctx context.Context, cmd Command) (CommandResult, error) {
	return runCheck(ctx, cmd, pipeWait)
}

func runCheck(ctx context.Context, cmd Command, wait time.Duration) (CommandResult, error) {
	file, err := os.CreateTemp("", "oe-check-*.sh")
	if err != nil {
		return CommandResult{}, exitcode.Wrap(exitcode.Unreadable, err, "create the check script")
	}
	path := file.Name()
	defer func() { _ = os.Remove(path) }()
	if _, err := file.WriteString(cmd.Script); err != nil {
		_ = file.Close()
		return CommandResult{}, exitcode.Wrap(exitcode.Unreadable, err, "write the check script")
	}
	if err := file.Close(); err != nil {
		return CommandResult{}, exitcode.Wrap(exitcode.Unreadable, err, "write the check script")
	}
	argv := shellArgv(cmd.Shell, path)
	proc := exec.CommandContext(ctx, argv[0], argv[1:]...) //nolint:gosec // argv[0] is bash or sh from a fixed switch; no shell string is interpolated.
	proc.Dir = cmd.Dir
	proc.Env = mergedEnv(cmd.Env)
	var stdout, stderr bytes.Buffer
	proc.Stdout = &stdout
	proc.Stderr = &stderr
	proc.WaitDelay = wait
	err = proc.Run()
	result := CommandResult{ExitCode: 0, Stdout: stdout.String(), Stderr: stderr.String(), StartError: ""}
	if err != nil {
		if exitErr, ok := errors.AsType[*exec.ExitError](err); ok {
			result.ExitCode = exitErr.ExitCode()
			return result, nil
		}
		if errors.Is(err, exec.ErrWaitDelay) {
			// Run reports this only when the shell itself exited 0, so the check passed. What a
			// background process printed afterwards is not part of the result.
			result.Stderr += backgroundNote
			return result, nil
		}
		result.ExitCode = notRun
		result.StartError = err.Error()
	}
	return result, nil
}

// backgroundNote tells a reader that a check's output was cut short.
const backgroundNote = "oe: a background process still held the check's output after its shell exited; later output is not shown\n"

// shellArgv maps a captured shell to the argv GitHub Actions would use. Only bash, sh, and an
// unset shell are runnable; every other shell is a requires-runner entry that never reaches here.
func shellArgv(shell, script string) []string {
	switch shell {
	case shellSh:
		return []string{shellSh, "-e", script}
	case shellBash:
		return []string{shellBash, "--noprofile", "--norc", "-eo", "pipefail", script}
	default:
		return []string{shellBash, "-e", script}
	}
}

// mergedEnv is the process environment with the entry's captured env applied on top.
// mergedEnv builds the check environment. GH_HOST and GH_REPO never reach a check, so a `gh`
// call inside one cannot target another host or repository; GH_HOST is pinned to github.com.
func mergedEnv(extra map[string]string) []string {
	env := map[string]string{}
	for _, kv := range os.Environ() {
		name, value, _ := strings.Cut(kv, "=")
		if name == "GH_HOST" || name == "GH_REPO" {
			continue
		}
		env[name] = value
	}
	for name, value := range extra {
		if name == "GH_HOST" || name == "GH_REPO" {
			continue
		}
		env[name] = value
	}
	env["GH_HOST"] = "github.com"
	out := make([]string, 0, len(env))
	for _, name := range slices.Sorted(maps.Keys(env)) {
		out = append(out, name+"="+env[name])
	}
	return out
}
