package cmd_test

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/runner"
)

// recorder records every call of the runner it wraps, as a snapshot would hold them.
type recorder struct {
	mu    sync.Mutex
	inner runner.Runner
	calls []runner.Call
	seen  map[string]bool
}

func record(inner runner.Runner) *recorder {
	return &recorder{mu: sync.Mutex{}, inner: inner, calls: nil, seen: map[string]bool{}}
}

func (r *recorder) Run(ctx context.Context, prog runner.Program, args []string) (runner.Result, error) {
	res, err := r.inner.Run(ctx, prog, args)
	if err != nil {
		return res, err
	}
	argv := append([]string{string(prog)}, args...)
	key := strings.Join(argv, "\x00")
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.seen[key] {
		r.seen[key] = true
		r.calls = append(r.calls, runner.Call{Argv: argv, Stdout: string(res.Stdout), Stderr: string(res.Stderr), ExitCode: res.ExitCode})
	}
	return res, nil
}

// world is an Epic with a container, a cycle, a leftover token, a ready Issue, a rejected one,
// and one with work in flight.
func world() *ghfake.Router {
	r := ghfake.New()
	children := []string{
		ghfake.IssueNode(5, "OPEN", "", ghfake.SubConn(2, ghfake.IssueNode(51, "CLOSED", "", ""), ghfake.IssueNode(52, "OPEN", "", ""))),
		ghfake.IssueNode(7, "OPEN", ghfake.BlockerConn(1, `{"number":5,"state":"OPEN"}`), ""),
		ghfake.IssueNode(8, "OPEN", ghfake.BlockerConn(1, `{"number":9,"state":"OPEN"}`), ""),
		ghfake.IssueNode(9, "OPEN", ghfake.BlockerConn(1, `{"number":8,"state":"OPEN"}`), ""),
		ghfake.IssueNode(10, "OPEN", "", ""),
		ghfake.IssueNode(11, "OPEN", "", ""),
		ghfake.IssueNode(12, "OPEN", "", ""),
	}
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("tasks {{T9}}", "["+strings.Join(children, ",")+"]", len(children), false, "")
	})
	r.On(ghfake.Pulls, func(map[string]string) string {
		return ghfake.PullPage("["+ghfake.PullNode(30, "CLOSED", "feat/issue-11", "2026-10-05T00:00:00Z", false)+"]", false, "")
	})
	r.On(ghfake.Refs, func(map[string]string) string { return ghfake.RefPage(false, "", "feat/issue-12", "feat/issue-11") })
	r.On(ghfake.Git, func(map[string]string) string { return "feat/issue-12\n" })
	r.Comments(nil)
	return r
}

type boardOut struct {
	Issues []struct {
		Number int    `json:"number"`
		State  string `json:"state"`
	} `json:"issues"`
	Actions []struct {
		Kind  string `json:"kind"`
		Issue int    `json:"issue"`
	} `json:"actions"`
	Notifications []struct {
		Key string `json:"key"`
	} `json:"notifications"`
	Containers []struct {
		Number int  `json:"number"`
		Done   bool `json:"done"`
	} `json:"containers"`
}

func parseBoard(t *testing.T, r result) boardOut {
	t.Helper()
	var out boardOut
	if err := json.Unmarshal([]byte(r.stdout), &out); err != nil {
		t.Fatalf("stdout %q is not the board payload: %v", r.stdout, err)
	}
	return out
}

func (b boardOut) state(n int) string {
	for _, i := range b.Issues {
		if i.Number == n {
			return i.State
		}
	}
	return ""
}

