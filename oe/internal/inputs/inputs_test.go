package inputs_test

import (
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/runner"
)

type spy struct {
	mu    sync.Mutex
	inner runner.Runner
	calls int
}

func (s *spy) Run(ctx context.Context, prog runner.Program, args []string) (runner.Result, error) {
	s.mu.Lock()
	s.calls++
	s.mu.Unlock()
	return s.inner.Run(ctx, prog, args)
}

const probeOK = `{"data":{"repository":{"defaultBranchRef":{"name":"main"},` +
	`"issue":{"number":277,"subIssues":{"totalCount":16},"blockedBy":{"totalCount":0}}}}}`

func call(stdout string, exit int, argv ...string) runner.Call {
	return runner.Call{Argv: argv, Stdout: stdout, Stderr: "", ExitCode: exit}
}

func probe(stdout string, exit int) runner.Call {
	return call(stdout, exit, "gh", "api", "graphql", "-f", "query="+inputs.ProbeQuery,
		"-f", "owner=maro114510", "-f", "name=skills", "-F", "epic=277")
}

// world returns a full set of healthy responses, with any override replacing its argv.
func world(overrides ...runner.Call) *spy {
	calls := make([]runner.Call, 0, 5+len(overrides))
	calls = append(calls,
		call("gh version 2.102.0 (2026-09-30)\nhttps://github.com/cli/cli/releases/tag/v2.102.0\n", 0, "gh", "--version"),
		call("", 0, "gh", "auth", "status", "--hostname", "github.com"),
		call(`{"login":"maro114510"}`, 0, "gh", "api", "user"),
		call("git@github.com:maro114510/skills.git\n", 0, "git", "remote", "get-url", "origin"),
		probe(probeOK, 0),
	)
	calls = append(calls, overrides...) // NewSnapshot keeps the later duplicate.
	return &spy{mu: sync.Mutex{}, inner: runner.NewSnapshot(calls), calls: 0}
}

func resolve(t *testing.T, s *spy, args inputs.Args) (inputs.Inputs, error) {
	t.Helper()
	return inputs.Resolve(t.Context(), gh.New(s, false), args)
}

func epic(n string) inputs.Args {
	return inputs.Args{Repo: "", Epic: n, MaxParallel: "", MaxParallelSet: false}
}

func TestResolveHappyPath(t *testing.T) {
	t.Parallel()

	got, err := resolve(t, world(), epic("277"))
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	want := inputs.Inputs{
		Repo: "maro114510/skills", Epic: 277, Me: "maro114510", DefaultBranch: "main",
		MaxParallel: 3, MaxParallelReason: "", GHVersion: "2.102.0",
	}
	if got != want {
		t.Errorf("Resolve() = %+v, want %+v", got, want)
	}
}

// TestRepoDefaultsToOrigin guards IN-01: without --repo, the repo comes from origin.
func TestRepoDefaultsToOrigin(t *testing.T) {
	t.Parallel()

	remotes := map[string]string{
		"https":      "https://github.com/maro114510/skills.git",
		"https bare": "https://github.com/maro114510/skills",
		"scp ssh":    "git@github.com:maro114510/skills.git",
		"ssh url":    "ssh://git@github.com/maro114510/skills.git",
	}
	for name, url := range remotes {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got, err := resolve(t, world(call(url+"\n", 0, "git", "remote", "get-url", "origin")), epic("277"))
			if err != nil || got.Repo != "maro114510/skills" {
				t.Errorf("Resolve() repo = %q, err = %v; want maro114510/skills", got.Repo, err)
			}
		})
	}
}

func TestRepoArgumentWinsOverOrigin(t *testing.T) {
	t.Parallel()

	args := epic("277")
	args.Repo = "maro114510/skills"
	s := world(call("", 2, "git", "remote", "get-url", "origin"))
	if got, err := resolve(t, s, args); err != nil || got.Repo != "maro114510/skills" {
		t.Errorf("Resolve() = %+v, %v; want the argument repo without reading origin", got, err)
	}
}

func TestOriginFailures(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		call runner.Call
		want exitcode.Code
	}{
		"no origin":         {call: call("", 2, "git", "remote", "get-url", "origin"), want: exitcode.Unreadable},
		"non-GitHub origin": {call: call("https://gitlab.com/a/b.git\n", 0, "git", "remote", "get-url", "origin"), want: exitcode.Refused},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := resolve(t, world(tt.call), epic("277"))
			if exitcode.CodeOf(err) != tt.want {
				t.Errorf("CodeOf(err) = %d, want %d; err = %v", exitcode.CodeOf(err), tt.want, err)
			}
		})
	}
}

