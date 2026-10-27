package ship

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/integrate"
	"github.com/maro114510/skills/oe/internal/scan"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// The routes a publish takes and what follows it.
const (
	RoutePublished   = "PUBLISHED"
	RouteInterrupted = "INTERRUPTED"

	NextLand = "land"
)

// Result is what a publish did and what the loop does next.
type Result struct {
	Issue  int    `json:"issue"`
	Route  string `json:"route"`
	Reason string `json:"reason"`
	Next   string `json:"next"`
	Branch string `json:"branch"`
	// SHA and Base are the approved pair.
	SHA  string `json:"sha"`
	Base string `json:"base"`
	PR   int    `json:"pr"`
	// Pushed and Created say what this run did. Resumed says it continued a publish an earlier run began.
	Pushed  bool `json:"pushed"`
	Created bool `json:"created"`
	Resumed bool `json:"resumed"`
	// Link is ok or failed when this run linked the pull request to its Issues.
	// It is empty when this run did not, as for a pair already published.
	Link     string             `json:"link"`
	Findings []scan.Finding     `json:"findings"`
	Notes    []coord.NoteResult `json:"notes"`
	State    state.Issue        `json:"state"`
}

// NewResult is an empty result for the Issue.
func NewResult(n int) Result {
	var st state.Issue
	return Result{
		Issue: n, Route: "", Reason: "", Next: "", Branch: "", SHA: "", Base: "", PR: 0,
		Pushed: false, Created: false, Resumed: false, Link: "", Findings: []scan.Finding{}, Notes: []coord.NoteResult{}, State: st,
	}
}

// Deps is what a publish runs with.
type Deps struct {
	S       *coord.Session
	Client  *gh.Client
	In      inputs.Inputs
	Scripts ScriptRunner
	Checks  checks.CommandRunner
}

// Request is one Issue to publish.
type Request struct {
	Issue int
	// State is the Issue's state as read for this run, with a recorded head.
	State state.Issue
	// Worktree is the verified worktree of the Issue's branch.
	Worktree string
	// Set is CHECKS_SET derived at origin/<default branch>.
	Set     checks.Set
	Scripts Scripts
	// Title is the pull request title; Report is the worker's DONE report; Nits is how each reviewer nit was resolved.
	Title  string
	Report handoff.Report
	Nits   string
}

// flow is one publish, with the Issue, the approval it ships, and what the run has learned so far.
type flow struct {
	d   Deps
	r   Request
	st  state.Issue
	a   state.Approval
	res Result

	// title and body are the pull request text, composed and scanned before anything is pushed.
	title, body string
	// resuming says an earlier run recorded an intent for exactly this pair.
	resuming bool
	// inFlight says an intent is recorded for this pair, by this run or an earlier one.
	// A failure then leaves a publish in flight.
	inFlight bool
}

// Publish pushes the approved head and opens or links its pull request, contract §18.
// The order is fixed: freeze, secret scan, verdict freshness, checks, final gates, then the intent, the push, and the pull request.
// Every step after the intent is idempotent, so a run that stopped anywhere resumes from the recorded phase.
func Publish(ctx context.Context, d Deps, r Request) (Result, error) {
	f := &flow{d: d, r: r, st: r.State, a: state.Approval{ReviewedSHA: "", VerifiedBase: "", ReviewEvidence: state.ReviewEvidence{BehaviorChange: false, Basis: "", Criteria: nil}}, res: NewResult(r.Issue), title: r.Title, body: "", resuming: false, inFlight: false}
	err := f.run(ctx)
	f.res.State = f.st
	if err != nil && f.res.Route == "" && f.inFlight {
		f.res.Route, f.res.Reason = RouteInterrupted, err.Error()
	}
	return f.res, err
}

// stage is one step of a publish. It reports done when the run ends there without an error.
type stage func(ctx context.Context) (bool, error)

// always makes a step that cannot end the run into a stage.
func always(step func(ctx context.Context) error) stage {
	return func(ctx context.Context) (bool, error) { return false, step(ctx) }
}

func (f *flow) run(ctx context.Context) error {
	for _, step := range []stage{
		f.enter, f.scanAndCompose, always(f.fresh), always(f.plan), f.verify, always(f.gates), always(f.intentAndPush), always(f.openPullRequest),
	} {
		if done, err := step(ctx); done || err != nil {
			return err
		}
	}
	return nil
}

// update applies a transition and keeps the state it returns only when the write landed.
// A failed write returns the zero state, which must never replace the one this run read.
func (f *flow) update(ctx context.Context, t coord.Transition) error {
	next, err := f.d.S.Update(ctx, f.r.Issue, t)
	if err != nil {
		return err
	}
	f.st = next
	return nil
}

