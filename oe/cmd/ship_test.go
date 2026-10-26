package cmd_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/maro114510/skills/oe/cmd"
	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/ship"
	"github.com/maro114510/skills/oe/internal/state"
)

// prBoard is the pull requests the fake GitHub holds, by head branch.
type prBoard struct {
	mu  sync.Mutex
	prs []boardPR
}

type boardPR struct {
	number int
	state  string
	branch string
}

func (b *prBoard) add(branch, prState string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := firstPR + len(b.prs)
	b.prs = append(b.prs, boardPR{number: n, state: prState, branch: branch})
	return n
}

func (b *prBoard) count() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.prs)
}

// listing answers the per-branch pull request query.
func (b *prBoard) listing(v map[string]string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	var nodes []string
	for _, pr := range b.prs {
		if pr.branch == v["branch"] {
			nodes = append(nodes, ghfake.PullNode(pr.number, pr.state, pr.branch, "2026-10-05T00:00:00Z", pr.state == "MERGED"))
		}
	}
	return ghfake.PullPage("["+strings.Join(nodes, ",")+"]", false, "")
}

// fakeScripts stands in for the create-pr scripts. issue-refs.sh runs for real, since it only reads git;
// create-linked-pr.sh would call gh, so it opens a pull request on the board instead.
type fakeScripts struct {
	mu    sync.Mutex
	board *prBoard

	calls  []ship.Script
	bodies []string
	// refs replaces the issue-refs.sh result when set.
	refs *ship.ScriptResult
	// createExit and linkExit are the exit codes of the create and link runs.
	createExit, linkExit int
	// failBeforeCreate is a process that cannot start; crashAfterCreate dies once the pull request exists.
	failBeforeCreate, crashAfterCreate bool
}

func (f *fakeScripts) RunScript(ctx context.Context, s ship.Script) (ship.ScriptResult, error) {
	f.mu.Lock()
	f.calls = append(f.calls, s)
	f.mu.Unlock()
	switch filepath.Base(s.Path) {
	case "issue-refs.sh":
		if f.refs != nil {
			return *f.refs, nil
		}
		return ship.Exec{}.RunScript(ctx, s)
	case "create-linked-pr.sh":
		return f.createOrLink(s)
	}
	return ship.ScriptResult{}, fmt.Errorf("unexpected script %s", s.Path)
}

func (f *fakeScripts) createOrLink(s ship.Script) (ship.ScriptResult, error) {
	if i := slices.Index(s.Args, "--link"); i >= 0 {
		return ship.ScriptResult{ExitCode: f.linkExit, Stdout: "LINKED #7\n", Stderr: ""}, nil
	}
	if f.failBeforeCreate {
		return ship.ScriptResult{}, errors.New("the script could not start")
	}
	body, err := os.ReadFile(s.Args[slices.Index(s.Args, "--body-file")+1])
	if err != nil {
		return ship.ScriptResult{}, err
	}
	f.mu.Lock()
	f.bodies = append(f.bodies, string(body))
	f.mu.Unlock()
	n := f.board.add(s.Args[slices.Index(s.Args, "--head")+1], "OPEN")
	if f.crashAfterCreate {
		return ship.ScriptResult{}, errors.New("the process was killed after the pull request existed")
	}
	return ship.ScriptResult{ExitCode: f.createExit, Stdout: fmt.Sprintf("https://github.com/o/r/pull/%d\n", n), Stderr: ""}, nil
}

func (f *fakeScripts) created() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.bodies)
}

func (f *fakeScripts) linked() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if slices.Contains(c.Args, "--link") {
			n++
		}
	}
	return n
}

// fakeChecks stands in for the CHECKS_SET commands.
type fakeChecks struct {
	mu     sync.Mutex
	runs   int
	exit   int
	output string
	// during runs while a check runs, as another Publisher would.
	during func()
}

func (f *fakeChecks) RunCheck(context.Context, checks.Command) (checks.CommandResult, error) {
	f.mu.Lock()
	f.runs++
	during, exit, out := f.during, f.exit, f.output
	f.mu.Unlock()
	if during != nil {
		during()
	}
	return checks.CommandResult{ExitCode: exit, Stdout: out, Stderr: "", StartError: ""}, nil
}

func (f *fakeChecks) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.runs
}

// shipFlow is an Issue whose approval is bound at its pinned head and base, ready to ship.
type shipFlow struct {
	reviewFlow

	// approved is the head the approval binds: oe's merge commit on the worker's head.
	approved   string
	board      *prBoard
	scripts    *fakeScripts
	checks     *fakeChecks
	report     string
	scriptsDir string
}