func TestBadRepoArgumentIsUsage(t *testing.T) {
	t.Parallel()

	for _, repo := range []string{"noslash", "a/b/c", "a b/c", "/b"} {
		args := epic("277")
		args.Repo = repo
		s := world()
		if _, err := resolve(t, s, args); exitcode.CodeOf(err) != exitcode.Usage || s.calls != 0 {
			t.Errorf("repo %q: code %d, calls %d; want Usage before any call", repo, exitcode.CodeOf(err), s.calls)
		}
	}
}

// TestEpicIsNeverGuessed guards IN-02: without an Epic the command stops before any call.
func TestEpicIsNeverGuessed(t *testing.T) {
	t.Parallel()

	for _, raw := range []string{"", "0", "-3", "abc", "https://github.com/maro114510/skills/pull/3", "https://example.com/a/b/issues/3"} {
		s := world()
		_, err := resolve(t, s, epic(raw))
		if exitcode.CodeOf(err) != exitcode.Usage {
			t.Errorf("epic %q: code = %d, want Usage; err = %v", raw, exitcode.CodeOf(err), err)
		}
		if s.calls != 0 {
			t.Errorf("epic %q: %d calls, want none", raw, s.calls)
		}
	}
	_, err := resolve(t, world(), epic(""))
	if err == nil || !strings.Contains(err.Error(), "never guesses") {
		t.Errorf("err = %v, want it to say oe never guesses an Epic", err)
	}
}

func TestEpicURLSetsRepo(t *testing.T) {
	t.Parallel()

	s := world(call("", 2, "git", "remote", "get-url", "origin"))
	got, err := resolve(t, s, epic("https://github.com/maro114510/skills/issues/277"))
	if err != nil || got.Epic != 277 || got.Repo != "maro114510/skills" {
		t.Errorf("Resolve() = %+v, %v; want epic 277 in maro114510/skills", got, err)
	}
}

func TestEpicURLConflictingRepoIsUsage(t *testing.T) {
	t.Parallel()

	args := epic("https://github.com/maro114510/skills/issues/277")
	args.Repo = "other/repo"
	if _, err := resolve(t, world(), args); exitcode.CodeOf(err) != exitcode.Usage {
		t.Errorf("code = %d, want Usage", exitcode.CodeOf(err))
	}
}

// TestMaxParallelFallback guards IN-04: an invalid cap falls back to 3 and says why.
func TestMaxParallelFallback(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		raw        string
		set        bool
		want       int
		wantReason bool
	}{
		"unset":         {raw: "", set: false, want: 3, wantReason: false},
		"valid":         {raw: "5", set: true, want: 5, wantReason: false},
		"zero":          {raw: "0", set: true, want: 3, wantReason: true},
		"negative":      {raw: "-2", set: true, want: 3, wantReason: true},
		"non-numeric":   {raw: "abc", set: true, want: 3, wantReason: true},
		"empty but set": {raw: "", set: true, want: 3, wantReason: true},
		"fraction":      {raw: "1.5", set: true, want: 3, wantReason: true},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			args := epic("277")
			args.MaxParallel, args.MaxParallelSet = tt.raw, tt.set
			got, err := resolve(t, world(), args)
			if err != nil {
				t.Fatalf("Resolve() error = %v", err)
			}
			if got.MaxParallel != tt.want {
				t.Errorf("MaxParallel = %d, want %d", got.MaxParallel, tt.want)
			}
			if hasReason := got.MaxParallelReason != ""; hasReason != tt.wantReason {
				t.Errorf("MaxParallelReason = %q, want reason: %v", got.MaxParallelReason, tt.wantReason)
			}
			if tt.wantReason && !strings.Contains(got.MaxParallelReason, "3") {
				t.Errorf("MaxParallelReason = %q, want it to name the fallback 3", got.MaxParallelReason)
			}
		})
	}
}