func (f *flow) refused(format string, args ...any) error {
	return exitcode.New(exitcode.Refused, fmt.Sprintf(format, args...))
}

// enter checks what the run starts from, which is an approval, the worker report of this dispatch, and the freeze check.
// A pair already linked has nothing left to publish and ends here.
func (f *flow) enter(ctx context.Context) (bool, error) {
	n, st := f.r.Issue, f.st
	if st.Approval == nil {
		return false, f.refused("#%d has no approval, so nothing may be published; run oe review pin and verdict first", n)
	}
	f.a = *st.Approval
	f.res.Branch, f.res.SHA, f.res.Base = st.Branch, f.a.ReviewedSHA, f.a.VerifiedBase
	if rep := f.r.Report; rep.Issue != n || rep.Branch != st.Branch {
		return false, f.refused("the worker report names #%d on %q, not #%d on %q", rep.Issue, rep.Branch, n, st.Branch)
	}
	if _, err := f.d.S.Check(ctx); err != nil {
		return false, err
	}
	p := st.Publish
	if p == nil || p.SHA != f.a.ReviewedSHA || p.Base != f.a.VerifiedBase {
		return false, nil
	}
	if p.Phase != coord.PublishLinked {
		f.resuming = true
		return false, nil
	}
	f.res.Route, f.res.Next, f.res.PR = RoutePublished, NextLand, p.PR
	f.res.Reason = "this pair is already published and linked; nothing was done, and the link is not checked again"
	return true, nil
}

// head and base read the worktree's HEAD and the default branch, which oe never fetches.
func (f *flow) head(ctx context.Context) (string, error) {
	return integrate.Rev(ctx, f.d.Client, f.r.Worktree, "HEAD")
}

func (f *flow) base(ctx context.Context) (string, error) {
	return integrate.Rev(ctx, f.d.Client, f.r.Worktree, "refs/remotes/origin/"+f.d.In.DefaultBranch)
}

// fresh is the verdict freshness gate.
// The worktree must be at reviewed_sha and the default branch at verified_base.
func (f *flow) fresh(ctx context.Context) error {
	head, err := f.head(ctx)
	if err != nil {
		return err
	}
	if head != f.a.ReviewedSHA {
		return exitcode.New(exitcode.Stale, fmt.Sprintf("the worktree is at %s, not the reviewed %s; run oe review pin", head, f.a.ReviewedSHA))
	}
	base, err := f.base(ctx)
	if err != nil {
		return err
	}
	if base != f.a.VerifiedBase {
		return exitcode.New(exitcode.Stale, fmt.Sprintf("origin/%s is at %s, not the verified %s; run oe review pin", f.d.In.DefaultBranch, base, f.a.VerifiedBase))
	}
	return nil
}

// gates are the final gates before anything irreversible: the freeze check and the freshness gate, read again.
func (f *flow) gates(ctx context.Context) error {
	if _, err := f.d.S.Check(ctx); err != nil {
		return err
	}
	return f.fresh(ctx)
}

// plan reads the remote and the branch's pull requests and stops on whatever the record does not explain.
func (f *flow) plan(ctx context.Context) error {
	remote, err := f.remoteHead(ctx)
	if err != nil {
		return err
	}
	if Expect(f.st.Publish, remote) == RemoteExternal {
		return f.externalPush(ctx, remote)
	}
	_, err = f.openPR(ctx)
	return err
}

// remoteHead reads the branch on origin, or "" when it is not there.
func (f *flow) remoteHead(ctx context.Context) (string, error) {
	ref := "refs/heads/" + f.st.Branch
	out, err := f.d.Client.Git(ctx, "-C", f.r.Worktree, "ls-remote", "origin", ref)
	if err != nil {
		return "", err
	}
	for line := range strings.SplitSeq(string(out), "\n") {
		if sha, name, ok := strings.Cut(strings.TrimSpace(line), "\t"); ok && name == ref {
			return sha, nil
		}
	}
	return "", nil
}