func TestBoardClassifiesAndProposes(t *testing.T) {
	t.Parallel()

	r := run(world(), "board", "--epic", "277")
	if r.code != 0 {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	b := parseBoard(t, r)
	want := map[int]string{51: "done", 52: "ready", 7: "waiting", 8: "waiting", 9: "waiting", 10: "ready", 11: "rejected", 12: "in-progress"}
	for n, st := range want {
		if got := b.state(n); got != st {
			t.Errorf("#%d = %q, want %q", n, got, st)
		}
	}
	if b.state(5) != "" {
		t.Error("the container was classified as a unit of work")
	}
	if got := b.dispatched(); !slices.Equal(got, []int{12, 10, 52}) {
		t.Errorf("dispatch = %v, want the resumed #12 first, then #10 and #52, none of the cycle", got)
	}
	keys := b.keys()
	if len(keys) != 3 || keys[0] != "dep-cycle:8,9" || !strings.HasPrefix(keys[1], "leftover-placeholder:277:") || keys[2] != "rejected:11:30" {
		t.Errorf("notes = %v, want one cycle note, one token note, and the rejection", keys)
	}
}

func (b boardOut) dispatched() []int {
	var out []int
	for _, a := range b.Actions {
		if a.Kind == "dispatch" {
			out = append(out, a.Issue)
		}
	}
	return out
}

func (b boardOut) keys() []string {
	out := make([]string, 0, len(b.Notifications))
	for _, n := range b.Notifications {
		out = append(out, n.Key)
	}
	return out
}

// TestBoardNeverPrintsABody: bodies are searched for placeholder tokens but never printed.
func TestBoardNeverPrintsABody(t *testing.T) {
	t.Parallel()

	r := run(world(), "board", "--epic", "277")
	if strings.Contains(r.stdout, "tasks") {
		t.Errorf("stdout %q holds the Epic body", r.stdout)
	}
}

// assertReadOnly fails for any call that is not a read.
func assertReadOnly(t *testing.T, calls [][]string) {
	t.Helper()
	for _, c := range calls {
		if why := writes(c); why != "" {
			t.Errorf("call %q %s", strings.Join(c, " "), why)
		}
	}
}

func writes(c []string) string {
	line := strings.ToLower(strings.Join(c, " "))
	switch {
	case c[0] == "git":
		return gitWrite(c)
	case strings.Contains(line, "graphql") && !strings.Contains(line, "query=query"):
		return "is not a GraphQL query"
	case strings.Contains(line, "mutation"):
		return "holds a mutation"
	case strings.Contains(line, " -x ") || strings.Contains(line, "--method"):
		return "sends a request that is not a GET"
	case slices.Contains(c, "comment") || slices.Contains(c, "merge"):
		return "comments or merges"
	default:
		return ""
	}
}

func gitWrite(c []string) string {
	if c[1] == "remote" || c[1] == "for-each-ref" {
		return ""
	}
	return "is not a git read"
}

// TestBoardNeverWrites guards the zero-write requirement over a live run: every call is a read.
func TestBoardNeverWrites(t *testing.T) {
	t.Parallel()

	router := world()
	if first := run(router, "board", "--epic", "277"); first.code != 0 {
		t.Fatalf("exit %d, stdout %q", first.code, first.stdout)
	}
	assertReadOnly(t, router.Calls())
}

// TestBoardReplaysFromASnapshot: a snapshot recorded from a live run replays to the same output
// without starting a process.
func TestBoardReplaysFromASnapshot(t *testing.T) {
	t.Parallel()

	live := record(world())
	first := run(live, "board", "--epic", "277")
	path := writeSnapshot(t, live.calls)
	dead := newSpy(nil)
	second := run(dead, "--snapshot", path, "board", "--epic", "277")
	third := run(dead, "--snapshot", path, "board", "--epic", "277")
	if second != first || third != first {
		t.Errorf("a replay differs from the live run:\n live %q\n 2nd  %q", first.stdout, second.stdout)
	}
	if dead.count() != 0 {
		t.Errorf("real calls under --snapshot = %d, want none", dead.count())
	}
}

func TestBoardStopsOnATruncatedPRListing(t *testing.T) {
	t.Parallel()

	r := world()
	r.On(ghfake.Pulls, func(v map[string]string) string {
		if v["after"] == "" {
			return ghfake.PullPage("["+ghfake.PullNode(30, "CLOSED", "feat/issue-11", "2026-10-05T00:00:00Z", false)+"]", true, "p1")
		}
		return `{"errors":[{"message":"boom"}],"data":null}`
	})
	r.Exit(ghfake.Pulls, 0)
	res := run(r, "board", "--epic", "277")
	wantOneLine(t, res, 1, "unreadable:")
	if strings.Contains(res.stdout, "ready") || strings.Contains(res.stdout, "in-progress") {
		t.Errorf("stdout %q classified something from a partial read", res.stdout)
	}
}

func TestBoardStopsOnAForeignLeaseAndOnV1Markers(t *testing.T) {
	t.Parallel()

	lease := ghfake.StateBody("lease", "lease", `,"token":"other","host":"h","pid":42,"started_at":"a","renewed_at":"b"`)
	r := world()
	r.Comments(map[string]string{"277": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "loop", "User", "OWNER", lease))})
	wantOneLine(t, run(r, "board", "--epic", "277"), 7, "coordination:")

	own := world()
	own.Comments(map[string]string{"277": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "loop", "User", "OWNER", lease))})
	if res := run(own, "board", "--epic", "277", "--lease-token", "other"); res.code != 0 {
		t.Errorf("the lease holder's own board read: exit %d, %q", res.code, res.stdout)
	}

	v1 := world()
	v1.Comments(map[string]string{"277": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "loop", "User", "OWNER", "<!-- orchestrate-epic:ledger -->"))})
	wantOneLine(t, run(v1, "board", "--epic", "277"), 6, "protocol:")
}

