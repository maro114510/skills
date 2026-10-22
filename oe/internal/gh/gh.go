// Package gh is oe's only path to GitHub and git. Reads and writes are separate methods: any
// failed, partial, or rate-limited read taints the client so that no later write can run on
// it, and a client in snapshot mode refuses every write without calling anything.
package gh

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"unicode"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/runner"
)

// Host is the only GitHub host oe talks to. Every `gh api` call is pinned to it, so GH_HOST
// cannot point a read or a write at another host's identity or repositories.
const Host = "github.com"

const (
	apiCmd       = "api"
	hostnameFlag = "--hostname"
)

// ErrExitStatus marks a call that ran and exited non-zero.
var ErrExitStatus = errors.New("exited non-zero")

// ErrRateLimited marks a call GitHub rate-limited. oe never backs off; the command stops.
var ErrRateLimited = errors.New("rate limit")

// Client runs gh and git through a runner.
type Client struct {
	r        runner.Runner
	snapshot bool

	mu     sync.Mutex
	failed error
}

// New returns a client. With snapshot set, every Write refuses.
func New(r runner.Runner, snapshot bool) *Client {
	return &Client{r: r, snapshot: snapshot, mu: sync.Mutex{}, failed: nil}
}

// Err returns the first read failure, or nil while every read so far was full.
func (c *Client) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.failed
}

// Read runs a read-only gh command and returns its stdout. A `gh api` call that would send a
// non-GET request is refused, so a write cannot slip past Write's checks through Read.
func (c *Client) Read(ctx context.Context, args ...string) ([]byte, error) {
	if err := readOnlyAPI(args); err != nil {
		return nil, err
	}
	pinned, err := pinHost(args)
	if err != nil {
		return nil, err
	}
	return c.read(ctx, runner.GH, pinned)
}

// notFoundStatus is the suffix gh writes to stderr when the API answered 404.
const notFoundStatus = "(HTTP 404)"

// ReadMissing is Read for a resource whose absence is an answer. It reports found=false, without
// tainting the client, only for a confirmed absence: gh's 404 line on stderr and GitHub's error
// body on stdout carrying exactly message. Any other failure, another 404 included, taints the
// client as Read does, so a resource that could not be seen is never read as absent.
func (c *Client) ReadMissing(ctx context.Context, message string, args ...string) ([]byte, bool, error) {
	if err := readOnlyAPI(args); err != nil {
		return nil, false, err
	}
	pinned, err := pinHost(args)
	if err != nil {
		return nil, false, err
	}
	res, err := c.r.Run(ctx, runner.GH, pinned)
	if err != nil {
		return nil, false, c.taint(exitcode.Wrap(exitcode.Unreadable, err, describe(runner.GH, pinned)+" failed"))
	}
	if res.ExitCode == 0 {
		return res.Stdout, true, nil
	}
	if confirmedMissing(res, message) {
		return nil, false, nil
	}
	return nil, false, c.taint(failure(runner.GH, pinned, res))
}

func confirmedMissing(res runner.Result, message string) bool {
	if !strings.Contains(string(res.Stderr), notFoundStatus) {
		return false
	}
	var body struct {
		Message string `json:"message"`
	}
	return json.Unmarshal(res.Stdout, &body) == nil && body.Message == message
}

// Git runs a read-only git command and returns its stdout.
func (c *Client) Git(ctx context.Context, args ...string) ([]byte, error) {
	return c.read(ctx, runner.Git, args)
}

// GitWrite runs a git command that changes local repository state, such as adding a worktree.
// Like Write, it refuses in snapshot mode and after any failed read, and it never taints the
// client: a failed change is the caller's to report, not a partial read.
func (c *Client) GitWrite(ctx context.Context, args ...string) ([]byte, error) {
	if c.snapshot {
		return nil, exitcode.New(exitcode.Refused, "--snapshot disables every mutation: "+describe(runner.Git, args))
	}
	if err := c.Err(); err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, "an earlier read failed or was partial, so no write is authorized")
	}
	res, err := c.r.Run(ctx, runner.Git, args)
	if err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, describe(runner.Git, args)+" failed")
	}
	if res.ExitCode != 0 {
		return nil, failure(runner.Git, args, res)
	}
	return res.Stdout, nil
}

// Write runs a mutating gh command. It refuses in snapshot mode and after any failed read.
func (c *Client) Write(ctx context.Context, args ...string) ([]byte, error) {
	if c.snapshot {
		return nil, exitcode.New(exitcode.Refused, "--snapshot disables every mutation: "+describe(runner.GH, args))
	}
	if err := c.Err(); err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, "an earlier read failed or was partial, so no write is authorized")
	}
	args, err := pinHost(args)
	if err != nil {
		return nil, err
	}
	res, err := c.r.Run(ctx, runner.GH, args)
	if err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, describe(runner.GH, args)+" failed")
	}
	if res.ExitCode != 0 {
		return nil, failure(runner.GH, args, res)
	}
	return res.Stdout, nil
}