// openPR reads the branch's pull requests and returns the one open, or 0.
// A branch with only closed or merged pull requests is the board's to classify, never ours to open another for.
// An open pull request that targets another branch than the default is refused, since create-linked-pr.sh links nothing for it and exits 0.
func (f *flow) openPR(ctx context.Context) (int, error) {
	prs, err := snapshot.ReadBranchPRs(ctx, f.d.Client, f.d.In.Repo, f.st.Branch)
	if err != nil {
		return 0, err
	}
	open := 0
	for _, pr := range prs {
		switch {
		case pr.State != snapshot.StateOpen:
		case open != 0:
			return 0, f.refused("more than one pull request is open for %s; a person decides which stays", f.st.Branch)
		case pr.Base != f.d.In.DefaultBranch:
			return 0, f.refused("the open pull request #%d for %s targets %s, not the default branch %s; a person decides", pr.Number, f.st.Branch, pr.Base, f.d.In.DefaultBranch)
		default:
			open = pr.Number
		}
	}
	if open == 0 && len(prs) > 0 {
		return 0, f.refused("a pull request for %s was closed or merged and none is open; the board classifies the Issue, and a person decides epic-redo", f.st.Branch)
	}
	return open, nil
}

// externalPush notes a branch no recorded publish explains and stops. Nothing is pushed.
func (f *flow) externalPush(ctx context.Context, remote string) error {
	n := f.r.Issue
	seen := remote
	if seen == "" {
		seen = "absent"
	}
	nr, err := f.d.S.PostNote(ctx, n, fmt.Sprintf("external-push:%d:%s", n, seen), ExternalPushNote(n, f.st.Branch, remote))
	if err != nil {
		return err
	}
	f.res.Notes = append(f.res.Notes, nr)
	return f.refused("external push: origin/%s is at %q, which no recorded publish explains; nothing was pushed, and a person decides", f.st.Branch, remote)
}

// scanAndCompose scans everything that would go out and composes the pull request text, before the intent.
func (f *flow) scanAndCompose(ctx context.Context) (bool, error) {
	rep, err := scan.Outgoing(ctx, f.d.Client, f.r.Worktree, f.a.VerifiedBase)
	if err != nil {
		return false, err
	}
	if !rep.Clean {
		return true, f.parkSecret(ctx, "what would be pushed", rep.Findings)
	}
	closing, conflict, err := f.closingLines(ctx)
	if err != nil {
		return false, err
	}
	if conflict != "" {
		return true, f.park(ctx, "refs", "closing keywords conflict: "+conflict)
	}
	f.body = Body{
		Summary: f.r.Report.Summary, Checks: f.r.Report.Checks, Nits: f.r.Nits, Evidence: f.a.ReviewEvidence,
		ReviewedSHA: f.a.ReviewedSHA, VerifiedBase: f.a.VerifiedBase, Closing: closing, Epic: f.d.In.Epic,
	}.Render()
	if text := scan.Text("pull-request", []byte(f.title+"\n"+f.body)); !text.Clean {
		return true, f.parkSecret(ctx, "the pull request text", text.Findings)
	}
	return false, nil
}

// closingLines runs issue-refs.sh from the worktree. Its exit 3 is a conflict between closing keywords, returned as its text.
func (f *flow) closingLines(ctx context.Context) ([]string, string, error) {
	out, err := f.d.Scripts.RunScript(ctx, Script{Path: f.r.Scripts.Refs, Args: []string{f.a.VerifiedBase}, Dir: f.r.Worktree})
	if err != nil {
		return nil, "", exitcode.Wrap(exitcode.Unreadable, err, "issue-refs.sh could not run")
	}
	switch out.ExitCode {
	case 0:
		return ClosingLines(out.Stdout, f.r.Issue, Skipped(f.r.Report.Skipped)), "", nil
	case exitConflict:
		return nil, strings.TrimSpace(out.Stdout), nil
	}
	return nil, "", f.refused("issue-refs.sh failed (exit %d)", out.ExitCode)
}

// exitConflict is the exit code of issue-refs.sh and create-linked-pr.sh for a closing keyword that conflicts or a link that is missing.
const exitConflict = 3

// verify runs CHECKS_SET once, unless an earlier run recorded an intent for this pair, which only a green run reaches.
// A red entry, or an entry that leaves the worktree changed, parks the Issue.
func (f *flow) verify(ctx context.Context) (bool, error) {
	if f.resuming {
		return false, nil
	}
	set := f.r.Set
	if set.Base != f.d.In.DefaultBranch || set.Revision != f.a.VerifiedBase {
		return false, exitcode.New(exitcode.Stale, "CHECKS_SET was derived at "+set.Revision+" for "+set.Base+", not the verified base "+f.a.VerifiedBase+"; derive it again")
	}
	report, err := checks.RunSet(ctx, f.d.Client, f.d.Checks, f.r.Worktree, set)
	if err != nil {
		return false, err
	}
	if why := checksFailure(report); why != "" {
		return true, f.park(ctx, "checks", why)
	}
	return false, nil
}