// TestBoardObserveShowsTheBoardBesideAForeignLease: --observe is for a person reading the board.
// It names the lease holder and proposes nothing, so it cannot drive a second Publisher.
func TestBoardObserveShowsTheBoardBesideAForeignLease(t *testing.T) {
	t.Parallel()

	lease := ghfake.StateBody("lease", "lease", `,"token":"other","host":"h","pid":42,"started_at":"a","renewed_at":"b"`)
	r := world()
	r.Comments(map[string]string{"277": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "loop", "User", "OWNER", lease))})
	res := run(r, "board", "--epic", "277", "--observe")
	if res.code != 0 {
		t.Fatalf("exit %d, stdout %q", res.code, res.stdout)
	}
	var out struct {
		Lease   *struct{ Host string } `json:"lease"`
		Actions []json.RawMessage      `json:"actions"`
		Issues  []json.RawMessage      `json:"issues"`
	}
	if err := json.Unmarshal([]byte(res.stdout), &out); err != nil {
		t.Fatalf("stdout %q: %v", res.stdout, err)
	}
	if out.Lease == nil || out.Lease.Host != "h" || len(out.Actions) != 0 || len(out.Issues) == 0 {
		t.Errorf("lease = %+v, actions = %d, issues = %d; want the holder named, no actions, the board shown", out.Lease, len(out.Actions), len(out.Issues))
	}
}

func TestBoardNeedsAnEpic(t *testing.T) {
	t.Parallel()

	s := newSpy(nil)
	wantOneLine(t, run(s, "board"), 2, "never guesses")
	if s.count() != 0 {
		t.Errorf("calls = %d, want none", s.count())
	}
}

const cleanPull = `{"data":{"repository":{"pullRequest":{"number":7,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE",` +
	`"mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","isMergeQueueEnabled":false,"headRefOid":"abc123",` +
	`"reviewRequests":{"totalCount":0,"nodes":[]},` +
	`"latestOpinionatedReviews":{"totalCount":1,"nodes":[{"state":"APPROVED","author":{"login":"alice"}}]},` +
	`"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":true}]},` +
	`"commits":{"nodes":[{"commit":{"oid":"abc123","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":1,"nodes":[` +
	`{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}}}}]}}}}}`

func TestReadinessPrintsTheClassification(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Readiness, func(v map[string]string) string {
		if v["num"] != "7" || v["owner"] != "o" || v["repo"] != "r" {
			t.Errorf("vars = %v, want o/r #7", v)
		}
		return cleanPull
	})
	res := run(r, "readiness", "--epic", "277", "--pr", "7")
	want := `{"status":"READY","reason":"checks and reviews complete, merge state CLEAN","pr":7,"head":"abc123","next":"merge"}` + "\n"
	if res.code != 0 || res.stdout != want {
		t.Errorf("exit %d, stdout %q; want 0, %q", res.code, res.stdout, want)
	}
}

func TestReadinessHoldsOnAnUnreadableSignal(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Readiness, func(map[string]string) string {
		return strings.Replace(cleanPull, `"isDraft":false,`, "", 1)
	})
	res := run(r, "readiness", "--epic", "277", "--pr", "7")
	wantOneLine(t, res, 1, "isDraft missing")
	if !strings.Contains(res.stdout, "next human") {
		t.Errorf("stdout %q, want the hold named", res.stdout)
	}
}

