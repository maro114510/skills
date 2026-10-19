// Package runner runs the external programs oe depends on, gh and git, always as an argv
// array and never through a shell, or replays them from a recorded snapshot.
package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// Program is an external program oe may run. Only the constants below are accepted.
type Program string

// The programs oe runs.
const (
	GH  Program = "gh"
	Git Program = "git"
)

// ErrUnknownProgram rejects any program other than gh and git.
var ErrUnknownProgram = errors.New("unknown program")

// ErrNotRecorded is returned by a snapshot for a call it holds no response for.
var ErrNotRecorded = errors.New("call not recorded in snapshot")

// Result is a finished call. A non-zero ExitCode is a result, not an error.
type Result struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
}

// Runner runs one program with arguments.
type Runner interface {
	Run(ctx context.Context, prog Program, args []string) (Result, error)
}

// Exec runs real processes.
type Exec struct{}

// Run starts prog with args as separate argv elements. It returns an error only when the
// process cannot run at all.
func (Exec) Run(ctx context.Context, prog Program, args []string) (Result, error) {
	var cmd *exec.Cmd
	switch prog {
	// The program is a literal and args are argv elements, never a shell string.
	case GH:
		cmd = exec.CommandContext(ctx, "gh", args...) //nolint:gosec // G204: fixed program, argv only.
	case Git:
		cmd = exec.CommandContext(ctx, "git", args...) //nolint:gosec // G204: fixed program, argv only.
	default:
		return Result{}, fmt.Errorf("%w: %q", ErrUnknownProgram, prog)
	}
	cmd.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", "GIT_TERMINAL_PROMPT=0")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	res := Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), ExitCode: 0}
	if err != nil {
		if exitErr, ok := errors.AsType[*exec.ExitError](err); ok {
			res.ExitCode = exitErr.ExitCode()
			return res, nil
		}
		return res, fmt.Errorf("run %s: %w", prog, err)
	}
	return res, nil
}

// Call is one recorded invocation. Argv starts with the program name.
type Call struct {
	Argv     []string `json:"argv"`
	Stdout   string   `json:"stdout"`
	Stderr   string   `json:"stderr"`
	ExitCode int      `json:"exit_code"`
}

type snapshotFile struct {
	Calls []Call `json:"calls"`
}

// Snapshot replays recorded calls and never starts a process, so it cannot reach the network.
type Snapshot struct {
	calls map[string]Call
}

// NewSnapshot builds a snapshot from calls. A later duplicate replaces an earlier one; use
// LoadSnapshot for a file, which rejects duplicates.
func NewSnapshot(calls []Call) *Snapshot {
	s := &Snapshot{calls: make(map[string]Call, len(calls))}
	for _, c := range calls {
		s.calls[key(c.Argv)] = c
	}
	return s
}

// LoadSnapshot reads a snapshot file of the form {"calls":[{argv, stdout, stderr, exit_code}]}.
// Unknown fields, trailing data, an empty argv, an unknown program, or a duplicate argv fail.
func LoadSnapshot(path string) (*Snapshot, error) {
	data, err := os.ReadFile(path) //nolint:gosec // The snapshot path is an explicit operator argument.
	if err != nil {
		return nil, fmt.Errorf("read snapshot: %w", err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var f snapshotFile
	if err := dec.Decode(&f); err != nil {
		return nil, fmt.Errorf("parse snapshot %s: %w", path, err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("parse snapshot %s: trailing data after the object", path)
	}
	seen := make(map[string]bool, len(f.Calls))
	for i, c := range f.Calls {
		if len(c.Argv) == 0 {
			return nil, fmt.Errorf("snapshot %s: call %d has an empty argv", path, i)
		}
		if p := Program(c.Argv[0]); p != GH && p != Git {
			return nil, fmt.Errorf("snapshot %s: call %d: %w: %q", path, i, ErrUnknownProgram, c.Argv[0])
		}
		k := key(c.Argv)
		if seen[k] {
			return nil, fmt.Errorf("snapshot %s: call %d duplicates argv %q", path, i, c.Argv)
		}
		seen[k] = true
	}
	return NewSnapshot(f.Calls), nil
}

// Run returns the recorded response for prog and args, or ErrNotRecorded.
func (s *Snapshot) Run(_ context.Context, prog Program, args []string) (Result, error) {
	argv := append([]string{string(prog)}, args...)
	c, ok := s.calls[key(argv)]
	if !ok {
		return Result{}, fmt.Errorf("%w: %q", ErrNotRecorded, argv)
	}
	return Result{Stdout: []byte(c.Stdout), Stderr: []byte(c.Stderr), ExitCode: c.ExitCode}, nil
}

// key joins argv with NUL, which no argument can contain.
func key(argv []string) string { return strings.Join(argv, "\x00") }
