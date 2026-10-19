package cmd_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/maro114510/skills/oe/cmd"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/runner"
)

// spy stands in for the real process runner and records every call.
type spy struct {
	mu    sync.Mutex
	inner runner.Runner
	calls [][]string
}

func (s *spy) Run(ctx context.Context, prog runner.Program, args []string) (runner.Result, error) {
	s.mu.Lock()
	s.calls = append(s.calls, append([]string{string(prog)}, args...))
	s.mu.Unlock()
	return s.inner.Run(ctx, prog, args)
}

func (s *spy) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.calls)
}

const probeOK = `{"data":{"repository":{"defaultBranchRef":{"name":"main"},` +
	`"issue":{"number":277,"subIssues":{"totalCount":16},"blockedBy":{"totalCount":0}}}}}`

const probePartial = `{"data":{"repository":{"defaultBranchRef":{"name":"main"},"issue":null}},` +
	`"errors":[{"type":"NOT_FOUND","message":"Could not resolve to an Issue with the number of 277."}]}`

func healthy(probeBody string, probeExit int) []runner.Call {
	return []runner.Call{
		{Argv: []string{"gh", "--version"}, Stdout: "gh version 2.102.0 (2026-09-30)\n", Stderr: "", ExitCode: 0},
		{Argv: []string{"gh", "auth", "status", "--hostname", "github.com"}, Stdout: "", Stderr: "", ExitCode: 0},
		{Argv: []string{"gh", "api", "user"}, Stdout: `{"login":"maro114510"}`, Stderr: "", ExitCode: 0},
		{Argv: []string{"git", "remote", "get-url", "origin"}, Stdout: "https://github.com/maro114510/skills.git\n", Stderr: "", ExitCode: 0},
		{
			Argv: []string{
				"gh", "api", "graphql", "-f", "query=" + inputs.ProbeQuery,
				"-f", "owner=maro114510", "-f", "name=skills", "-F", "epic=277",
			},
			Stdout: probeBody, Stderr: "", ExitCode: probeExit,
		},
	}
}

type result struct {
	code   int
	stdout string
	stderr string
}

func run(exec runner.Runner, args ...string) result {
	var out, errOut bytes.Buffer
	code := cmd.Main(args, cmd.Env{Stdout: &out, Stderr: &errOut, Exec: exec, Version: "v1.2.3"})
	return result{code: code, stdout: out.String(), stderr: errOut.String()}
}

func newSpy(calls []runner.Call) *spy {
	return &spy{mu: sync.Mutex{}, inner: runner.NewSnapshot(calls), calls: nil}
}

func writeSnapshot(t *testing.T, calls []runner.Call) string {
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

func wantOneLine(t *testing.T, r result, code int, contains string) {
	t.Helper()
	if r.code != code {
		t.Errorf("exit = %d, want %d; stdout = %q", r.code, code, r.stdout)
	}
	if strings.Count(r.stdout, "\n") != 1 || !strings.Contains(r.stdout, contains) {
		t.Errorf("stdout = %q, want one verdict line containing %q", r.stdout, contains)
	}
}

func TestUsageErrors(t *testing.T) {
	t.Parallel()

	tests := map[string][]string{
		"no subcommand":      {},
		"unknown subcommand": {"bogus"},
		"unknown flag":       {"resolve", "--bogus"},
		"stray argument":     {"resolve", "extra"},
		"bare group":         {"ship"},
	}
	for name, args := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			s := newSpy(nil)
			wantOneLine(t, run(s, args...), 2, "usage:")
			if s.count() != 0 {
				t.Errorf("calls = %d, want none", s.count())
			}
		})
	}
}

func TestVersion(t *testing.T) {
	t.Parallel()

	for _, args := range [][]string{{"--version"}, {"version"}} {
		r := run(newSpy(nil), args...)
		if r.code != 0 || r.stdout != "v1.2.3\n" {
			t.Errorf("%v: exit %d, stdout %q; want 0, v1.2.3", args, r.code, r.stdout)
		}
	}
}

func TestResolvePrintsJSON(t *testing.T) {
	t.Parallel()

	r := run(newSpy(healthy(probeOK, 0)), "resolve", "--epic", "277")
	want := `{"repo":"maro114510/skills","epic":277,"me":"maro114510","default_branch":"main",` +
		`"max_parallel":3,"max_parallel_reason":"","gh_version":"2.102.0"}` + "\n"
	if r.code != 0 || r.stdout != want {
		t.Errorf("exit %d, stdout %q; want 0, %q", r.code, r.stdout, want)
	}
}

func TestResolveWithoutEpicNeverGuesses(t *testing.T) {
	t.Parallel()

	s := newSpy(healthy(probeOK, 0))
	wantOneLine(t, run(s, "resolve"), 2, "never guesses")
	if s.count() != 0 {
		t.Errorf("calls = %d, want none", s.count())
	}
}

