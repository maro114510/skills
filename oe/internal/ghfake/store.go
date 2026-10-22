package ghfake

import (
	"encoding/json"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
)

// Stored is one comment the Store holds.
type Stored struct {
	ID          int64
	Issue       int
	Login       string
	Typename    string
	Association string
	Body        string
}

// Write is one write the Store received: its method, the Issue or comment it targets, and the
// body it carried.
type Write struct {
	Method  string
	Issue   int
	Comment int64
	Body    string
}

// WriteHook runs before a write is applied. It may change the Store, as another session
// would between a read and a write, and returns the exit code the write fails with, or 0.
// A failure returned with applied set still stores the write, as a request that landed but
// whose response was lost.
type WriteHook func(s *Store, w Write) (exit int, applied bool)

// Store is a stateful comment store for the loop's own reads and writes: it answers the
// comments query from what it holds, and the REST calls that post, edit, and read a comment.
// Everything the loop posts is authored by "loop" as OWNER.
type Store struct {
	mu     sync.Mutex
	next   int64
	all    []*Stored
	writes []Write
	hook   WriteHook
}

// NewStore returns an empty store whose next comment ID is first.
func NewStore(first int64) *Store {
	return &Store{mu: sync.Mutex{}, next: first, all: nil, writes: nil, hook: nil}
}

// Add stores a comment by login with an association and returns its ID.
func (s *Store) Add(issue int, login, association, body string) int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.addLocked(issue, login, association, body)
}

// Edit replaces the body of a stored comment, as a person editing it would.
func (s *Store) Edit(id int64, body string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.findLocked(id); c != nil {
		c.Body = body
	}
}

// Delete removes a stored comment.
func (s *Store) Delete(id int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.all = slices.DeleteFunc(s.all, func(c *Stored) bool { return c.ID == id })
}

// OnWrite sets the hook every write runs first; nil removes it.
func (s *Store) OnWrite(h WriteHook) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hook = h
}

// Comments returns the stored comments of an Issue, in ID order.
func (s *Store) Comments(issue int) []Stored {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Stored
	for _, c := range s.all {
		if c.Issue == issue {
			out = append(out, *c)
		}
	}
	return out
}

// Writes returns every write the store received, failed ones included.
func (s *Store) Writes() []Write {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.writes)
}

// Query answers a comments query from the store.
func (s *Store) Query(v map[string]string) string {
	numbers := Aliased(v["query"])
	byIssue := make(map[string]string, len(numbers))
	for _, n := range numbers {
		issue, _ := strconv.Atoi(n)
		byIssue[n] = s.conn(issue)
	}
	return CommentsFor(numbers, byIssue)
}

func (s *Store) addLocked(issue int, login, association, body string) int64 {
	id := s.next
	s.next++
	s.all = append(s.all, &Stored{ID: id, Issue: issue, Login: login, Typename: "User", Association: association, Body: body})
	return id
}

func (s *Store) findLocked(id int64) *Stored {
	for _, c := range s.all {
		if c.ID == id {
			return c
		}
	}
	return nil
}

// conn renders the comments connection of an Issue as one full page.
func (s *Store) conn(issue int) string {
	cs := s.Comments(issue)
	nodes := make([]string, 0, len(cs))
	for _, c := range cs {
		nodes = append(nodes, CommentNode(int(c.ID), c.Login, c.Typename, c.Association, c.Body))
	}
	return CommentConn(len(nodes), false, "", nodes...)
}

var (
	issueCommentsPath = regexp.MustCompile(`^repos/[^/]+/[^/]+/issues/([0-9]+)/comments$`)
	commentPath       = regexp.MustCompile(`^repos/[^/]+/[^/]+/issues/comments/([0-9]+)$`)
)

const notFound = `{"message":"Not Found"}`

// rest answers a REST comment call. It returns ok=false for a call it does not know.
func (s *Store) rest(args []string) (string, int, bool) {
	path, method, fields := restCall(args)
	if m := issueCommentsPath.FindStringSubmatch(path); m != nil && method == http.MethodPost {
		issue, _ := strconv.Atoi(m[1])
		out, code := s.write(Write{Method: method, Issue: issue, Comment: 0, Body: fields["body"]})
		return out, code, true
	}
	m := commentPath.FindStringSubmatch(path)
	if m == nil {
		return "", 0, false
	}
	id, _ := strconv.ParseInt(m[1], 10, 64)
	switch method {
	case http.MethodGet:
		s.mu.Lock()
		defer s.mu.Unlock()
		if c := s.findLocked(id); c != nil {
			return restJSON(c), 0, true
		}
		return notFound, 1, true
	case http.MethodPatch:
		out, code := s.write(Write{Method: method, Issue: 0, Comment: id, Body: fields["body"]})
		return out, code, true
	default:
		return "", 0, false
	}
}

func (s *Store) write(w Write) (string, int) {
	s.mu.Lock()
	s.writes = append(s.writes, w)
	hook := s.hook
	s.mu.Unlock()
	exit, applied := 0, true
	if hook != nil {
		exit, applied = hook(s, w)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var c *Stored
	switch {
	case !applied:
	case w.Method == http.MethodPost:
		c = s.findLocked(s.addLocked(w.Issue, "loop", "OWNER", w.Body))
	default:
		if c = s.findLocked(w.Comment); c == nil {
			return notFound, 1
		}
		c.Body = w.Body
	}
	if exit != 0 || c == nil {
		return `{"message":"Server Error"}`, max(exit, 1)
	}
	return restJSON(c), 0
}

func restJSON(c *Stored) string {
	out, _ := json.Marshal(map[string]any{
		"id": c.ID, "body": c.Body, "author_association": c.Association,
		"user": map[string]any{"login": c.Login},
	})
	return string(out)
}

// restCall splits a `gh api` REST call into its path, its method, and its -f fields. Without
// an explicit method, gh sends a GET, or a POST when the call carries fields.
func restCall(args []string) (string, string, map[string]string) {
	path, method, fields := "", "", map[string]string{}
	for i := 1; i < len(args); i++ {
		a, next := args[i], ""
		if i+1 < len(args) {
			next = args[i+1]
		}
		switch a {
		case "--hostname":
			i++
		case "-X", "--method":
			method = next
			i++
		case "-f", "-F", "--raw-field", "--field":
			k, v, _ := strings.Cut(next, "=")
			fields[k] = v
			i++
		default:
			if strings.HasPrefix(a, "repos/") {
				path = a
			}
		}
	}
	return path, restMethod(method, len(fields) > 0), fields
}

func restMethod(explicit string, hasFields bool) string {
	switch {
	case explicit != "":
		return strings.ToUpper(explicit)
	case hasFields:
		return http.MethodPost
	default:
		return http.MethodGet
	}
}

// Serve answers the comments query and the REST comment calls from the store.
func (r *Router) Serve(s *Store) {
	r.On(CommentsName, s.Query)
	r.mu.Lock()
	defer r.mu.Unlock()
	r.store = s
}

// Mutations counts the calls that would change GitHub: every `gh api` REST call that is not a
// GET.
func (r *Router) Mutations() int {
	n := 0
	for _, c := range r.Calls() {
		if len(c) < 2 || c[0] != "gh" || c[1] != "api" || slices.Contains(c, "graphql") {
			continue
		}
		if _, method, _ := restCall(c[1:]); method != http.MethodGet {
			n++
		}
	}
	return n
}