// checksFailure says why a check run blocks publication, or is empty when it does not.
func checksFailure(report checks.Report) string {
	var b strings.Builder
	for _, res := range report.Results {
		if res.Passed {
			continue
		}
		fmt.Fprintf(&b, "- %s -> exit %d\n%s\n", res.Command, res.ExitCode, tail(res.Error+res.Stdout+res.Stderr, tailLines))
	}
	if len(report.ChangedPaths) > 0 {
		fmt.Fprintf(&b, "- the checks left changes in the worktree: %s\n", strings.Join(report.ChangedPaths, ", "))
	}
	return strings.TrimSpace(b.String())
}

// tailLines bounds the output of a failing check quoted in a note.
const tailLines = 30

func tail(text string, n int) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// park posts the note and parks the Issue, so nothing is pushed and a person decides.
// A note that holds a suspected secret is replaced by the ship-class secret note.
func (f *flow) park(ctx context.Context, cause, why string) error {
	n := f.r.Issue
	key := fmt.Sprintf("parked:%d:%s:%s", n, cause, coord.DigestPlaceholder)
	nr, err := f.d.S.PostNote(ctx, n, key, handoff.ParkedNote(n, why))
	if scanErr, ok := asScan(err); ok {
		return f.parkSecret(ctx, "the "+cause+" output", scanErr.Result.Findings)
	}
	if err != nil {
		return err
	}
	f.res.Notes = append(f.res.Notes, nr)
	return f.parked(ctx, cause+": "+firstLine(why))
}

// parkSecret parks the Issue as ship-class secret. The note never quotes what was found.
func (f *flow) parkSecret(ctx context.Context, what string, findings []scan.Finding) error {
	n := f.r.Issue
	f.res.Findings = findings
	key := fmt.Sprintf("ship-class:%d:%s:%s", n, handoff.ShipSecret, coord.DigestPlaceholder)
	nr, err := f.d.S.PostNote(ctx, n, key, handoff.ShipClassNote(n, handoff.ShipSecret, ""))
	if err != nil {
		return err
	}
	f.res.Notes = append(f.res.Notes, nr)
	return f.parked(ctx, "ship-class secret: "+what+" holds a suspected secret")
}

func (f *flow) parked(ctx context.Context, blocker string) error {
	if err := f.update(ctx, coord.Park{Blockers: []string{blocker}, Head: ""}); err != nil {
		return err
	}
	f.res.Route, f.res.Next = coord.RouteParked, coord.NextParked
	f.res.Reason = "nothing was pushed: " + blocker
	return nil
}

func firstLine(text string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(text), "\n")
	return line
}

// intentAndPush records the intent for the pair, then pushes exactly its SHA and records the push.
// The remote is read again right before the intent, so prev_sha is what the push will be checked against.
func (f *flow) intentAndPush(ctx context.Context) error {
	remote, err := f.remoteHead(ctx)
	if err != nil {
		return err
	}
	if Expect(f.st.Publish, remote) == RemoteExternal {
		return f.externalPush(ctx, remote)
	}
	if f.resuming {
		f.res.Resumed, f.inFlight = true, true
	} else {
		if err := f.update(ctx, coord.RecordPublishIntent{SHA: f.a.ReviewedSHA, Base: f.a.VerifiedBase, PrevSHA: remote}); err != nil {
			return err
		}
		f.inFlight = true
	}
	if f.st.Publish.Phase != coord.PublishIntent {
		return nil
	}
	if remote != f.a.ReviewedSHA {
		if err := f.push(ctx); err != nil {
			return err
		}
	}
	return f.update(ctx, coord.RecordPublished{PR: 0})
}

// push sends exactly the approved SHA to the Issue's branch. It never forces, deletes, or runs a hook.
func (f *flow) push(ctx context.Context) error {
	refspec := f.a.ReviewedSHA + ":refs/heads/" + f.st.Branch
	if _, err := f.d.Client.GitWrite(ctx, "-C", f.r.Worktree, "-c", "core.hooksPath="+os.DevNull, "push", "--no-verify", "origin", refspec); err != nil {
		return err
	}
	f.res.Pushed = true
	return nil
}

// openPullRequest links the branch's open pull request, or creates one when none exists, then records it.
// It starts with the final gates again, since the push took time and a resumed run may be hours late.
func (f *flow) openPullRequest(ctx context.Context) error {
	if err := f.gates(ctx); err != nil {
		return err
	}
	pr, err := f.openPR(ctx)
	if err != nil {
		return err
	}
	if err := f.remoteStillApproved(ctx); err != nil {
		return err
	}
	if pr != 0 {
		err = f.link(ctx, pr)
	} else {
		pr, err = f.create(ctx)
	}
	if err != nil {
		return err
	}
	if err := f.update(ctx, coord.RecordPublished{PR: pr}); err != nil {
		return err
	}
	f.res.Route, f.res.Next, f.res.PR = RoutePublished, NextLand, pr
	f.res.Reason = "the approved head is on origin and its pull request is linked"
	return nil
}