func newShipFlow(t *testing.T, skipped string) shipFlow {
	t.Helper()
	f := newReviewFlow(t, "w.txt", "b.txt")
	p := f.pin(t)
	if v := f.verdict(t, p.Head); v.Route != "BOUND" {
		t.Fatalf("verdict = %+v", v)
	}
	if err := os.MkdirAll(filepath.Join(f.wt, "oe"), 0o750); err != nil {
		t.Fatal(err)
	}
	scriptsDir, err := filepath.Abs("../../skills/create-pr/scripts")
	if err != nil {
		t.Fatal(err)
	}
	board := &prBoard{}
	f.w.r.On(ghfake.PullsByHead, board.listing)
	report := "STATUS: DONE\nISSUE: #7\nBRANCH: feat/issue-7\nWORKTREE: " + f.wt + "\nHEAD_SHA: " + f.head +
		"\nCHECKS: go test ./... -> exit 0\nCRITERIA: WORKER-ONLY claim -> [behavior] unchecked\nSKIPPED: " + skipped + "\nSUMMARY: adds w.txt\n"
	path := filepath.Join(t.TempDir(), "report.md")
	if err := os.WriteFile(path, []byte(report), 0o600); err != nil {
		t.Fatal(err)
	}
	return shipFlow{
		reviewFlow: f, approved: p.Head, board: board,
		scripts: &fakeScripts{board: board}, checks: &fakeChecks{}, report: path, scriptsDir: scriptsDir,
	}
}

func (s shipFlow) args(extra ...string) []string {
	args := make([]string, 0, 20+len(s.tok)+len(extra))
	args = append(args, "--epic", "277", "ship", "publish", "--issue", "7", "--worktree", s.wt, "--checks-set", s.set,
		"--title", "Add w.txt", "--report-file", s.report, "--create-pr-scripts", s.scriptsDir)
	return append(append(args, s.tok...), extra...)
}

// publish runs oe ship publish as a fresh process.
func (s shipFlow) publish(extra ...string) result {
	var out, errOut bytes.Buffer
	code := cmd.Main(s.args(extra...), cmd.Env{
		Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errOut, Exec: s.tr, Version: "v1.2.3",
		Getenv:   func(k string) string { return map[string]string{"XDG_STATE_HOME": s.w.dir}[k] },
		Hostname: func() (string, error) { return "host-a", nil },
		Checks:   s.checks, Scripts: s.scripts,
	})
	return result{code: code, stdout: out.String(), stderr: errOut.String()}
}

type shipped struct {
	Route   string `json:"route"`
	Next    string `json:"next"`
	Reason  string `json:"reason"`
	Link    string `json:"link"`
	PR      int    `json:"pr"`
	Pushed  bool   `json:"pushed"`
	Created bool   `json:"created"`
	Resumed bool   `json:"resumed"`
	State   struct {
		UnresolvedBlockers []string `json:"unresolved_blockers"`
		Approval           *struct {
			ReviewedSHA string `json:"reviewed_sha"`
		} `json:"approval"`
		Publish *struct {
			SHA     string `json:"sha"`
			PrevSHA string `json:"prev_sha"`
			Base    string `json:"base"`
			PR      int    `json:"pr"`
			Phase   string `json:"phase"`
		} `json:"publish"`
	} `json:"state"`
}

// remoteHead is the branch on origin, or "" when it is not there.
func (s shipFlow) remoteHead(t *testing.T) string {
	t.Helper()
	out := gitIn(t, s.shared, "ls-remote", "origin", "refs/heads/feat/issue-7")
	if out == "" {
		return ""
	}
	return strings.Fields(out)[0]
}

// pushes lists the git push calls oe made.
func (s shipFlow) pushes() [][]string {
	var out [][]string
	for _, args := range s.tr.git {
		if subcommand(args) == "push" {
			out = append(out, args)
		}
	}
	return out
}

// stateOf reads the Issue's state from the store.
func (s shipFlow) stateOf(t *testing.T) state.Issue {
	t.Helper()
	var st state.Issue
	for _, c := range s.w.store.Comments(7) {
		if strings.HasPrefix(c.Body, "<!-- oe:v2 state issue:7 -->") {
			if _, err := protocol.DecodeState(c.Body, &st); err != nil {
				t.Fatal(err)
			}
		}
	}
	return st
}

func (s shipFlow) noteKeys(prefix string) int {
	return countPrefix(s.w.store.Comments(7), "<!-- oe:v2 note "+prefix)
}

