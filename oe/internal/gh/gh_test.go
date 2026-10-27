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
		{"api", "--hostname", "github.com", "--hostname", "ghe.example.com", "user"},
		{"api", "--hostname=github.com", "--hostname=ghe.example.com", "user"},
		{"api", "user", "--hostname"},
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

// TestGitWriteIsGatedLikeWrite: a local git change refuses under --snapshot and after a failed
// read, before any call, and its own failure leaves the client untainted.
func TestGitWriteIsGatedLikeWrite(t *testing.T) {
	t.Parallel()

	add := []string{"worktree", "add", "/tmp/x", "b"}
	s := newSpy(runner.Call{Argv: append([]string{"git"}, add...), Stdout: "", Stderr: "", ExitCode: 0})
	if _, err := gh.New(s, true).GitWrite(t.Context(), add...); exitcode.CodeOf(err) != exitcode.Refused || len(s.calls) != 0 {
		t.Errorf("snapshot GitWrite: code %d, calls %q", exitcode.CodeOf(err), s.calls)
	}
	s = newSpy(
		runner.Call{Argv: []string{"git", "remote", "get-url", "origin"}, Stdout: "", Stderr: "no remote", ExitCode: 2},
		runner.Call{Argv: append([]string{"git"}, add...), Stdout: "", Stderr: "", ExitCode: 0},
	)
	c := gh.New(s, false)
	_, _ = c.Git(t.Context(), "remote", "get-url", "origin")
	if _, err := c.GitWrite(t.Context(), add...); exitcode.CodeOf(err) != exitcode.Unreadable || len(s.calls) != 1 {
		t.Errorf("GitWrite after a failed read: code %d, calls %q", exitcode.CodeOf(err), s.calls)
	}
	s = newSpy(runner.Call{Argv: append([]string{"git"}, add...), Stdout: "", Stderr: "fatal: exists", ExitCode: 128})
	c = gh.New(s, false)
	if _, err := c.GitWrite(t.Context(), add...); exitcode.CodeOf(err) != exitcode.Unreadable || c.Err() != nil {
		t.Errorf("failed GitWrite: code %d, taint %v", exitcode.CodeOf(err), c.Err())
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

// TestReadMissingConfirmsOnlyTheNamedAbsence: a 404 whose message is the one named is a
// confirmed absence that leaves the client able to write; any other failure, a 404 included,
// taints it as Read does.
func TestReadMissingConfirmsOnlyTheNamedAbsence(t *testing.T) {
	t.Parallel()

	argv := []string{"gh", "api", "--hostname", "github.com", "repos/o/r/branches/main/protection"}
	const missing = "Branch not protected"
	tests := map[string]struct {
		call    runner.Call
		found   bool
		wantErr bool
	}{
		"found":          {runner.Call{Argv: argv, Stdout: `{"url":"x"}`, Stderr: "", ExitCode: 0}, true, false},
		"named 404":      {runner.Call{Argv: argv, Stdout: `{"message":"Branch not protected","status":"404"}`, Stderr: "gh: Branch not protected (HTTP 404)", ExitCode: 1}, false, false},
		"other 404":      {runner.Call{Argv: argv, Stdout: `{"message":"Not Found","status":"404"}`, Stderr: "gh: Not Found (HTTP 404)", ExitCode: 1}, false, true},
		"403":            {runner.Call{Argv: argv, Stdout: `{"message":"Branch not protected"}`, Stderr: "gh: Must have admin rights (HTTP 403)", ExitCode: 1}, false, true},
		"404 no body":    {runner.Call{Argv: argv, Stdout: "", Stderr: "gh: Branch not protected (HTTP 404)", ExitCode: 1}, false, true},
		"404 no stderr":  {runner.Call{Argv: argv, Stdout: `{"message":"Branch not protected"}`, Stderr: "", ExitCode: 1}, false, true},
		"not answerable": {runner.Call{Argv: []string{"gh", "other"}, Stdout: "", Stderr: "", ExitCode: 0}, false, true},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			c := gh.New(newSpy(tc.call), false)
			out, found, err := c.ReadMissing(t.Context(), missing, "api", "repos/o/r/branches/main/protection")
			if tc.wantErr {
				if exitcode.CodeOf(err) != exitcode.Unreadable || c.Err() == nil {
					t.Errorf("ReadMissing() err = %v, Err() = %v; want Unreadable and a tainted client", err, c.Err())
				}
				return
			}
			if err != nil || found != tc.found || c.Err() != nil {
				t.Errorf("ReadMissing() = %q, %v, %v; Err() = %v", out, found, err, c.Err())
			}
			if found && string(out) != `{"url":"x"}` {
				t.Errorf("ReadMissing() out = %q", out)
			}
		})
	}
}