func TestGHVersionFloor(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		out  string
		want exitcode.Code
	}{
		"below the floor": {out: "gh version 2.39.9 (2023-01-01)\n", want: exitcode.Refused},
		"major 1":         {out: "gh version 1.14.0 (2021-01-01)\n", want: exitcode.Refused},
		"at the floor":    {out: "gh version 2.40.0 (2023-12-01)\n", want: exitcode.OK},
		"unparseable":     {out: "something else\n", want: exitcode.Unreadable},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := resolve(t, world(call(tt.out, 0, "gh", "--version")), epic("277"))
			if exitcode.CodeOf(err) != tt.want {
				t.Errorf("code = %d, want %d; err = %v", exitcode.CodeOf(err), tt.want, err)
			}
		})
	}
}

// TestGHAuthIsConfirmed guards IN-05: a failing gh auth status stops resolution.
func TestGHAuthIsConfirmed(t *testing.T) {
	t.Parallel()

	_, err := resolve(t, world(call("", 1, "gh", "auth", "status", "--hostname", "github.com")), epic("277"))
	if exitcode.CodeOf(err) != exitcode.Refused || !strings.Contains(err.Error(), "gh auth") {
		t.Errorf("err = %v, want Refused naming gh auth", err)
	}
}

func TestGHAuthTransientFailureIsUnreadable(t *testing.T) {
	t.Parallel()

	limited := runner.Call{
		Argv:   []string{"gh", "auth", "status", "--hostname", "github.com"},
		Stdout: "", Stderr: "gh: API rate limit exceeded (HTTP 403)", ExitCode: 1,
	}
	if _, err := resolve(t, world(limited), epic("277")); exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("rate-limited auth check: code = %d, want Unreadable; err = %v", exitcode.CodeOf(err), err)
	}
	missing := &spy{mu: sync.Mutex{}, inner: runner.NewSnapshot([]runner.Call{
		call("gh version 2.102.0 (2026-09-30)\n", 0, "gh", "--version"),
	}), calls: 0}
	if _, err := resolve(t, missing, epic("277")); exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("auth check that never ran: code = %d, want Unreadable; err = %v", exitcode.CodeOf(err), err)
	}
}

func TestUnsupportedHostIsRefused(t *testing.T) {
	t.Parallel()

	for _, field := range []string{"subIssues", "blockedBy"} {
		body := `{"errors":[{"extensions":{"code":"undefinedField","typeName":"Issue","fieldName":"` + field +
			`"},"message":"Field '` + field + `' doesn't exist on type 'Issue'"}]}`
		_, err := resolve(t, world(probe(body, 1)), epic("277"))
		if exitcode.CodeOf(err) != exitcode.Refused || !strings.Contains(err.Error(), "sub-issue") {
			t.Errorf("%s: err = %v, want Refused naming sub-issue support", field, err)
		}
	}
}

// TestGHFailureStops guards EC-02: a gh failure, partial read, or rate limit is shown and stops.
func TestGHFailureStops(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		call runner.Call
		want string
	}{
		"Epic not found, data with errors": {
			call: probe(`{"data":{"repository":{"defaultBranchRef":{"name":"main"},"issue":null}},`+
				`"errors":[{"type":"NOT_FOUND","message":"Could not resolve to an Issue with the number of 277."}]}`, 1),
			want: "partial",
		},
		"rate limited": {
			call: probe(`{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}`, 1),
			want: "rate limited",
		},
		"api user fails": {
			call: runner.Call{Argv: []string{"gh", "api", "user"}, Stdout: "", Stderr: "gh: HTTP 502", ExitCode: 1},
			want: "HTTP 502",
		},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := resolve(t, world(tt.call), epic("277"))
			if exitcode.CodeOf(err) != exitcode.Unreadable || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("err = %v, want Unreadable mentioning %q", err, tt.want)
			}
		})
	}
}

func TestEmptyRepositoryIsRefused(t *testing.T) {
	t.Parallel()

	body := `{"data":{"repository":{"defaultBranchRef":null,"issue":{"number":277,"subIssues":{"totalCount":0},"blockedBy":{"totalCount":0}}}}}`
	if _, err := resolve(t, world(probe(body, 0)), epic("277")); exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("code = %d, want Refused", exitcode.CodeOf(err))
	}
}

func TestEmptyLoginIsUnreadable(t *testing.T) {
	t.Parallel()

	if _, err := resolve(t, world(call(`{"login":""}`, 0, "gh", "api", "user")), epic("277")); exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("code = %d, want Unreadable", exitcode.CodeOf(err))
	}
}