func TestReadinessHoldsOnGraphQLErrorsAndAMissingPR(t *testing.T) {
	t.Parallel()

	for name, body := range map[string]string{
		"errors":  `{"errors":[{"message":"boom"}],"data":null}`,
		"no PR":   `{"data":{"repository":{"pullRequest":null}}}`,
		"partial": strings.Replace(cleanPull, `{"data":`, `{"errors":[{"message":"rate limit"}],"data":`, 1),
	} {
		r := ghfake.New()
		r.On(ghfake.Readiness, func(map[string]string) string { return body })
		r.Exit(ghfake.Readiness, 1)
		if name == "no PR" {
			r.Exit(ghfake.Readiness, 0)
		}
		wantOneLine(t, run(r, "readiness", "--epic", "277", "--pr", "7"), 1, "unreadable:")
	}
}

func TestReadinessNeedsAPR(t *testing.T) {
	t.Parallel()

	for _, args := range [][]string{{"readiness", "--epic", "277"}, {"readiness", "--epic", "277", "--pr", "0"}, {"readiness", "--epic", "277", "--pr", "x"}} {
		s := newSpy(nil)
		wantOneLine(t, run(s, args...), 2, "usage:")
		if s.count() != 0 {
			t.Errorf("%v: calls = %d, want none", args, s.count())
		}
	}
}

func postMerge(pr, issue int) string {
	return ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "loop", "User", "OWNER", ghfake.StateBody("post-merge", "post-merge",
		`,"pr":`+itoa(pr)+`,"issue":`+itoa(issue)+`,"reviewed_sha":"h","verified_base":"b","phase":"merged","merge_sha":"m111","requested_at":"t"`)))
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func healthWorld(pull string, exit int) *ghfake.Router {
	r := ghfake.New()
	r.Comments(map[string]string{"277": postMerge(7, 45)})
	r.On(ghfake.MergePull, func(map[string]string) string { return pull })
	r.Exit(ghfake.MergePull, exit)
	return r
}

const passingPull = `{"data":{"repository":{"pullRequest":{"number":7,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",` +
	`"mergeCommit":{"oid":"m111","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":1,"nodes":[` +
	`{"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T00:00:10Z","checkSuite":{"databaseId":1}}]}}}}}}}`

func TestHealthPrintsTheClassification(t *testing.T) {
	t.Parallel()

	res := run(healthWorld(passingPull, 0), "health", "--epic", "277")
	want := `{"status":"PASS","reason":"every check on m111 passed","record_id":1,"pr":7,"issue":45,"merge":"m111","next":"proceed"}` + "\n"
	if res.code != 0 || res.stdout != want {
		t.Errorf("exit %d, stdout %q; want 0, %q", res.code, res.stdout, want)
	}
}

func TestHealthWithNoRecordIsClear(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.Comments(nil)
	res := run(r, "health", "--epic", "277")
	want := `{"status":"CLEAR","reason":"no loop merge recorded","record_id":0,"next":"proceed"}` + "\n"
	if res.code != 0 || res.stdout != want {
		t.Errorf("exit %d, stdout %q; want 0, %q", res.code, res.stdout, want)
	}
}

func TestHealthHoldsOnGraphQLErrors(t *testing.T) {
	t.Parallel()

	res := run(healthWorld(`{"errors":[{"type":"RATE_LIMITED","message":"rate limited"}],"data":null}`, 1), "health", "--epic", "277")
	wantOneLine(t, res, 1, "rate limited")

	// A merge whose checks cannot be read is held, and exits 1 with one verdict line.
	truncated := strings.Replace(passingPull, `"totalCount":1`, `"totalCount":101`, 1)
	wantOneLine(t, run(healthWorld(truncated, 0), "health", "--epic", "277"), 1, "checks truncated on m111")
}

func TestClassifiersNeverMutateUnderSnapshot(t *testing.T) {
	t.Parallel()

	// Only a snapshot with every read answers; the classifiers must work from it alone.
	rec := record(healthWorld(passingPull, 0))
	live := run(rec, "health", "--epic", "277")
	path := writeSnapshot(t, rec.calls)
	dead := newSpy(nil)
	if replay := run(dead, "--snapshot", path, "health", "--epic", "277"); replay != live || dead.count() != 0 {
		t.Errorf("replay %+v differs from live %+v or made real calls", replay, live)
	}
}
