package gh_test

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/runner"
)

// spy wraps a snapshot and records every argv it is asked to run.
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

func newSpy(calls ...runner.Call) *spy {
	return &spy{mu: sync.Mutex{}, inner: runner.NewSnapshot(calls), calls: nil}
}

const query = "query{viewer{login}}"

func gqlCall(stdout, stderr string, exit int) runner.Call {
	return runner.Call{Argv: []string{"gh", "api", "graphql", "--hostname", "github.com", "-f", "query=" + query}, Stdout: stdout, Stderr: stderr, ExitCode: exit}
}

func TestReadReturnsStdout(t *testing.T) {
	t.Parallel()

	c := gh.New(newSpy(runner.Call{Argv: []string{"gh", "api", "--hostname", "github.com", "user"}, Stdout: "ok", Stderr: "", ExitCode: 0}), false)
	out, err := c.Read(t.Context(), "api", "user")
	if err != nil || string(out) != "ok" {
		t.Errorf("Read() = %q, %v; want ok, nil", out, err)
	}
}

func TestReadFailureIsUnreadable(t *testing.T) {
	t.Parallel()

	tests := map[string]runner.Call{
		"non-zero exit": {Argv: []string{"gh", "api", "--hostname", "github.com", "user"}, Stdout: "", Stderr: "gh: Not Found (HTTP 404)", ExitCode: 1},
	}
	for name, call := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := gh.New(newSpy(call), false).Read(t.Context(), "api", "user")
			if exitcode.CodeOf(err) != exitcode.Unreadable {
				t.Errorf("CodeOf(err) = %d, want Unreadable; err = %v", exitcode.CodeOf(err), err)
			}
		})
	}
}

// TestFailedLookupIsNeverNothingFound guards LC-01 and CMD-07: a call that could not be read,
// such as one the runner cannot answer, is an error, never an empty result.
func TestFailedLookupIsNeverNothingFound(t *testing.T) {
	t.Parallel()

	out, err := gh.New(newSpy(), false).Read(t.Context(), "api", "user")
	if err == nil {
		t.Fatalf("Read() = %q, nil; want an error", out)
	}
	if exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("CodeOf(err) = %d, want Unreadable", exitcode.CodeOf(err))
	}
}

func TestRateLimitIsReported(t *testing.T) {
	t.Parallel()

	tests := map[string]runner.Call{
		"REST primary":   {Argv: []string{"gh", "api", "--hostname", "github.com", "user"}, Stdout: "", Stderr: "gh: API rate limit exceeded for user ID 1. (HTTP 403)", ExitCode: 1},
		"REST secondary": {Argv: []string{"gh", "api", "--hostname", "github.com", "user"}, Stdout: "", Stderr: "gh: You have exceeded a secondary rate limit (HTTP 403)", ExitCode: 1},
		"HTTP 429":       {Argv: []string{"gh", "api", "--hostname", "github.com", "user"}, Stdout: "", Stderr: "gh: Too Many Requests (HTTP 429)", ExitCode: 1},
	}
	for name, call := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := gh.New(newSpy(call), false).Read(t.Context(), "api", "user")
			if exitcode.CodeOf(err) != exitcode.Unreadable || !strings.Contains(err.Error(), "rate limited") {
				t.Errorf("err = %v, want Unreadable mentioning rate limited", err)
			}
			if !errors.Is(err, gh.ErrRateLimited) {
				t.Errorf("errors.Is(err, ErrRateLimited) = false; err = %v", err)
			}
		})
	}
}

func TestGraphQLRateLimitIsReported(t *testing.T) {
	t.Parallel()

	body := `{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}`
	var out struct{}
	err := gh.New(newSpy(gqlCall(body, "gh: API rate limit exceeded", 1)), false).GraphQL(t.Context(), query, nil, &out)
	if exitcode.CodeOf(err) != exitcode.Unreadable || !strings.Contains(err.Error(), "rate limited") {
		t.Errorf("err = %v, want Unreadable mentioning rate limited", err)
	}
}