func TestReadMissingRefusesWrites(t *testing.T) {
	t.Parallel()

	s := newSpy()
	_, _, err := gh.New(s, false).ReadMissing(t.Context(), "x", "api", "-X", "DELETE", "repos/o/r/branches/main/protection")
	if exitcode.CodeOf(err) != exitcode.Refused || len(s.calls) != 0 {
		t.Errorf("err = %v, calls = %q", err, s.calls)
	}
}

func mergeArgs() []string {
	return []string{"api", "-X", "PUT", "repos/o/r/pulls/7/merge", "-f", "sha=abc"}
}

func mergeCall(stdout, stderr string, exit int) runner.Call {
	argv := []string{"gh", "api", "-i", "--hostname", "github.com", "-X", "PUT", "repos/o/r/pulls/7/merge", "-f", "sha=abc"}
	return runner.Call{Argv: argv, Stdout: stdout, Stderr: stderr, ExitCode: exit}
}

// TestWriteHTTPReturnsEveryAnswerWithItsStatus: the merge route depends on telling a 200 from a 409 from a 405,
// and gh exits non-zero with the body on stdout for the last two.
func TestWriteHTTPReturnsEveryAnswerWithItsStatus(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		call   runner.Call
		status int
		body   string
	}{
		"a 200 with the merge commit": {
			mergeCall("HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"sha\":\"m1\",\"merged\":true}", "", 0),
			200, `{"sha":"m1","merged":true}`,
		},
		"a 409 on a moved head, which gh reports as a failed exit": {
			mergeCall("HTTP/2.0 409 Conflict\r\nContent-Type: application/json\r\n\r\n{\"message\":\"Head branch was modified.\"}",
				"gh: Head branch was modified. (HTTP 409)", 1),
			409, `{"message":"Head branch was modified."}`,
		},
		"a 405 the repository rejected": {
			mergeCall("HTTP/2.0 405 Method Not Allowed\r\n\r\n{\"message\":\"Required status check is expected.\"}", "gh: (HTTP 405)", 1),
			405, `{"message":"Required status check is expected."}`,
		},
		"a 502 whose merge may still have landed": {
			mergeCall("HTTP/1.1 502 Bad Gateway\r\n\r\n", "gh: (HTTP 502)", 1),
			502, "",
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			resp, err := gh.New(newSpy(tc.call), false).WriteHTTP(t.Context(), mergeArgs()...)
			if err != nil || resp.Status != tc.status || string(resp.Body) != tc.body {
				t.Errorf("WriteHTTP() = %d %q, %v; want %d %q, nil", resp.Status, resp.Body, err, tc.status, tc.body)
			}
		})
	}
}