func TestResolveMaxParallelFallback(t *testing.T) {
	t.Parallel()

	for _, raw := range []string{"0", "abc"} {
		r := run(newSpy(healthy(probeOK, 0)), "resolve", "--epic", "277", "--max-parallel", raw)
		if r.code != 0 || !strings.Contains(r.stdout, `"max_parallel":3`) {
			t.Errorf("max-parallel %s: exit %d, stdout %q; want cap 3", raw, r.code, r.stdout)
		}
		if !strings.Contains(r.stderr, "not a positive integer") || !strings.Contains(r.stdout, "not a positive integer") {
			t.Errorf("max-parallel %s: stderr %q, stdout %q; want the reason printed", raw, r.stderr, r.stdout)
		}
	}
}

// TestSnapshotResolveIsReproducible runs the read-only resolve twice over one snapshot: the
// output is identical and no real call is made.
func TestSnapshotResolveIsReproducible(t *testing.T) {
	t.Parallel()

	path := writeSnapshot(t, healthy(probeOK, 0))
	s := newSpy(nil)
	first := run(s, "--snapshot", path, "resolve", "--epic", "277")
	second := run(s, "--snapshot", path, "resolve", "--epic", "277")
	if first.code != 0 || first != second {
		t.Errorf("runs differ or failed: %+v vs %+v", first, second)
	}
	if s.count() != 0 {
		t.Errorf("real calls = %d, want none under --snapshot", s.count())
	}
}

// TestEmptySnapshotIsUsage: an empty --snapshot, as from an unset variable, never falls back
// to real calls.
func TestEmptySnapshotIsUsage(t *testing.T) {
	t.Parallel()

	for _, args := range [][]string{
		{"--snapshot=", "resolve", "--epic", "277"},
		{"--snapshot", "", "resolve", "--epic", "277"},
		{"--snapshot=", "--epic", "277", "ship", "publish"},
		{"--snapshot=", "--epic", "277", "land", "merge"},
	} {
		s := newSpy(healthy(probeOK, 0))
		wantOneLine(t, run(s, args...), 2, "--snapshot needs a file path")
		if s.count() != 0 {
			t.Errorf("%q: calls = %d, want none", args, s.count())
		}
	}
}

func TestSnapshotUnusableIsUsage(t *testing.T) {
	t.Parallel()

	r := run(newSpy(nil), "--snapshot", filepath.Join(t.TempDir(), "absent.json"), "resolve", "--epic", "277")
	wantOneLine(t, r, 2, "--snapshot")
}

func TestSnapshotUnrecordedCallIsUnreadable(t *testing.T) {
	t.Parallel()

	path := writeSnapshot(t, healthy(probeOK, 0)[:2])
	wantOneLine(t, run(newSpy(nil), "--snapshot", path, "resolve", "--epic", "277"), 1, "unreadable:")
}

func mutating() [][]string { return [][]string{{"ship", "publish"}, {"land", "merge"}} }

// TestMutatingRefusesUnderSnapshot: every mutating subcommand exits non-zero under
// --snapshot without any call, even when the snapshot would answer every read.
func TestMutatingRefusesUnderSnapshot(t *testing.T) {
	t.Parallel()

	path := writeSnapshot(t, healthy(probeOK, 0))
	for _, sub := range mutating() {
		s := newSpy(healthy(probeOK, 0))
		r := run(s, append([]string{"--snapshot", path, "--epic", "277"}, sub...)...)
		wantOneLine(t, r, 8, "--snapshot disables every mutation")
		if s.count() != 0 {
			t.Errorf("%v: calls = %d, want none", sub, s.count())
		}
	}
}

// TestMutatingRefusesOnPartialGraphQL: a GraphQL response carrying data and errors makes every
// mutating subcommand exit non-zero, and only reads were attempted.
func TestMutatingRefusesOnPartialGraphQL(t *testing.T) {
	t.Parallel()

	for _, sub := range mutating() {
		s := newSpy(healthy(probePartial, 1))
		r := run(s, append([]string{"--epic", "277"}, sub...)...)
		wantOneLine(t, r, 1, "partial")
		reads := map[string]bool{}
		for _, c := range healthy(probePartial, 1) {
			reads[strings.Join(c.Argv, "\x00")] = true
		}
		for _, c := range s.calls {
			if !reads[strings.Join(c, "\x00")] {
				t.Errorf("%v: call %q is not one of the resolution reads", sub, c)
			}
		}
	}
}

func TestMutatingNotYetImplemented(t *testing.T) {
	t.Parallel()

	for _, sub := range mutating() {
		r := run(newSpy(healthy(probeOK, 0)), append([]string{"--epic", "277"}, sub...)...)
		wantOneLine(t, r, 8, "not implemented")
	}
}
