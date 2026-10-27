// Package ghfake is a stand-in for gh and git in tests. A Router answers the calls a run of oe
// makes, telling each GraphQL query by a phrase only it holds and handing the call's variables
// to a handler, so a test states only the responses it cares about.
package ghfake

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/maro114510/skills/oe/internal/runner"
)

// Handler returns the response body of a query, given its variables. The raw query is under the
// key "query"; a git call's arguments, joined by spaces, are under the key "args".
type Handler func(vars map[string]string) string

// Router implements runner.Runner.
type Router struct {
	mu       sync.Mutex
	handlers map[string]Handler
	exits    map[string]int
	stderrs  map[string]string
	calls    [][]string
	origin   string
	store    *Store
}

// The names of the queries and calls a Router answers.
const (
	Tree         = "tree"
	Blockers     = "blockers"
	Pulls        = "pulls"
	Refs         = "refs"
	CommentsName = "comments"
	MoreComments = "moreComments"
	MergePull    = "mergePull"
	// PullsByHead is the listing of the pull requests of one head branch, in every state.
	PullsByHead = "pullsByHead"
	Readiness   = "readiness"
	Git         = "git"
	// Protection is the REST read of the default branch's protection.
	Protection = "protection"
)

// phrases are the texts only one query holds. The comments query is the only one with the
// first comments form, and the page query for more comments the only one with the second.
var phrases = map[string]string{ //nolint:gochecknoglobals // A fixed table of the queries told apart.
	Tree:         "defaultBranchRef { name target",
	Blockers:     "node(id: $id)",
	Pulls:        "pullRequests(first: 100",
	PullsByHead:  "headRefName: $branch",
	Refs:         "refs(refPrefix",
	CommentsName: "comments(first: 100) { totalCount",
	MoreComments: "comments(first: 100, after: $after)",
	MergePull:    "mergeCommit { oid",
	Readiness:    "reviewRequests(first: 100)",
	Protection:   "/protection",
}

func phrase(name string) string { return phrases[name] }

// queryOrder is the order queries are told apart in: a query is the first whose phrase it holds.
func queryOrder() []string {
	return []string{CommentsName, MoreComments, Blockers, MergePull, Readiness, Tree, PullsByHead, Pulls, Refs, Protection}
}

const probePhrase = "subIssues(first:0)"

// New returns a Router for a healthy world with an empty Epic: gh 2.102 signed in as "loop",
// origin o/r, empty answers for every query, and a default branch without protection.
func New() *Router {
	r := &Router{
		mu: sync.Mutex{}, handlers: map[string]Handler{}, exits: map[string]int{}, stderrs: map[string]string{},
		calls: nil, origin: "https://github.com/o/r.git\n", store: nil,
	}
	r.On(Protection, func(map[string]string) string { return `{"message":"Branch not protected","status":"404"}` })
	r.Exit(Protection, 1)
	r.Stderr(Protection, "gh: Branch not protected (HTTP 404)")
	r.On(Tree, func(map[string]string) string { return EpicTree("", "[]", 0, false, "") })
	r.On(Pulls, func(map[string]string) string { return PullPage("[]", false, "") })
	r.On(PullsByHead, func(map[string]string) string { return PullPage("[]", false, "") })
	r.On(Refs, func(map[string]string) string { return RefPage(false, "") })
	r.On(Git, func(map[string]string) string { return "" })
	return r
}

// On sets the handler of a query.
func (r *Router) On(name string, h Handler) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.handlers[name] = h
}

// Stderr sets the stderr a query or call returns with its body.
func (r *Router) Stderr(name, text string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.stderrs[name] = text
}

// SetOrigin sets the URL `git remote get-url origin` prints.
func (r *Router) SetOrigin(url string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.origin = url + "\n"
}

// Exit sets the exit code a query returns with its body.
func (r *Router) Exit(name string, code int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.exits[name] = code
}

// Calls returns every call made so far, each as its program followed by its arguments.
func (r *Router) Calls() [][]string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([][]string(nil), r.calls...)
}

// Count counts the calls whose arguments hold phrase.
func (r *Router) Count(phrase string) int {
	n := 0
	for _, c := range r.Calls() {
		if strings.Contains(strings.Join(c, "\n"), phrase) {
			n++
		}
	}
	return n
}

// Queries returns every call, one per line.
func (r *Router) Queries() string {
	var b strings.Builder
	for _, c := range r.Calls() {
		b.WriteString(strings.Join(c, " "))
		b.WriteString("\n")
	}
	return b.String()
}

// Vars returns the -f and -F variables of a gh call, and its query under "query".
func Vars(args []string) map[string]string {
	out := map[string]string{}
	for i := 0; i+1 < len(args); i++ {
		if args[i] == "-f" || args[i] == "-F" {
			if k, v, ok := strings.Cut(args[i+1], "="); ok {
				out[k] = v
			}
		}
	}
	return out
}