// GraphQL runs a query and decodes its data into out. A response with any error, data
// beside errors included, fails as Unreadable wrapping a *QueryError.
func (c *Client) GraphQL(ctx context.Context, query string, vars []Var, out any) error {
	if op := operation(query); op != "query" {
		return exitcode.New(exitcode.Refused, "GraphQL is read-only; a "+op+" must go through Write")
	}
	args := make([]string, 0, 6+2*len(vars)) //nolint:mnd // Six fixed words, then a flag and a value per variable.
	args = append(args, apiCmd, "graphql", hostnameFlag, Host, "-f", "query="+query)
	for _, v := range vars {
		args = append(args, v.flag, v.name+"="+v.value)
	}
	res, err := c.r.Run(ctx, runner.GH, args)
	if err != nil {
		return c.taint(exitcode.Wrap(exitcode.Unreadable, err, "gh api graphql failed"))
	}
	data, err := graphQLData(args, res)
	if err != nil {
		return c.taint(err)
	}
	if err := json.Unmarshal(data, out); err != nil {
		return c.taint(exitcode.Wrap(exitcode.Unreadable, err, "decode graphql data"))
	}
	return nil
}

func (c *Client) taint(err error) error {
	c.mu.Lock()
	if c.failed == nil {
		c.failed = err
	}
	c.mu.Unlock()
	return err
}

func (c *Client) read(ctx context.Context, prog runner.Program, args []string) ([]byte, error) {
	res, err := c.r.Run(ctx, prog, args)
	if err != nil {
		return nil, c.taint(exitcode.Wrap(exitcode.Unreadable, err, describe(prog, args)+" failed"))
	}
	if res.ExitCode != 0 {
		return nil, c.taint(failure(prog, args, res))
	}
	return res.Stdout, nil
}

// Var is one GraphQL variable. Build it with String or Int so gh receives the right type.
type Var struct {
	flag  string
	name  string
	value string
}

// String is a string variable, passed raw with -f.
func String(name, value string) Var { return Var{flag: "-f", name: name, value: value} }

// Int is an integer variable, passed typed with -F.
func Int(name string, value int) Var {
	return Var{flag: "-F", name: name, value: strconv.Itoa(value)}
}

// GQLError is one entry of a GraphQL response's errors array.
type GQLError struct {
	Type       string          `json:"type"`
	Message    string          `json:"message"`
	Path       []any           `json:"path"`
	Extensions GQLErrExtension `json:"extensions"`
}

// GQLErrExtension carries the schema-validation detail of a GraphQL error.
type GQLErrExtension struct {
	Code      string `json:"code"`
	TypeName  string `json:"typeName"`  //nolint:tagliatelle // GitHub's field name.
	FieldName string `json:"fieldName"` //nolint:tagliatelle // GitHub's field name.
}

// QueryError is a GraphQL response that carried errors. Partial is set when data came back
// beside the errors. Either way the read is not full and authorizes nothing.
type QueryError struct {
	Errors  []GQLError
	Partial bool
}

func (e *QueryError) Error() string {
	msgs := make([]string, 0, len(e.Errors))
	for _, ge := range e.Errors {
		msgs = append(msgs, ge.Message)
	}
	return strings.Join(msgs, "; ")
}

// UndefinedField reports whether the schema rejected a field with this name.
func (e *QueryError) UndefinedField(name string) bool {
	for _, ge := range e.Errors {
		if ge.Extensions.Code == "undefinedField" && ge.Extensions.FieldName == name {
			return true
		}
	}
	return false
}

func (e *QueryError) rateLimited() bool {
	for _, ge := range e.Errors {
		if ge.Type == "RATE_LIMITED" || isRateLimited(ge.Message) {
			return true
		}
	}
	return false
}

type gqlResponse struct {
	Data   json.RawMessage `json:"data"`
	Errors []GQLError      `json:"errors"`
}

// graphQLData returns the data of a full response. gh exits 1 on GraphQL errors but still
// prints the body, so the body is parsed before the exit code decides anything.
func graphQLData(args []string, res runner.Result) (json.RawMessage, error) {
	var resp gqlResponse
	if err := json.Unmarshal(res.Stdout, &resp); err != nil {
		if res.ExitCode != 0 {
			return nil, failure(runner.GH, args, res)
		}
		return nil, exitcode.Wrap(exitcode.Unreadable, err, "gh api graphql returned unparseable output")
	}
	if len(resp.Errors) > 0 {
		qe := &QueryError{Errors: resp.Errors, Partial: hasData(resp.Data)}
		msg := "gh api graphql returned errors"
		if qe.Partial {
			msg = "gh api graphql returned data with errors, a partial read"
		}
		if qe.rateLimited() {
			return nil, exitcode.Wrap(exitcode.Unreadable, fmt.Errorf("%w: %w", ErrRateLimited, qe), "rate limited: "+msg)
		}
		return nil, exitcode.Wrap(exitcode.Unreadable, qe, msg)
	}
	if res.ExitCode != 0 {
		return nil, failure(runner.GH, args, res)
	}
	if !hasData(resp.Data) {
		return nil, exitcode.New(exitcode.Unreadable, "gh api graphql returned no data")
	}
	return resp.Data, nil
}