func TestGraphQLDecodesData(t *testing.T) {
	t.Parallel()

	var out struct {
		Viewer struct {
			Login string `json:"login"`
		} `json:"viewer"`
	}
	err := gh.New(newSpy(gqlCall(`{"data":{"viewer":{"login":"me"}}}`, "", 0)), false).GraphQL(t.Context(), query, nil, &out)
	if err != nil || out.Viewer.Login != "me" {
		t.Errorf("GraphQL() = %+v, %v; want login me", out, err)
	}
}

func TestGraphQLVariablesKeepOrderAndType(t *testing.T) {
	t.Parallel()

	s := newSpy()
	var out struct{}
	_ = gh.New(s, false).GraphQL(t.Context(), query, []gh.Var{gh.String("owner", "o"), gh.Int("n", 7)}, &out)
	want := []string{"gh", "api", "graphql", "--hostname", "github.com", "-f", "query=" + query, "-f", "owner=o", "-F", "n=7"}
	if len(s.calls) != 1 || !slices.Equal(s.calls[0], want) {
		t.Errorf("argv = %q, want %q", s.calls, want)
	}
}

// TestGraphQLDataWithErrorsIsPartial covers a response that carries both data and errors:
// it is a partial read, exit 1, and the caller can inspect the errors.
func TestGraphQLDataWithErrorsIsPartial(t *testing.T) {
	t.Parallel()

	body := `{"data":{"viewer":{"login":"me"}},"errors":[{"type":"NOT_FOUND","path":["x"],"message":"Could not resolve"}]}`
	var out struct{}
	err := gh.New(newSpy(gqlCall(body, "gh: Could not resolve", 1)), false).GraphQL(t.Context(), query, nil, &out)
	if exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Fatalf("CodeOf(err) = %d, want Unreadable; err = %v", exitcode.CodeOf(err), err)
	}
	var qe *gh.QueryError
	if !errors.As(err, &qe) || !qe.Partial || len(qe.Errors) != 1 || qe.Errors[0].Type != "NOT_FOUND" {
		t.Errorf("QueryError = %+v, want one partial NOT_FOUND error", qe)
	}
}

func TestGraphQLErrorsWithExitZeroStillFail(t *testing.T) {
	t.Parallel()

	body := `{"data":{"viewer":{"login":"me"}},"errors":[{"message":"something"}]}`
	var out struct{}
	err := gh.New(newSpy(gqlCall(body, "", 0)), false).GraphQL(t.Context(), query, nil, &out)
	if exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("CodeOf(err) = %d, want Unreadable", exitcode.CodeOf(err))
	}
}

func TestGraphQLUndefinedField(t *testing.T) {
	t.Parallel()

	body := `{"errors":[{"path":["query","repository","issue","subIssues"],` +
		`"extensions":{"code":"undefinedField","typeName":"Issue","fieldName":"subIssues"},"message":"Field 'subIssues' doesn't exist on type 'Issue'"}]}`
	var out struct{}
	err := gh.New(newSpy(gqlCall(body, "gh: Field doesn't exist", 1)), false).GraphQL(t.Context(), query, nil, &out)
	var qe *gh.QueryError
	if !errors.As(err, &qe) || !qe.UndefinedField("subIssues") || qe.UndefinedField("blockedBy") || qe.Partial {
		t.Errorf("QueryError = %+v, want a non-partial undefined subIssues", qe)
	}
}

func TestGraphQLUnparseableOrEmptyFails(t *testing.T) {
	t.Parallel()

	tests := map[string]runner.Call{
		"not JSON, exit 0": gqlCall("<html>", "", 0),
		"not JSON, exit 1": gqlCall("", "gh: connection refused", 1),
		"null data":        gqlCall(`{"data":null}`, "", 0),
		"exit 1 no errors": gqlCall(`{"data":{}}`, "gh: HTTP 502", 1),
	}
	for name, call := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			var out struct{}
			err := gh.New(newSpy(call), false).GraphQL(t.Context(), query, nil, &out)
			if exitcode.CodeOf(err) != exitcode.Unreadable {
				t.Errorf("CodeOf(err) = %d, want Unreadable; err = %v", exitcode.CodeOf(err), err)
			}
		})
	}
}