// wantNothingPublished checks that no push, pull request, or publish record exists.
func (s shipFlow) wantNothingPublished(t *testing.T) {
	t.Helper()
	if got := s.remoteHead(t); got != "" {
		t.Errorf("origin holds the branch at %s", got)
	}
	if n := s.board.count(); n != 0 {
		t.Errorf("%d pull requests exist", n)
	}
	if p := s.pushes(); len(p) != 0 {
		t.Errorf("oe pushed: %v", p)
	}
	if st := s.stateOf(t); st.Publish != nil {
		t.Errorf("a publish was recorded: %+v", st.Publish)
	}
}

// failWritesOf makes every state write whose body holds text fail without landing, as a crash at that write would.
func (s shipFlow) failWritesOf(text string) {
	s.w.store.OnWrite(func(_ *ghfake.Store, w ghfake.Write) (int, bool) {
		if strings.Contains(w.Body, text) {
			return 1, false
		}
		return 0, true
	})
}

// freezeFromAnotherPublisher freezes the Epic's ledger as a second session would.
func (s shipFlow) freezeFromAnotherPublisher(t *testing.T) {
	t.Helper()
	for _, c := range s.w.store.Comments(277) {
		if !strings.HasPrefix(c.Body, "<!-- oe:v2 state ledger -->") {
			continue
		}
		var l state.Ledger
		if _, err := protocol.DecodeState(c.Body, &l); err != nil {
			t.Fatal(err)
		}
		l.Revision++
		l.FreezeSeq = 1
		l.Freeze = &state.Freeze{Seq: 1, Reason: "a merge broke the default branch", MergeSHA: "", Health: "", Released: false}
		body, err := protocol.EncodeState(&l)
		if err != nil {
			t.Fatal(err)
		}
		s.w.store.Edit(c.ID, body)
		return
	}
	t.Fatal("the Epic has no ledger")
}

// firstPR is the number the fake GitHub gives the first pull request.
const firstPR = 30

// wantPublished checks a run that published and linked the pull request.
func wantPublished(t *testing.T, r result, got shipped) {
	t.Helper()
	if r.code != 0 || got.Route != "PUBLISHED" || got.Next != "land" || got.PR != firstPR {
		t.Fatalf("exit %d, publish = %+v", r.code, got)
	}
	if p := got.State.Publish; p == nil || p.Phase != "linked" || p.PR != firstPR {
		t.Fatalf("publish record = %+v, want linked to #%d", p, firstPR)
	}
}

// wantPushedExactly checks that origin holds the approved head, pushed once by oe, never forced, with hooks off.
func (s shipFlow) wantPushedExactly(t *testing.T) {
	t.Helper()
	if rem := s.remoteHead(t); rem != s.approved {
		t.Errorf("origin holds %s, want the approved head %s", rem, s.approved)
	}
	pushes := s.pushes()
	if len(pushes) != 1 {
		t.Fatalf("pushes = %v, want exactly one", pushes)
	}
	line := strings.Join(pushes[0], " ")
	for _, want := range []string{"core.hooksPath=" + os.DevNull, "push --no-verify origin " + s.approved + ":refs/heads/feat/issue-7"} {
		if !strings.Contains(line, want) {
			t.Errorf("push %q lacks %q", line, want)
		}
	}
	for _, bad := range []string{"--force", " -f ", "--force-with-lease", "--delete"} {
		if strings.Contains(line, bad) {
			t.Errorf("push %q carries %q", line, bad)
		}
	}
}

// wantBody checks the body of the pull request oe opened.
func (s shipFlow) wantBody(t *testing.T, closing string) {
	t.Helper()
	if len(s.scripts.bodies) != 1 {
		t.Fatalf("bodies = %d, want one", len(s.scripts.bodies))
	}
	if strings.Contains(s.scripts.bodies[0], "WORKER-ONLY") {
		t.Errorf("the body carries the worker's criteria:\n%s", s.scripts.bodies[0])
	}
	for _, want := range []string{
		"## Summary\nadds w.txt\n", "go test ./... -> exit 0", "BEHAVIOR_CHANGE: yes — adds w.txt",
		"1. w.txt exists -> verified [behavior] — cat w.txt printed worker", "- reviewed_sha: " + s.approved, "- verified_base: " + s.base,
		closing + "\nPart of Epic #277\n",
	} {
		if !strings.Contains(s.scripts.bodies[0], want) {
			t.Errorf("body lacks %q:\n%s", want, s.scripts.bodies[0])
		}
	}
}

