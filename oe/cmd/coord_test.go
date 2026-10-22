package cmd_test

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/cmd"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/runner"
	"github.com/maro114510/skills/oe/internal/state"
)

// coordWorld is an Epic with one open child, #7, whose comments live in a store, and a state
// directory of its own so no test touches the real lock directory.
type coordWorld struct {
	r     *ghfake.Router
	store *ghfake.Store
	dir   string
}

func newCoordWorld(t *testing.T) *coordWorld {
	t.Helper()
	w := &coordWorld{r: ghfake.New(), store: ghfake.NewStore(100), dir: t.TempDir()}
	w.r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(7, "OPEN", "", "")+"]", 1, false, "")
	})
	w.r.Serve(w.store)
	return w
}

func (w *coordWorld) run(args ...string) result {
	return runEnv(w.r, w.dir, "", args...)
}

func runEnv(exec runner.Runner, dir, stdin string, args ...string) result {
	var out, errOut bytes.Buffer
	code := cmd.Main(args, cmd.Env{
		Stdin: strings.NewReader(stdin), Stdout: &out, Stderr: &errOut, Exec: exec, Version: "v1.2.3",
		Getenv:   func(k string) string { return map[string]string{"XDG_STATE_HOME": dir}[k] },
		Hostname: func() (string, error) { return "host-a", nil },
	})
	return result{code: code, stdout: out.String(), stderr: errOut.String()}
}

func (w *coordWorld) acquire(t *testing.T) string {
	t.Helper()
	r := w.run("--epic", "277", "lease", "acquire", "--pid", "4242")
	if r.code != 0 {
		t.Fatalf("acquire: exit %d, %q", r.code, r.stdout)
	}
	var res coord.LeaseResult
	if err := json.Unmarshal([]byte(r.stdout), &res); err != nil || res.Token == "" {
		t.Fatalf("acquire printed %q", r.stdout)
	}
	return res.Token
}

func (w *coordWorld) put(t *testing.T, issue int, s protocol.State) {
	t.Helper()
	s.StateEnvelope().UpdatedBy = "earlier"
	s.StateEnvelope().Revision = 1
	body, err := protocol.EncodeState(s)
	if err != nil {
		t.Fatal(err)
	}
	w.store.Add(issue, "loop", "OWNER", body)
}

func coordCommands(token string) map[string][]string {
	tok := []string{"--lease-token", token}
	return map[string][]string{
		"lease end":           append([]string{"lease", "end"}, tok...),
		"note post":           append([]string{"note", "post", "--on", "7", "--key", "start:7:feat/issue-7"}, tok...),
		"ledger create":       append([]string{"ledger", "create"}, tok...),
		"ledger check":        append([]string{"ledger", "check"}, tok...),
		"ledger reserve":      append([]string{"ledger", "reserve", "--worker-dispatches", "1"}, tok...),
		"ledger freeze":       append([]string{"ledger", "freeze", "--reason", "x"}, tok...),
		"ledger release":      append([]string{"ledger", "release"}, tok...),
		"state start":         append([]string{"state", "start", "--issue", "7"}, tok...),
		"state apply-signals": append([]string{"state", "apply-signals", "--issue", "7"}, tok...),
		"state park":          append([]string{"state", "park", "--issue", "7", "--blocker", "x"}, tok...),
		"state invalidate":    append([]string{"state", "invalidate-approval", "--issue", "7"}, tok...),
		"gate":                append([]string{"gate"}, tok...),
	}
}

// TestCoordinationRefusesUnderSnapshot: every coordination subcommand, lease acquire included,
// exits 8 under --snapshot before any call.
func TestCoordinationRefusesUnderSnapshot(t *testing.T) {
	t.Parallel()

	path := writeSnapshot(t, healthy(probeOK, 0))
	cmds := coordCommands("tok")
	cmds["lease acquire"] = []string{"lease", "acquire", "--pid", "1"}
	for name, args := range cmds {
		s := newSpy(healthy(probeOK, 0))
		r := runEnv(s, t.TempDir(), "x", append([]string{"--snapshot", path, "--epic", "277"}, args...)...)
		if r.code != 8 || !strings.Contains(r.stdout, "--snapshot disables every mutation") || s.count() != 0 {
			t.Errorf("%s: exit %d, stdout %q, calls %d", name, r.code, r.stdout, s.count())
		}
	}
}