// TestPartialReadAuthorizesNoWrite checks that once any read failed or came back partial, a
// write refuses even when the caller ignored the read error, and gh is never called for it.
func TestPartialReadAuthorizesNoWrite(t *testing.T) {
	t.Parallel()

	body := `{"data":{"viewer":{"login":"me"}},"errors":[{"message":"partial"}]}`
	s := newSpy(gqlCall(body, "", 1), runner.Call{Argv: []string{"gh", "issue", "comment", "1"}, Stdout: "", Stderr: "", ExitCode: 0})
	c := gh.New(s, false)
	var out struct{}
	_ = c.GraphQL(t.Context(), query, nil, &out)

	_, err := c.Write(t.Context(), "issue", "comment", "1")
	if exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("Write() code = %d, want Unreadable; err = %v", exitcode.CodeOf(err), err)
	}
	if len(s.calls) != 1 {
		t.Errorf("calls = %q, want only the read", s.calls)
	}
}

// TestReadRefusesWrites keeps Read from becoming a side door around Write's checks: a gh api
// call that would send anything but a GET is refused before gh runs.
func TestReadRefusesWrites(t *testing.T) {
	t.Parallel()

	refused := [][]string{
		{"api", "graphql", "-f", "query=query{viewer{login}}"},
		{"api", "-X", "POST", "repos/o/r/issues/1/comments"},
		{"api", "--method", "PATCH", "repos/o/r/issues/comments/1"},
		{"api", "--method=DELETE", "repos/o/r/issues/comments/1"},
		{"api", "-XPOST", "repos/o/r/issues/1/comments"},
		{"api", "repos/o/r/issues/1/comments", "-f", "body=x"},
		{"api", "repos/o/r/issues/1/comments", "-fbody=x"},
		{"api", "repos/o/r/issues/1/comments", "--raw-field=body=x"},
		{"api", "repos/o/r/issues/1/comments", "--input", "body.json"},
	}
	for _, args := range refused {
		s := newSpy()
		_, err := gh.New(s, false).Read(t.Context(), args...)
		if exitcode.CodeOf(err) != exitcode.Refused || len(s.calls) != 0 {
			t.Errorf("Read(%q): code %d, calls %d; want Refused before any call", args, exitcode.CodeOf(err), len(s.calls))
		}
	}

	allowed := [][]string{
		{"api", "user"},
		{"api", "-X", "GET", "search/issues", "-f", "q=x"},
		{"api", "--paginate", "repos/o/r/issues/1/comments", "-H", "Accept: application/json"},
		{"--version"},
	}
	for _, args := range allowed {
		argv := []string{"gh"}
		if args[0] == "api" {
			argv = append(argv, "api", "--hostname", "github.com")
			argv = append(argv, args[1:]...)
		} else {
			argv = append(argv, args...)
		}
		s := newSpy(runner.Call{Argv: argv, Stdout: "ok", Stderr: "", ExitCode: 0})
		if _, err := gh.New(s, false).Read(t.Context(), args...); err != nil {
			t.Errorf("Read(%q) error = %v, want nil", args, err)
		}
	}
}