// wantNoDirectPRCommand checks that oe never ran a gh pr command itself, since the create-pr scripts are the only way a pull request opens.
func (s shipFlow) wantNoDirectPRCommand(t *testing.T) {
	t.Helper()
	for _, c := range s.w.r.Calls() {
		if len(c) > 2 && c[0] == "gh" && c[1] == "pr" {
			t.Errorf("oe called gh directly: %v", c)
		}
	}
}

// TestPublishPushesTheApprovedHeadOnceAndOpensOneLinkedPR shows the whole path on a clean run.
//   - Exactly the approved SHA is pushed to the Issue's branch, never forced, with hooks off.
//   - One pull request is opened, its body holds the reviewer's evidence and the bound pair, and the publish ends linked.
func TestPublishPushesTheApprovedHeadOnceAndOpensOneLinkedPR(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	r := s.publish()
	got := decode[shipped](t, r)
	wantPublished(t, r, got)
	if !got.Pushed || !got.Created || got.Resumed || got.Link != "ok" {
		t.Errorf("publish = %+v, want pushed, created, not resumed, linked", got)
	}
	s.wantPushedExactly(t)
	s.wantBody(t, "Closes #7")
	s.wantNoDirectPRCommand(t)
	if p := got.State.Publish; p.SHA != s.approved || p.Base != s.base || p.PrevSHA != "" {
		t.Errorf("publish record = %+v", p)
	}
	if s.checks.count() != 1 {
		t.Errorf("checks ran %d times, want once", s.checks.count())
	}
}

// TestPublishUsesRelatedWhenSomethingWasSkipped shows that deferred work never closes its Issue.
func TestPublishUsesRelatedWhenSomethingWasSkipped(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "criterion 2 -> done by hand, because X")
	if r := s.publish(); r.code != 0 {
		t.Fatalf("exit %d: %s", r.code, r.stdout)
	}
	s.wantBody(t, "Related #7")
	if strings.Contains(s.scripts.bodies[0], "Closes #7") {
		t.Errorf("body closes the Issue:\n%s", s.scripts.bodies[0])
	}
}

// TestPublishFreezeRecheckAFreezePostedWhileChecksRunPushesNothing is the PublishFreezeRecheck regression.
// A freeze posted by another Publisher while the checks run stops the ship after them: nothing is pushed, no pull request is created or linked, and no intent is recorded.
func TestPublishFreezeRecheckAFreezePostedWhileChecksRunPushesNothing(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	s.checks.during = func() { s.freezeFromAnotherPublisher(t) }
	r := s.publish()
	if r.code != 4 || !strings.Contains(r.stdout, "frozen") {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	s.wantNothingPublished(t)
	if s.scripts.created() != 0 || s.scripts.linked() != 0 {
		t.Errorf("created %d, linked %d pull requests", s.scripts.created(), s.scripts.linked())
	}
	if s.checks.count() != 1 {
		t.Errorf("checks ran %d times, want the one during which the freeze landed", s.checks.count())
	}
}

// TestPublishOfAFrozenEpicDoesNothingAtAll shows that a freeze already standing stops the ship before the scan, the checks, or any write.
func TestPublishOfAFrozenEpicDoesNothingAtAll(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	s.freezeFromAnotherPublisher(t)
	if r := s.publish(); r.code != 4 {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	s.wantNothingPublished(t)
	if s.checks.count() != 0 {
		t.Errorf("checks ran %d times", s.checks.count())
	}
}

// TestPublishWithAnotherHeadOrBaseThanTheApprovalPublishesNothing shows that the verdict freshness gate exits 3 and writes nothing.
func TestPublishWithAnotherHeadOrBaseThanTheApprovalPublishesNothing(t *testing.T) {
	t.Parallel()

	moves := map[string]func(t *testing.T, s shipFlow){
		"the worktree HEAD moved past reviewed_sha": func(t *testing.T, s shipFlow) {
			t.Helper()
			commitIn(t, s.wt, "late.txt", "unreviewed\n")
		},
		"the default branch advanced past verified_base": func(t *testing.T, s shipFlow) {
			t.Helper()
			s.advanceBase(t)
		},
	}
	for name, move := range moves {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			s := newShipFlow(t, "")
			move(t, s)
			before := s.w.r.Mutations()
			r := s.publish()
			if r.code != 3 || s.w.r.Mutations() != before {
				t.Errorf("exit %d, stdout %q, mutations %d", r.code, r.stdout, s.w.r.Mutations()-before)
			}
			s.wantNothingPublished(t)
			if s.checks.count() != 0 {
				t.Errorf("checks ran %d times", s.checks.count())
			}
		})
	}
}