func TestCoordinationNeedsALeaseToken(t *testing.T) {
	t.Parallel()

	for name, args := range coordCommands("") {
		s := newSpy(healthy(probeOK, 0))
		r := runEnv(s, t.TempDir(), "x", append([]string{"--epic", "277"}, args...)...)
		if r.code != 2 || s.count() != 0 {
			t.Errorf("%s: exit %d, stdout %q, calls %d", name, r.code, r.stdout, s.count())
		}
	}
}

// TestForeignLeaseStopsEveryMutatingCommand: with the lease held by another host's session,
// every coordination subcommand exits 7, writes nothing, and never takes the lease over.
func TestForeignLeaseStopsEveryMutatingCommand(t *testing.T) {
	t.Parallel()

	for name, args := range coordCommands("mine") {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w := newCoordWorld(t)
			var l state.Lease
			l.Entity, l.Key = state.EntityLease, state.KeyLease
			l.Token, l.Host, l.PID, l.StartedAt, l.RenewedAt = "theirs", "host-b", 1, "2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z"
			w.put(t, 277, &l)
			r := runEnv(w.r, w.dir, "x", append([]string{"--epic", "277"}, args...)...)
			if r.code != 7 || w.r.Mutations() != 0 {
				t.Errorf("exit %d, stdout %q, mutations %d", r.code, r.stdout, w.r.Mutations())
			}
		})
	}
	w := newCoordWorld(t)
	var l state.Lease
	l.Entity, l.Key = state.EntityLease, state.KeyLease
	l.Token, l.Host, l.PID, l.StartedAt, l.RenewedAt = "theirs", "host-b", 1, "2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z"
	w.put(t, 277, &l)
	if r := w.run("--epic", "277", "lease", "acquire", "--pid", "4242"); r.code != 7 || w.r.Mutations() != 0 {
		t.Errorf("acquire over a foreign lease: exit %d, %q", r.code, r.stdout)
	}
}

// TestSecondProcessStopsOnTheEpicLock: while another process holds the Epic's lock, a command
// stops with exit 7 and writes nothing.
func TestSecondProcessStopsOnTheEpicLock(t *testing.T) {
	t.Parallel()

	w := newCoordWorld(t)
	token := w.acquire(t)
	held := coord.New(coord.Config{Client: nil, Inputs: resolvedInputs(), Token: "", LockDir: w.dir + "/oe/locks", Host: "h", Alive: nil, Now: nil})
	if err := held.Lock(); err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	before := w.r.Mutations()
	r := w.run("--epic", "277", "note", "post", "--on", "7", "--key", "start:7:feat/issue-7", "--lease-token", token)
	if r.code != 7 || !strings.Contains(r.stdout, "lock") || w.r.Mutations() != before {
		t.Errorf("exit %d, stdout %q", r.code, r.stdout)
	}
}