// TestWriteHTTPWithoutAnAnswerIsNoResponse: a request that was sent and got nothing back may have merged,
// so the caller must be able to tell it from a refusal that sent nothing.
func TestWriteHTTPWithoutAnAnswerIsNoResponse(t *testing.T) {
	t.Parallel()

	tests := map[string]*spy{
		"gh failed before any HTTP status":     newSpy(mergeCall("", "gh: error connecting to api.github.com", 1)),
		"stdout holds no status line":          newSpy(mergeCall("{\"sha\":\"m1\"}", "", 0)),
		"stdout holds a status that is no int": newSpy(mergeCall("HTTP/2.0 abc\r\n\r\n{}", "", 0)),
	}
	for name, s := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := gh.New(s, false).WriteHTTP(t.Context(), mergeArgs()...)
			if !errors.Is(err, gh.ErrNoResponse) || exitcode.CodeOf(err) != exitcode.Unreadable {
				t.Errorf("WriteHTTP() err = %v, code %d; want ErrNoResponse and Unreadable", err, exitcode.CodeOf(err))
			}
		})
	}
}

// TestWriteHTTPWhenGhCannotStartSentNothing: a runner that cannot start gh never put a request on the wire,
// so reconciling it as a possibly merged request would invent a merge that was never asked for.
func TestWriteHTTPWhenGhCannotStartSentNothing(t *testing.T) {
	t.Parallel()

	_, err := gh.New(newSpy(), false).WriteHTTP(t.Context(), mergeArgs()...)
	if errors.Is(err, gh.ErrNoResponse) || exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Errorf("WriteHTTP() err = %v, code %d; want an ordinary Unreadable error that is not ErrNoResponse", err, exitcode.CodeOf(err))
	}
}

// TestWriteHTTPIsRefusedBeforeAnyCallLikeWrite: a refusal sent nothing, so it must never read as no response,
// which would send the merge flow off to reconcile a request that was never made.
func TestWriteHTTPIsRefusedBeforeAnyCallLikeWrite(t *testing.T) {
	t.Parallel()

	snapshotted := newSpy(mergeCall("HTTP/2.0 200 OK\r\n\r\n{}", "", 0))
	_, err := gh.New(snapshotted, true).WriteHTTP(t.Context(), mergeArgs()...)
	if exitcode.CodeOf(err) != exitcode.Refused || errors.Is(err, gh.ErrNoResponse) || len(snapshotted.calls) != 0 {
		t.Errorf("snapshot WriteHTTP: code %d, err %v, calls %q; want Refused, no calls", exitcode.CodeOf(err), err, snapshotted.calls)
	}

	other := newSpy(mergeCall("HTTP/2.0 200 OK\r\n\r\n{}", "", 0))
	_, err = gh.New(other, false).WriteHTTP(t.Context(), "api", "--hostname", "ghe.example.com", "-X", "PUT", "repos/o/r/pulls/7/merge")
	if exitcode.CodeOf(err) != exitcode.Refused || len(other.calls) != 0 {
		t.Errorf("other host WriteHTTP: code %d, calls %q; want Refused before any call", exitcode.CodeOf(err), other.calls)
	}

	tainted := newSpy(
		runner.Call{Argv: []string{"gh", "api", "--hostname", "github.com", "user"}, Stdout: "", Stderr: "boom", ExitCode: 1},
		mergeCall("HTTP/2.0 200 OK\r\n\r\n{}", "", 0),
	)
	c := gh.New(tainted, false)
	_, _ = c.Read(t.Context(), "api", "user")
	_, err = c.WriteHTTP(t.Context(), mergeArgs()...)
	if exitcode.CodeOf(err) != exitcode.Unreadable || errors.Is(err, gh.ErrNoResponse) || len(tainted.calls) != 1 {
		t.Errorf("tainted WriteHTTP: code %d, err %v, calls %d; want Unreadable without a request", exitcode.CodeOf(err), err, len(tainted.calls))
	}
}