// advanceBase moves origin's default branch on and fetches it, as the Publisher does once per round.
func (s shipFlow) advanceBase(t *testing.T) string {
	t.Helper()
	commitIn(t, s.shared, "c.txt", "newer upstream\n")
	gitIn(t, s.shared, "push", "-q", "origin", "main")
	gitIn(t, s.shared, "fetch", "-q", "origin")
	return gitIn(t, s.shared, "rev-parse", "origin/main")
}

// TestPublishWithoutAnApprovalIsRefused shows that a DONE head nobody reviewed is never published.
func TestPublishWithoutAnApprovalIsRefused(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	if r := s.w.runIn(s.tr, "", "state", "invalidate-approval", "--issue", "7", "--lease-token", s.tok[1]); r.code != 0 {
		t.Fatalf("invalidate: exit %d, stdout %q", r.code, r.stdout)
	}
	if r := s.publish(); r.code != 8 {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	s.wantNothingPublished(t)
}

// wantParked checks a run that parked the Issue instead of publishing it.
func (s shipFlow) wantParked(t *testing.T, r result) {
	t.Helper()
	got := decode[shipped](t, r)
	if r.code != 0 || got.Route != "PARKED" || len(got.State.UnresolvedBlockers) == 0 || got.State.Approval != nil {
		t.Fatalf("exit %d, publish = %+v", r.code, got)
	}
	s.wantNothingPublished(t)
}

// TestPublishWithASuspectedSecretPushesNothingAndParksTheIssue shows that a secret anywhere in what would go out, the worktree included, ships nothing of the Issue.
// The Issue is parked as ship-class secret with a note that does not quote the secret.
func TestPublishWithASuspectedSecretPushesNothingAndParksTheIssue(t *testing.T) {
	t.Parallel()

	secret := "AKIA" + strings.Repeat("Z", 16)
	s := newShipFlow(t, "")
	if err := os.WriteFile(filepath.Join(s.wt, "leak.txt"), []byte("key = "+secret+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := s.publish()
	s.wantParked(t, r)
	if strings.Contains(r.stdout, secret) {
		t.Error("the secret was printed")
	}
	if s.noteKeys("ship-class:7:secret:") != 1 || s.checks.count() != 0 {
		t.Errorf("secret notes = %d, checks = %d", s.noteKeys("ship-class:7:secret:"), s.checks.count())
	}
	for _, c := range s.w.store.Comments(7) {
		if strings.Contains(c.Body, secret) {
			t.Error("the secret was posted")
		}
	}
}

// TestPublishWithASecretInTheTitleParksBeforeAnyPush shows that the pull request text is scanned before the intent is recorded.
func TestPublishWithASecretInTheTitleParksBeforeAnyPush(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	secret := "AKIA" + strings.Repeat("Y", 16)
	r := s.publish("--title", "Add "+secret)
	s.wantParked(t, r)
	if strings.Contains(r.stdout, secret) {
		t.Error("the secret was printed")
	}
}

// TestPublishWithARedOrMessyCheckRunPushesNothingAndParksTheIssue shows that a failing check, or a check that leaves files behind, blocks the push and parks the Issue.
func TestPublishWithARedOrMessyCheckRunPushesNothingAndParksTheIssue(t *testing.T) {
	t.Parallel()

	for name, setup := range map[string]func(t *testing.T, s shipFlow){
		"a check exits non-zero": func(t *testing.T, s shipFlow) {
			t.Helper()
			s.checks.exit, s.checks.output = 1, "FAIL: TestSomething\n"
		},
		"a check leaves a file in the worktree": func(t *testing.T, s shipFlow) {
			t.Helper()
			s.checks.during = func() {
				if err := os.WriteFile(filepath.Join(s.wt, "build.out"), []byte("artifact\n"), 0o600); err != nil {
					t.Error(err)
				}
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			s := newShipFlow(t, "")
			setup(t, s)
			s.wantParked(t, s.publish())
			if s.noteKeys("parked:7:checks:") != 1 {
				t.Errorf("checks notes = %d, want 1", s.noteKeys("parked:7:checks:"))
			}
		})
	}
}

// TestPublishParksWhenAnOlderClosesWouldStillCloseAnIssueTheNewestMarksRelated shows that issue-refs.sh exit 3 parks the Issue like a red check run.
func TestPublishParksWhenAnOlderClosesWouldStillCloseAnIssueTheNewestMarksRelated(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	s.scripts.refs = &ship.ScriptResult{ExitCode: 3, Stdout: "CONFLICT #7\n", Stderr: ""}
	s.wantParked(t, s.publish())
	if s.noteKeys("parked:7:refs:") != 1 {
		t.Errorf("refs notes = %d, want 1", s.noteKeys("parked:7:refs:"))
	}
}

// crashPoint stops a run at one place between the intent and the linked record.
type crashPoint struct {
	crash func(t *testing.T, s shipFlow)
	// phase is the record the crashed run leaves, and pushes the push attempts both runs make together.
	phase  string
	pushes int
}

func crashPoints() map[string]crashPoint {
	return map[string]crashPoint{
		"while the remote refuses the push": {
			crash: func(t *testing.T, s shipFlow) {
				t.Helper()
				s.refusePushes(t, true)
			}, phase: "intent", pushes: 2,
		},
		"after the push, before the pushed record": {
			crash: func(_ *testing.T, s shipFlow) { s.failWritesOf(`"phase": "pushed"`) }, phase: "intent", pushes: 1,
		},
		"after the pushed record, before the pull request": {
			crash: func(_ *testing.T, s shipFlow) { s.scripts.failBeforeCreate = true }, phase: "pushed", pushes: 1,
		},
		"after the pull request was opened, before it is recorded": {
			crash: func(_ *testing.T, s shipFlow) { s.scripts.crashAfterCreate = true }, phase: "pushed", pushes: 1,
		},
		"after the pull request was linked, before the linked record": {
			crash: func(_ *testing.T, s shipFlow) { s.failWritesOf(`"phase": "linked"`) }, phase: "pushed", pushes: 1,
		},
	}
}

// crashRun runs publish until it dies at the crash point, then clears the cause as a restart would.
func (s shipFlow) crashRun(t *testing.T, c crashPoint) {
	t.Helper()
	c.crash(t, s)
	if first := s.publish(); first.code == 0 {
		t.Fatalf("the crashed run succeeded: %s", first.stdout)
	}
	s.w.store.OnWrite(nil)
	s.refusePushes(t, false)
	s.scripts.failBeforeCreate, s.scripts.crashAfterCreate = false, false
	if st := s.stateOf(t); st.Publish == nil || st.Publish.Phase != c.phase {
		t.Fatalf("after the crash the record is %+v, want phase %s", st.Publish, c.phase)
	}
}

// refusePushes makes origin reject every push, or accept them again.
func (s shipFlow) refusePushes(t *testing.T, refuse bool) {
	t.Helper()
	hook := filepath.Join(gitIn(t, s.shared, "remote", "get-url", "origin"), "hooks", "pre-receive")
	if !refuse {
		if err := os.Remove(hook); err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		}
		return
	}
	if err := os.WriteFile(hook, []byte("#!/bin/sh\necho refused >&2\nexit 1\n"), 0o700); err != nil { //nolint:gosec // G306: a hook must be executable.
		t.Fatal(err)
	}
}

// TestPushToPRResumeAfterACrashEndsWithExactlyOneLinkedPR is the PushToPRResume regression, at every point a run can stop between the intent and the linked record.
// The next run passes fresh gates and ends with exactly one pull request, linked and recorded, and never pushes or runs the checks twice.
func TestPushToPRResumeAfterACrashEndsWithExactlyOneLinkedPR(t *testing.T) {
	t.Parallel()

	for name, c := range crashPoints() {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			s := newShipFlow(t, "")
			s.crashRun(t, c)

			r := s.publish()
			got := decode[shipped](t, r)
			wantPublished(t, r, got)
			if !got.Resumed {
				t.Errorf("publish = %+v, want a resumed run", got)
			}
			if s.board.count() != 1 {
				t.Errorf("pull requests = %d, want exactly one", s.board.count())
			}
			if s.scripts.created() != 1 {
				t.Errorf("pull requests created = %d, want exactly one", s.scripts.created())
			}
			if n := len(s.pushes()); n != c.pushes || s.checks.count() != 1 {
				t.Errorf("push attempts = %d and checks = %d, want %d and the first run's only", n, s.checks.count(), c.pushes)
			}
			if rem := s.remoteHead(t); rem != s.approved {
				t.Errorf("origin holds %s", rem)
			}
		})
	}
}