func TestCoordinationFlow(t *testing.T) {
	t.Parallel()

	w := newCoordWorld(t)
	token := w.acquire(t)
	tok := []string{"--lease-token", token}
	for range 2 {
		runEnv(w.r, w.dir, "着手しました", append([]string{"--epic", "277", "note", "post", "--on", "7", "--key", "start:7:feat/issue-7"}, tok...)...)
	}
	if n := countPrefix(w.store.Comments(7), "<!-- oe:v2 note start:7:feat/issue-7 -->"); n != 1 {
		t.Errorf("start notes = %d, want 1", n)
	}
	steps := []struct {
		args []string
		code int
		want string
	}{
		{[]string{"ledger", "create"}, 0, `"n":1`},
		{[]string{"ledger", "reserve", "--worker-dispatches", "5"}, 0, `"granted":true`},
		{[]string{"ledger", "reserve", "--worker-dispatches", "1"}, 4, `worker_dispatches 5 + 1 \u003e 5`},
		{[]string{"ledger", "check"}, 4, `"status":"FROZEN"`},
		{[]string{"ledger", "release"}, 4, `"released":false`},
		{[]string{"state", "start", "--issue", "7"}, 0, `"branch":"feat/issue-7"`},
		{[]string{"state", "park", "--issue", "7", "--blocker", "cap"}, 0, `"unresolved_blockers":["cap"]`},
	}
	for _, s := range steps {
		r := w.run(append(append([]string{"--epic", "277"}, s.args...), tok...)...)
		if r.code != s.code || strings.Count(r.stdout, "\n") != 1 || !strings.Contains(r.stdout, s.want) {
			t.Fatalf("%v: exit %d, stdout %q; want %d with %s", s.args, r.code, r.stdout, s.code, s.want)
		}
	}
	w.store.Add(277, "alice", "MEMBER", "epic-release")
	w.store.Add(7, "alice", "MEMBER", "epic-retry")
	w.wantRun(t, tok, []string{"ledger", "release"}, `"released":true`)
	w.wantRun(t, tok, []string{"state", "apply-signals", "--issue", "7"}, `"command":"epic-retry"`)
	w.wantRun(t, tok, []string{"lease", "end"}, `"pid":0`)
}

func (w *coordWorld) wantRun(t *testing.T, tok, args []string, want string) {
	t.Helper()
	r := w.run(append(append([]string{"--epic", "277"}, args...), tok...)...)
	if r.code != 0 || !strings.Contains(r.stdout, want) {
		t.Errorf("%v: exit %d, stdout %q; want %s", args, r.code, r.stdout, want)
	}
}

func TestNoteWithASecretPrintsTheReportAndExits8(t *testing.T) {
	t.Parallel()

	w := newCoordWorld(t)
	token := w.acquire(t)
	before := w.r.Mutations()
	r := runEnv(w.r, w.dir, "AKIA"+strings.Repeat("Q", 16), "--epic", "277", "note", "post", "--on", "7", "--key", "qa:7:{digest}", "--lease-token", token)
	if r.code != 8 || !strings.Contains(r.stdout, `"rule":"aws-access-key"`) || strings.Contains(r.stdout, "AKIA") || w.r.Mutations() != before {
		t.Errorf("exit %d, stdout %q", r.code, r.stdout)
	}
}

func TestStateCommandsRejectAnIssueOutsideTheEpic(t *testing.T) {
	t.Parallel()

	w := newCoordWorld(t)
	token := w.acquire(t)
	before := w.r.Mutations()
	r := w.run("--epic", "277", "state", "start", "--issue", "99", "--lease-token", token)
	if r.code != 8 || w.r.Mutations() != before {
		t.Errorf("exit %d, stdout %q", r.code, r.stdout)
	}
}

// TestStartNeedsAReadyOrInProgressIssue: a waiting Issue gets no state, so it is never proposed
// for dispatch before its dependencies are done.
func TestStartNeedsAReadyOrInProgressIssue(t *testing.T) {
	t.Parallel()

	w := newCoordWorld(t)
	w.r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(7, "OPEN", ghfake.BlockerConn(1, `{"number":9,"state":"OPEN"}`), "")+"]", 1, false, "")
	})
	token := w.acquire(t)
	before := w.r.Mutations()
	r := w.run("--epic", "277", "state", "start", "--issue", "7", "--lease-token", token)
	if r.code != 8 || !strings.Contains(r.stdout, "waiting") || w.r.Mutations() != before {
		t.Errorf("exit %d, stdout %q", r.code, r.stdout)
	}
}

func countPrefix(cs []ghfake.Stored, prefix string) int {
	n := 0
	for _, c := range cs {
		if strings.HasPrefix(c.Body, prefix) {
			n++
		}
	}
	return n
}

func resolvedInputs() inputs.Inputs {
	return inputs.Inputs{Repo: "o/r", Epic: 277, Me: "loop", DefaultBranch: "main", MaxParallel: 3, MaxParallelReason: "", GHVersion: "2.102.0"}
}