// TestWriteHTTPRefusesWhatIsNotAnAPICall: only a gh api call carries a status line.
func TestWriteHTTPRefusesWhatIsNotAnAPICall(t *testing.T) {
	t.Parallel()

	s := newSpy()
	_, err := gh.New(s, false).WriteHTTP(t.Context(), "pr", "merge", "7")
	if exitcode.CodeOf(err) != exitcode.Refused || len(s.calls) != 0 {
		t.Errorf("WriteHTTP(pr merge): code %d, calls %q; want Refused before any call", exitcode.CodeOf(err), s.calls)
	}
}

// TestProbeFailureLeavesTheClientWritable: after a merge request got no response, an unreadable pull request is the answer
// to record, so its failed read must not forbid the record the way an ordinary failed read forbids every write.
func TestProbeFailureLeavesTheClientWritable(t *testing.T) {
	t.Parallel()

	s := newSpy(
		runner.Call{Argv: []string{"gh", "api", "--hostname", "github.com", "repos/o/r/pulls/7"}, Stdout: "", Stderr: "boom", ExitCode: 1},
		runner.Call{Argv: []string{"gh", "issue", "comment", "1"}, Stdout: "done", Stderr: "", ExitCode: 0},
	)
	c := gh.New(s, false)
	if _, err := c.Probe().Read(t.Context(), "api", "repos/o/r/pulls/7"); exitcode.CodeOf(err) != exitcode.Unreadable {
		t.Fatalf("Probe().Read() code = %d, want Unreadable; err = %v", exitcode.CodeOf(err), err)
	}
	if c.Err() != nil {
		t.Errorf("Err() = %v; want the original client untainted by its probe", c.Err())
	}
	if out, err := c.Write(t.Context(), "issue", "comment", "1"); err != nil || string(out) != "done" {
		t.Errorf("Write() = %q, %v; want done, nil", out, err)
	}
}

// TestProbeKeepsTheReadRulesAndRefusesEveryWrite: a probe is a read-only view, so it can neither send a write
// nor widen what Read allows.
func TestProbeKeepsTheReadRulesAndRefusesEveryWrite(t *testing.T) {
	t.Parallel()

	s := newSpy(runner.Call{Argv: []string{"gh", "api", "--hostname", "github.com", "repos/o/r/pulls/7"}, Stdout: "{}", Stderr: "", ExitCode: 0})
	p := gh.New(s, false).Probe()
	if _, err := p.Read(t.Context(), "api", "repos/o/r/pulls/7"); err != nil {
		t.Fatalf("Probe().Read() err = %v", err)
	}
	if _, err := p.Read(t.Context(), "api", "-X", "PUT", "repos/o/r/pulls/7/merge"); exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("Probe().Read(PUT) code = %d, want Refused", exitcode.CodeOf(err))
	}
	if _, err := p.Write(t.Context(), "api", "-X", "PUT", "repos/o/r/pulls/7/merge"); exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("Probe().Write() code = %d, want Refused", exitcode.CodeOf(err))
	}
	if _, err := p.WriteHTTP(t.Context(), mergeArgs()...); exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("Probe().WriteHTTP() code = %d, want Refused", exitcode.CodeOf(err))
	}
	if _, err := p.GitWrite(t.Context(), "worktree", "add", "x"); exitcode.CodeOf(err) != exitcode.Refused {
		t.Errorf("Probe().GitWrite() code = %d, want Refused", exitcode.CodeOf(err))
	}
	if len(s.calls) != 1 {
		t.Errorf("calls = %q, want only the one read", s.calls)
	}
}

// TestProbeInSnapshotModeReplaysReads: a probe of a snapshot client still never starts a process.
func TestProbeInSnapshotModeReplaysReads(t *testing.T) {
	t.Parallel()

	s := newSpy(runner.Call{Argv: []string{"gh", "api", "--hostname", "github.com", "repos/o/r/pulls/7"}, Stdout: "{}", Stderr: "", ExitCode: 0})
	if _, err := gh.New(s, true).Probe().Read(t.Context(), "api", "repos/o/r/pulls/7"); err != nil {
		t.Errorf("Probe().Read() err = %v", err)
	}
}