// Run answers a call.
func (r *Router) Run(_ context.Context, prog runner.Program, args []string) (runner.Result, error) {
	r.mu.Lock()
	r.calls = append(r.calls, append([]string{string(prog)}, args...))
	handlers, exits, stderrs, origin, store := r.handlers, r.exits, r.stderrs, r.origin, r.store
	r.mu.Unlock()
	if out, ok := basic(prog, args, origin); ok {
		return runner.Result{Stdout: []byte(out), Stderr: nil, ExitCode: 0}, nil
	}
	if res, ok := restResult(store, prog, args); ok {
		return res, nil
	}
	if prog == runner.Git {
		out := handlers[Git](map[string]string{"args": strings.Join(args, " ")})
		return runner.Result{Stdout: []byte(out), Stderr: []byte(stderrs[Git]), ExitCode: exits[Git]}, nil
	}
	joined := strings.Join(args, "\n")
	for _, name := range queryOrder() {
		if !strings.Contains(joined, phrase(name)) {
			continue
		}
		h, found := handlers[name]
		if !found {
			return runner.Result{}, fmt.Errorf("no handler for %s: %w", name, runner.ErrNotRecorded)
		}
		return runner.Result{Stdout: []byte(h(Vars(args))), Stderr: []byte(stderrs[name]), ExitCode: exits[name]}, nil
	}
	return runner.Result{}, fmt.Errorf("unexpected call %q: %w", args, runner.ErrNotRecorded)
}

// restResult answers a REST comment call from the store, when one serves the Router.
func restResult(store *Store, prog runner.Program, args []string) (runner.Result, bool) {
	if store == nil || prog != runner.GH || len(args) == 0 || args[0] != "api" {
		return runner.Result{Stdout: nil, Stderr: nil, ExitCode: 0}, false
	}
	out, code, ok := store.rest(args)
	var stderr []byte
	if out == notFound {
		// gh's own line for a 404, which is what tells a deleted comment from a failed read.
		stderr = []byte("gh: Not Found (HTTP 404)")
	}
	return runner.Result{Stdout: []byte(out), Stderr: stderr, ExitCode: code}, ok
}

// basic answers the calls that resolve the run's inputs, and the clock.
func basic(prog runner.Program, args []string, origin string) (string, bool) {
	if prog == runner.Git {
		if len(args) > 0 && args[0] == "remote" {
			return origin, true
		}
		return "", false
	}
	if len(args) > 0 {
		switch args[0] {
		case "--version":
			return "gh version 2.102.0 (2026-09-30)\n", true
		case "auth":
			return "", true
		}
	}
	return apiBasic(strings.Join(args, "\n"))
}

func apiBasic(joined string) (string, bool) {
	switch {
	case strings.HasSuffix(joined, "\nuser"):
		return `{"login":"loop"}`, true
	case strings.HasSuffix(joined, "\nmeta"):
		return "HTTP/2.0 200 OK\r\nDate: Mon, 19 Oct 2026 00:05:00 GMT\r\n\r\n{}", true
	case strings.Contains(joined, probePhrase):
		return `{"data":{"repository":{"defaultBranchRef":{"name":"main"},` +
			`"issue":{"number":277,"subIssues":{"totalCount":1},"blockedBy":{"totalCount":0}}}}}`, true
	default:
		return "", false
	}
}

// Comments answers the comments query for the Issues it asks for with the connections in
// byIssue, keyed by number; an Issue not in it has no comments.
func (r *Router) Comments(byIssue map[string]string) {
	r.On(CommentsName, func(v map[string]string) string { return CommentsFor(Aliased(v["query"]), byIssue) })
}

var aliasRe = regexp.MustCompile(` i([0-9]+): issue\(`)

// Aliased returns the issue numbers a comments query asks for, in order.
func Aliased(query string) []string {
	matches := aliasRe.FindAllStringSubmatch(query, -1)
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		out = append(out, m[1])
	}
	return out
}

func pageInfo(more bool, cursor string) string {
	switch {
	case !more:
		return `{"hasNextPage":false,"endCursor":null}`
	case cursor == "":
		return `{"hasNextPage":true,"endCursor":null}`
	default:
		return fmt.Sprintf(`{"hasNextPage":true,"endCursor":%q}`, cursor)
	}
}

// EpicTree answers the tree query. children is the JSON array of sub-issue nodes.
func EpicTree(body, children string, total int, more bool, cursor string) string {
	return fmt.Sprintf(`{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"base1"}},`+
		`"issue":{"number":277,"state":"OPEN","body":%q,"createdAt":"2026-10-01T00:00:00Z",`+
		`"subIssues":{"totalCount":%d,"pageInfo":%s,"nodes":%s}}}}}`, body, total, pageInfo(more, cursor), children)
}