// operation returns the GraphQL operation type of a document: query for a bare selection set,
// else its leading keyword after whitespace and comments.
func operation(query string) string {
	q := query
	for {
		q = strings.TrimLeft(q, " \t\r\n,\ufeff")
		if !strings.HasPrefix(q, "#") {
			break
		}
		_, q, _ = strings.Cut(q, "\n")
	}
	if strings.HasPrefix(q, "{") {
		return "query"
	}
	end := strings.IndexFunc(q, func(r rune) bool { return !unicode.IsLetter(r) })
	if end < 0 {
		end = len(q)
	}
	return q[:end]
}

// pinHost adds `--hostname github.com` to a `gh api` call. Every `--hostname` already present
// must name github.com, because gh honors the last one, so no environment or argument can
// redirect oe away from github.com.
func pinHost(args []string) ([]string, error) {
	if len(args) == 0 || args[0] != apiCmd {
		return args, nil
	}
	named := false
	for i, a := range args {
		name, value, inline := strings.Cut(a, "=")
		if name != hostnameFlag {
			continue
		}
		if !inline {
			value = ""
			if i+1 < len(args) {
				value = args[i+1]
			}
		}
		if value != Host {
			return nil, exitcode.New(exitcode.Refused, "gh api must target "+Host+", not "+value)
		}
		named = true
	}
	if named {
		return args, nil
	}
	return append([]string{apiCmd, hostnameFlag, Host}, args[1:]...), nil
}

// readOnlyAPI refuses a `gh api` call that would not be a GET: GraphQL, which has its own
// method, an explicit non-GET method, or fields without an explicit GET, since gh then POSTs.
func readOnlyAPI(args []string) error {
	if len(args) == 0 || args[0] != apiCmd {
		return nil
	}
	if len(args) > 1 && args[1] == "graphql" {
		return exitcode.New(exitcode.Refused, "gh api graphql must go through GraphQL")
	}
	method, hasFields := apiMethod(args[1:])
	if (method != "" && !strings.EqualFold(method, "GET")) || (method == "" && hasFields) {
		return exitcode.New(exitcode.Refused, "Read refuses a gh api call that is not a GET; use Write")
	}
	return nil
}

// apiMethod returns the explicit request method of `gh api` arguments, if any, and whether
// they carry request fields.
func apiMethod(args []string) (string, bool) {
	method, hasFields := "", false
	for i, a := range args {
		name, value, inline := strings.Cut(a, "=")
		switch {
		case name == "-X" || name == "--method":
			if !inline && i+1 < len(args) {
				value = args[i+1]
			}
			method = value
		case strings.HasPrefix(a, "-X"):
			method = a[len("-X"):]
		case isFieldFlag(name):
			hasFields = true
		}
	}
	return method, hasFields
}

// isFieldFlag reports whether a `gh api` flag adds request fields or a body.
func isFieldFlag(name string) bool {
	switch name {
	case "--field", "--raw-field", "--input":
		return true
	}
	return strings.HasPrefix(name, "-f") || strings.HasPrefix(name, "-F")
}

func hasData(raw json.RawMessage) bool {
	s := strings.TrimSpace(string(raw))
	return s != "" && s != "null"
}

func failure(prog runner.Program, args []string, res runner.Result) error {
	detail := strings.TrimSpace(string(res.Stderr))
	if detail == "" {
		detail = strings.TrimSpace(string(res.Stdout))
	}
	msg := fmt.Sprintf("%s failed (exit %d)", describe(prog, args), res.ExitCode)
	if isRateLimited(detail) {
		return exitcode.Wrap(exitcode.Unreadable, fmt.Errorf("%w: %s", ErrRateLimited, detail), "rate limited: "+msg)
	}
	return exitcode.Wrap(exitcode.Unreadable, fmt.Errorf("%w: %s", ErrExitStatus, detail), msg)
}

// describe names a call by its program and first two arguments, never a query body.
func describe(prog runner.Program, args []string) string {
	head := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == hostnameFlag {
			i++ // Skip the pinned host; it is the same on every call.
			continue
		}
		head = append(head, args[i])
	}
	if len(head) > 2 { //nolint:mnd // Program plus a two-word subcommand, such as `gh api user`.
		head = head[:2]
	}
	return strings.Join(append([]string{string(prog)}, head...), " ")
}

func isRateLimited(text string) bool {
	t := strings.ToLower(text)
	return strings.Contains(t, "rate limit") || strings.Contains(t, "rate_limited") || strings.Contains(t, "http 429")
}