// remoteStillApproved reads the branch on origin once more, right before a pull request is linked or created.
// Anyone may move the branch after the push, and a pull request on another head must never be recorded as the approved one.
func (f *flow) remoteStillApproved(ctx context.Context) error {
	remote, err := f.remoteHead(ctx)
	if err != nil {
		return err
	}
	if remote != f.a.ReviewedSHA {
		return f.externalPush(ctx, remote)
	}
	return nil
}

// link ties an existing pull request to its Issues. A failure is noted on the Issue and never stops the round.
func (f *flow) link(ctx context.Context, pr int) error {
	out, err := f.d.Scripts.RunScript(ctx, Script{Path: f.r.Scripts.Create, Args: LinkArgs(f.d.In.Repo, pr), Dir: f.r.Worktree})
	if err != nil {
		return exitcode.Wrap(exitcode.Unreadable, err, "create-linked-pr.sh could not run")
	}
	return f.linked(ctx, pr, out.ExitCode)
}

// linked records the outcome of the linking: ok, or failed with a note once per pull request.
func (f *flow) linked(ctx context.Context, pr, exit int) error {
	if exit == 0 {
		f.res.Link = "ok"
		return nil
	}
	f.res.Link = "failed"
	n := f.r.Issue
	nr, err := f.d.S.PostNote(ctx, n, fmt.Sprintf("link-failed:%d:%d", n, pr), LinkFailedNote(n, pr, exit))
	if err != nil {
		return err
	}
	f.res.Notes = append(f.res.Notes, nr)
	return nil
}

// create opens the pull request through create-linked-pr.sh, never gh pr create.
// Exit 3 means the pull request exists but is not linked to its Issue.
func (f *flow) create(ctx context.Context) (int, error) {
	bodyFile, cleanup, err := f.writeBody()
	if err != nil {
		return 0, err
	}
	defer cleanup()
	args := CreateArgs(f.d.In.Repo, f.st.Branch, f.d.In.DefaultBranch, f.title, bodyFile)
	out, err := f.d.Scripts.RunScript(ctx, Script{Path: f.r.Scripts.Create, Args: args, Dir: f.r.Worktree})
	if err != nil {
		return 0, exitcode.Wrap(exitcode.Unreadable, err, "create-linked-pr.sh could not run")
	}
	if err := f.createFailure(out); err != nil {
		return 0, err
	}
	pr, err := f.createdNumber(ctx, out)
	if err != nil {
		return 0, err
	}
	f.res.Created = true
	return pr, f.linked(ctx, pr, out.ExitCode)
}

// writeBody puts the body in a private temporary file for the script to read.
func (f *flow) writeBody() (string, func(), error) {
	file, err := os.CreateTemp("", "oe-pr-body-*.md")
	if err != nil {
		return "", nil, exitcode.Wrap(exitcode.Unreadable, err, "cannot write the pull request body")
	}
	_, werr := file.WriteString(f.body)
	cerr := file.Close()
	cleanup := func() { _ = os.Remove(file.Name()) }
	if werr != nil || cerr != nil {
		cleanup()
		return "", nil, exitcode.New(exitcode.Unreadable, "cannot write the pull request body")
	}
	return file.Name(), cleanup, nil
}

// createFailure turns a create-linked-pr.sh exit that opened nothing into an error.
func (f *flow) createFailure(out ScriptResult) error {
	switch out.ExitCode {
	case 0, exitConflict:
		return nil
	case exitUsage:
		return f.refused("create-linked-pr.sh refused: %s", firstLine(out.Stdout+out.Stderr))
	}
	return exitcode.New(exitcode.Unreadable, fmt.Sprintf("create-linked-pr.sh failed (exit %d): %s", out.ExitCode, firstLine(out.Stderr)))
}

// exitUsage is the exit code of create-linked-pr.sh for bad usage or an unknown Issue.
const exitUsage = 2

// createdNumber reads the new pull request's number from the script's output, else from the branch's open pull request.
func (f *flow) createdNumber(ctx context.Context, out ScriptResult) (int, error) {
	if pr, ok := PRNumber(out.Stdout); ok {
		return pr, nil
	}
	pr, err := f.openPR(ctx)
	if err != nil {
		return 0, err
	}
	if pr == 0 {
		return 0, exitcode.New(exitcode.Unreadable, "create-linked-pr.sh printed no pull request URL and none is open")
	}
	return pr, nil
}