// IssueNode is one sub-issue node. blockers and sub are JSON connections, or "" for none.
func IssueNode(n int, state, blockers, sub string) string {
	if blockers == "" {
		blockers = BlockerConn(0)
	}
	subIssues := ""
	if sub != "" {
		subIssues = `,"subIssues":` + sub
	}
	return fmt.Sprintf(`{"id":"ID%d","number":%d,"state":%q,"title":"T%d","body":"","createdAt":"2026-10-02T00:00:00Z","blockedBy":%s%s}`,
		n, n, state, n, blockers, subIssues)
}

// BlockerConn is a blockedBy connection that read total edges and returned nodes.
func BlockerConn(total int, nodes ...string) string {
	for i, node := range nodes {
		nodes[i] = strings.Replace(node, `"state":`, `"repository":{"nameWithOwner":"o/r"},"state":`, 1)
	}
	return fmt.Sprintf(`{"totalCount":%d,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}`, total, strings.Join(nodes, ","))
}

// SubConn is a subIssues connection that read total sub-issues and returned nodes.
func SubConn(total int, nodes ...string) string {
	return BlockerConn(total, nodes...)
}

// PullPage answers the pull request listing. nodes is a JSON array.
func PullPage(nodes string, more bool, cursor string) string {
	return fmt.Sprintf(`{"data":{"repository":{"pullRequests":{"pageInfo":%s,"nodes":%s}}}}`, pageInfo(more, cursor), nodes)
}

// PullNode is one pull request in the listing.
func PullNode(n int, state, branch, created string, merged bool) string {
	return PullNodeOnBase(n, state, branch, "main", "", created, merged)
}

// PullNodeOnBase is a pull request of the branch that targets the base branch, with the body.
func PullNodeOnBase(n int, state, branch, base, body, created string, merged bool) string {
	mergedAt := "null"
	if merged {
		mergedAt = `"2026-10-10T00:00:00Z"`
	}
	return fmt.Sprintf(`{"number":%d,"state":%q,"mergedAt":%s,"createdAt":%q,"headRefName":%q,"baseRefName":%q,"body":%q,"headRefOid":"sha%d","isCrossRepository":false}`,
		n, state, mergedAt, created, branch, base, body, n)
}

// ForkPullNode is a pull request whose head branch is in another repository.
func ForkPullNode(n int, state, branch, created string, merged bool) string {
	return strings.Replace(PullNode(n, state, branch, created, merged), `"isCrossRepository":false`, `"isCrossRepository":true`, 1)
}

// RefPage answers the branch listing.
func RefPage(more bool, cursor string, names ...string) string {
	nodes := make([]string, 0, len(names))
	for _, n := range names {
		nodes = append(nodes, fmt.Sprintf(`{"name":%q}`, n))
	}
	return fmt.Sprintf(`{"data":{"repository":{"refs":{"pageInfo":%s,"nodes":[%s]}}}}`, pageInfo(more, cursor), strings.Join(nodes, ","))
}

// CommentNode is one comment.
func CommentNode(id int, login, typename, association, body string) string {
	return fmt.Sprintf(`{"databaseId":%d,"createdAt":"2026-10-03T00:00:00Z","authorAssociation":%q,"author":{"__typename":%q,"login":%q},"body":%q}`,
		id, association, typename, login, body)
}

// CommentConn is a comments connection that read total comments and returned nodes.
func CommentConn(total int, more bool, cursor string, nodes ...string) string {
	return fmt.Sprintf(`{"totalCount":%d,"pageInfo":%s,"nodes":[%s]}`, total, pageInfo(more, cursor), strings.Join(nodes, ","))
}

// CommentsFor answers a comments query for the given Issue numbers.
func CommentsFor(numbers []string, byIssue map[string]string) string {
	parts := make([]string, 0, len(numbers))
	for _, n := range numbers {
		conn, found := byIssue[n]
		if !found {
			conn = CommentConn(0, false, "")
		}
		parts = append(parts, fmt.Sprintf(`"i%s":{"number":%s,"comments":%s}`, n, n, conn))
	}
	return `{"data":{"repository":{` + strings.Join(parts, ",") + `}}}`
}

// StateBody is a v2 state comment body for key and entity, with extra JSON fields after the
// envelope (each starting with a comma).
func StateBody(key, entity, extra string) string {
	return fmt.Sprintf("<!-- oe:v2 state %s -->\n```json\n{\"protocol_version\":2,\"entity\":%q,\"key\":%q,\"revision\":1,\"updated_by\":\"tok\"%s}\n```\n",
		key, entity, key, extra)
}