// TestAPICallsArePinnedToGitHub keeps GH_HOST from redirecting a read or a write: every
// gh api call names github.com, and a call naming another host is refused before gh runs.
func TestAPICallsArePinnedToGitHub(t *testing.T) {
	t.Parallel()

	s := newSpy()
	c := gh.New(s, false)
	_, _ = c.Read(t.Context(), "api", "user")
	var out struct{}
	_ = c.GraphQL(t.Context(), query, nil, &out)
	for _, call := range s.calls {
		if !slices.Contains(call, "--hostname") || !slices.Contains(call, "github.com") {
			t.Errorf("call %q is not pinned to github.com", call)
		}
	}

	for _, args := range [][]string{
		{"api", "--hostname", "ghe.example.com", "user"},
		{"api", "--hostname=ghe.example.com", "user"},
	} {
		s := newSpy()
		c := gh.New(s, false)
		if _, err := c.Read(t.Context(), args...); exitcode.CodeOf(err) != exitcode.Refused {
			t.Errorf("Read(%q) code = %d, want Refused", args, exitcode.CodeOf(err))
		}
		if _, err := c.Write(t.Context(), args...); exitcode.CodeOf(err) != exitcode.Refused {
			t.Errorf("Write(%q) code = %d, want Refused", args, exitcode.CodeOf(err))
		}
		if len(s.calls) != 0 {
			t.Errorf("%q: calls = %d, want none", args, len(s.calls))
		}
	}
}

func TestGraphQLRefusesMutations(t *testing.T) {
	t.Parallel()

	for _, q := range []string{
		"mutation{addComment(input:{}){clientMutationId}}",
		"  # leading comment\n mutation M { x }",
		"subscription{x}",
	} {
		s := newSpy()
		var out struct{}
		err := gh.New(s, false).GraphQL(t.Context(), q, nil, &out)
		if exitcode.CodeOf(err) != exitcode.Refused || len(s.calls) != 0 {
			t.Errorf("GraphQL(%q): code %d, calls %d; want Refused before any call", q, exitcode.CodeOf(err), len(s.calls))
		}
	}
	for _, q := range []string{"{viewer{login}}", "query Q($a:Int){x}", "# c\nquery{x}"} {
		s := newSpy()
		var out struct{}
		_ = gh.New(s, false).GraphQL(t.Context(), q, nil, &out)
		if len(s.calls) != 1 {
			t.Errorf("GraphQL(%q): calls %d, want the query sent", q, len(s.calls))
		}
	}
}

func TestSnapshotRefusesEveryWrite(t *testing.T) {
	t.Parallel()

	s := newSpy(runner.Call{Argv: []string{"gh", "issue", "comment", "1"}, Stdout: "", Stderr: "", ExitCode: 0})
	_, err := gh.New(s, true).Write(t.Context(), "issue", "comment", "1")
	if exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("Write() code = %d, want Refused", exitcode.CodeOf(err))
	}
	if len(s.calls) != 0 {
		t.Errorf("calls = %q, want none", s.calls)
	}
}

func TestWriteAfterCleanReads(t *testing.T) {
	t.Parallel()

	s := newSpy(
		runner.Call{Argv: []string{"gh", "api", "--hostname", "github.com", "user"}, Stdout: "{}", Stderr: "", ExitCode: 0},
		runner.Call{Argv: []string{"gh", "issue", "comment", "1"}, Stdout: "done", Stderr: "", ExitCode: 0},
	)
	c := gh.New(s, false)
	if _, err := c.Read(t.Context(), "api", "user"); err != nil {
		t.Fatal(err)
	}
	if out, err := c.Write(t.Context(), "issue", "comment", "1"); err != nil || string(out) != "done" {
		t.Errorf("Write() = %q, %v; want done, nil", out, err)
	}
}

func TestGitReadFailureTaints(t *testing.T) {
	t.Parallel()

	s := newSpy(runner.Call{Argv: []string{"git", "remote", "get-url", "origin"}, Stdout: "", Stderr: "error: No such remote", ExitCode: 2})
	c := gh.New(s, false)
	if _, err := c.Git(t.Context(), "remote", "get-url", "origin"); exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("Git() code = %d, want Unreadable", exitcode.CodeOf(err))
	}
	if err := c.Err(); err == nil {
		t.Error("Err() = nil after a failed read, want the failure")
	}
}