// TestPublishStopsOnAnExternalPush covers contract §8 Push.
// A branch on the remote with no intent ever recorded is an external push: a note, and nothing pushed.
func TestPublishStopsOnAnExternalPush(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	gitIn(t, s.shared, "push", "-q", "origin", s.approved+":refs/heads/feat/issue-7")
	r := s.publish()
	if r.code != 8 || !strings.Contains(r.stdout, "external push") {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	if n := len(s.pushes()); n != 0 || s.board.count() != 0 || s.stateOf(t).Publish != nil {
		t.Errorf("pushes %d, pull requests %d, record %+v", n, s.board.count(), s.stateOf(t).Publish)
	}
	if s.noteKeys("external-push:7:"+s.approved) != 1 || s.checks.count() != 0 {
		t.Errorf("external-push notes = %d, checks = %d", s.noteKeys("external-push:7:"+s.approved), s.checks.count())
	}
}

// TestPublishStopsWhenTheRemoteDiffersFromTheRecordedIntent shows that a branch someone else moved after the intent is left alone: nothing more is pushed and no pull request opens.
func TestPublishStopsWhenTheRemoteDiffersFromTheRecordedIntent(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	s.crashRun(t, crashPoints()["after the push, before the pushed record"])
	gitIn(t, s.shared, "push", "-q", "-f", "origin", s.base+":refs/heads/feat/issue-7")
	if r := s.publish(); r.code != 8 {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	if n := len(s.pushes()); n != 1 || s.board.count() != 0 {
		t.Errorf("pushes %d, pull requests %d, want only the crashed run's push and no pull request", n, s.board.count())
	}
	if rem := s.remoteHead(t); rem != s.base {
		t.Errorf("origin holds %s, want the other party's %s untouched", rem, s.base)
	}
	if st := s.stateOf(t); st.Publish == nil || st.Publish.Phase != "intent" {
		t.Errorf("record = %+v, want the intent kept", st.Publish)
	}
}

// TestPublishRefusesABranchWhosePullRequestWasClosed shows that a closed pull request routes the Issue to rejected, never to a second pull request.
func TestPublishRefusesABranchWhosePullRequestWasClosed(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	s.board.add("feat/issue-7", "CLOSED")
	if r := s.publish(); r.code != 8 || !strings.Contains(r.stdout, "closed") {
		t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
	}
	if n := len(s.pushes()); n != 0 || s.scripts.created() != 0 || s.stateOf(t).Publish != nil {
		t.Errorf("pushes %d, created %d, record %+v", n, s.scripts.created(), s.stateOf(t).Publish)
	}
}

// TestPublishCommentsALinkFailureAndGoesOn shows that a pull request that exists but could not be linked to its Issue is reported on the Issue, and the round continues.
func TestPublishCommentsALinkFailureAndGoesOn(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	s.scripts.createExit = 3
	r := s.publish()
	got := decode[shipped](t, r)
	wantPublished(t, r, got)
	if got.Link != "failed" || s.noteKeys("link-failed:7:30") != 1 {
		t.Errorf("link = %q, link-failed notes = %d, want failed and one note", got.Link, s.noteKeys("link-failed:7:30"))
	}
}

// TestAPublishInFlightSurvivesAStalenessPassAndTheNewPairShipsOverIt shows that a crash after the push followed by a moved base is recoverable without hand-editing state.
//   - Publish exits 3 and creates nothing, because the base moved.
//   - Pin clears the approval while the publish stays recorded as pushed.
//   - After a new review, publish pushes the newer head over the old one with the old head as prev_sha, and opens one pull request.
func TestAPublishInFlightSurvivesAStalenessPassAndTheNewPairShipsOverIt(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	s.crashRun(t, crashPoints()["after the pushed record, before the pull request"])
	oldHead := s.approved
	newBase := s.restale(t)

	r := s.publish()
	got := decode[shipped](t, r)
	wantPublished(t, r, got)
	if got.Resumed || s.board.count() != 1 || s.remoteHead(t) != s.approved {
		t.Errorf("resumed %v, pull requests %d, origin %s; want a fresh publish of %s", got.Resumed, s.board.count(), s.remoteHead(t), s.approved)
	}
	if rec := got.State.Publish; rec.SHA != s.approved || rec.PrevSHA != oldHead || rec.Base != newBase {
		t.Errorf("record = %+v", rec)
	}
	for _, args := range s.pushes() {
		if line := strings.Join(args, " "); strings.Contains(line, " -f") || strings.Contains(line, "force") {
			t.Errorf("a push was forced: %s", line)
		}
	}
}

// restale moves the base past a pushed publish and walks the Issue back to a bound approval of the new pair.
// It returns the new base and sets approved to the new head.
func (s *shipFlow) restale(t *testing.T) string {
	t.Helper()
	oldHead := s.approved
	newBase := s.advanceBase(t)
	s.set = checksSet(t, newBase)
	if r := s.publish(); r.code != 3 || s.board.count() != 0 {
		t.Fatalf("publish on a moved base: exit %d, stdout %q, pull requests %d", r.code, r.stdout, s.board.count())
	}
	p := s.pin(t)
	if p.Route != "PINNED" || p.Head == oldHead || p.State.Approval != nil {
		t.Fatalf("pin = %+v", p)
	}
	if st := s.stateOf(t); st.Publish == nil || st.Publish.Phase != "pushed" || st.Publish.SHA != oldHead {
		t.Fatalf("record after the staleness pass = %+v, want the old push kept", st.Publish)
	}
	if v := s.approveAt(t, p.Head, newBase); v.Route != "BOUND" {
		t.Fatalf("verdict = %+v", v)
	}
	s.approved = p.Head
	return newBase
}

// approveAt binds a clean reviewer approval of head against base.
func (s shipFlow) approveAt(t *testing.T, head, base string) pinned {
	t.Helper()
	text := "VERDICT: APPROVE\nREPO: o/r\nISSUE: #7\nBRANCH: feat/issue-7\nREVIEWED_HEAD: " + head + "\nREVIEWED_BASE: " + base +
		"\nCHECKS_REVISION: " + base + "\nBEHAVIOR_CHANGE: yes — adds w.txt\nCRITERIA:\n1. w.txt exists -> verified [behavior] — cat w.txt printed worker\n" +
		"CHECKS:\n1. go test ./... -> exit 0\nFINDINGS:\nnone\n"
	return decode[pinned](t, s.w.runIn(s.tr, text, append([]string{"review", "verdict", "--issue", "7", "--worktree", s.wt, "--checks-set", s.set}, s.tok...)...))
}

// TestPublishOfAnAlreadyLinkedPairChangesNothing shows that running publish again after it finished neither pushes nor opens anything.
func TestPublishOfAnAlreadyLinkedPairChangesNothing(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	if r := s.publish(); r.code != 0 {
		t.Fatalf("first run: exit %d, stdout %q", r.code, r.stdout)
	}
	mutations := s.w.r.Mutations()
	r := s.publish()
	got := decode[shipped](t, r)
	wantPublished(t, r, got)
	if got.Pushed || got.Created {
		t.Errorf("publish = %+v, want nothing done", got)
	}
	if n := len(s.pushes()); n != 1 || s.board.count() != 1 || s.checks.count() != 1 || s.w.r.Mutations() != mutations {
		t.Errorf("pushes %d, pull requests %d, checks %d, mutations %d", n, s.board.count(), s.checks.count(), s.w.r.Mutations()-mutations)
	}
}

// TestPublishFinalGatesStopAHeadOrBaseThatMovedWhileTheChecksRan shows that the base and the HEAD are read again after the checks, like the freeze.
// Nothing is pushed and no intent is recorded.
func TestPublishFinalGatesStopAHeadOrBaseThatMovedWhileTheChecksRan(t *testing.T) {
	t.Parallel()

	moves := map[string]func(t *testing.T, s shipFlow){
		"the worktree HEAD moved": func(t *testing.T, s shipFlow) {
			t.Helper()
			commitIn(t, s.wt, "late.txt", "unreviewed\n")
		},
		"the default branch advanced": func(t *testing.T, s shipFlow) {
			t.Helper()
			s.advanceBase(t)
		},
	}
	for name, move := range moves {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			s := newShipFlow(t, "")
			s.checks.during = func() { move(t, s) }
			if r := s.publish(); r.code != 3 {
				t.Fatalf("exit %d, stdout %q", r.code, r.stdout)
			}
			s.wantNothingPublished(t)
			if s.checks.count() != 1 {
				t.Errorf("checks ran %d times, want the one during which the pair moved", s.checks.count())
			}
		})
	}
}

// TestPublishIgnoresEditsInTheSharedCheckout shows that oe pushes exactly the reviewed SHA from the Issue's worktree.
// A person's own dirty work in the shared checkout neither blocks the ship nor rides along.
func TestPublishIgnoresEditsInTheSharedCheckout(t *testing.T) {
	t.Parallel()

	s := newShipFlow(t, "")
	if err := os.WriteFile(filepath.Join(s.shared, "a.txt"), []byte("my own unfinished edit\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.shared, "notes.txt"), []byte("key = AKIA"+strings.Repeat("X", 16)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := s.publish()
	wantPublished(t, r, decode[shipped](t, r))
	s.wantPushedExactly(t)
	if tree := gitIn(t, s.shared, "ls-tree", "-r", "--name-only", s.approved); strings.Contains(tree, "notes.txt") {
		t.Errorf("the pushed tree holds the shared checkout's file:\n%s", tree)
	}
}
