package cmd_test

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/maro114510/skills/oe/internal/runner"
)

// trace records every git call oe makes, so a test can show which commands changed history.
type trace struct {
	inner runner.Runner
	mu    sync.Mutex
	git   [][]string
}

func (r *trace) Run(ctx context.Context, prog runner.Program, args []string) (runner.Result, error) {
	if prog == runner.Git {
		r.mu.Lock()
		r.git = append(r.git, slices.Clone(args))
		r.mu.Unlock()
	}
	return r.inner.Run(ctx, prog, args)
}

// subcommand is the git subcommand of an argv, after its -c and -C options.
func subcommand(args []string) string {
	for i := 0; i < len(args); i++ {
		if args[i] == "-c" || args[i] == "-C" {
			i++
			continue
		}
		return args[i]
	}
	return ""
}

// reviewFlow is an Issue whose worker committed and reported DONE while main advanced on origin and the Publisher fetched it.
type reviewFlow struct {
	w             *coordWorld
	tr            *trace
	shared, wt    string
	head, base    string
	set           string
	tok           []string
	workerTouches string
}

func newReviewFlow(t *testing.T, workerFile, upstreamFile string) reviewFlow {
	t.Helper()
	w := newCoordWorld(t)
	tr := &trace{inner: mixed{fake: w.r}, mu: sync.Mutex{}, git: nil}
	shared := sharedRepo(t)
	gitIn(t, shared, "config", "user.name", "oe")
	gitIn(t, shared, "config", "user.email", "oe@example.com")
	token := w.acquire(t)
	f := reviewFlow{w: w, tr: tr, shared: shared, tok: []string{"--lease-token", token, "--repo-dir", shared}, workerTouches: workerFile}
	for _, args := range [][]string{{"state", "start", "--issue", "7", "--lease-token", token}, {"ledger", "create", "--lease-token", token}} {
		if r := w.runIn(tr, "", args...); r.code != 0 {
			t.Fatalf("%v: %d %q", args, r.code, r.stdout)
		}
	}
	wt := decode[struct {
		Worktree string `json:"worktree"`
	}](t, w.runIn(tr, "", append([]string{"worker", "worktree", "--issue", "7"}, f.tok...)...))
	f.wt = wt.Worktree
	f.head = commitIn(t, f.wt, workerFile, "worker\n")
	rep := "STATUS: DONE\nISSUE: #7\nBRANCH: feat/issue-7\nWORKTREE: " + f.wt + "\nHEAD_SHA: " + f.head + "\n"
	if r := w.runIn(tr, rep, append([]string{"worker", "report", "--issue", "7", "--worktree", f.wt}, f.tok...)...); r.code != 0 {
		t.Fatalf("report: %d %q", r.code, r.stdout)
	}
	commitIn(t, shared, upstreamFile, "upstream\n")
	gitIn(t, shared, "push", "-q", "origin", "main")
	gitIn(t, shared, "fetch", "-q", "origin")
	f.base = gitIn(t, shared, "rev-parse", "origin/main")
	f.set = checksSet(t, f.base)
	return f
}

type pinned struct {
	Route    string   `json:"route"`
	Next     string   `json:"next"`
	Head     string   `json:"head"`
	Base     string   `json:"base"`
	Prompt   string   `json:"prompt"`
	Findings []string `json:"findings"`
	State    struct {
		Cycle           int      `json:"cycle"`
		HeadSHA         *string  `json:"head_sha"`
		PendingFindings []string `json:"pending_findings"`
		Approval        *struct {
			ReviewedSHA  string `json:"reviewed_sha"`
			VerifiedBase string `json:"verified_base"`
		} `json:"approval"`
	} `json:"state"`
}

func (f reviewFlow) pin(t *testing.T) pinned {
	t.Helper()
	return decode[pinned](t, f.w.runIn(f.tr, "", append([]string{"review", "pin", "--issue", "7", "--worktree", f.wt, "--checks-set", f.set}, f.tok...)...))
}

func (f reviewFlow) verdict(t *testing.T, head string) pinned {
	t.Helper()
	text := "VERDICT: APPROVE\nREPO: o/r\nISSUE: #7\nBRANCH: feat/issue-7\nREVIEWED_HEAD: " + head + "\nREVIEWED_BASE: " + f.base +
		"\nCHECKS_REVISION: " + f.base + "\nBEHAVIOR_CHANGE: yes — adds w.txt\nCRITERIA:\n1. w.txt exists -> verified [behavior] — cat w.txt printed worker\n" +
		"CHECKS:\n1. go test ./... -> exit 0\nFINDINGS:\nnone\n"
	return decode[pinned](t, f.w.runIn(f.tr, text, append([]string{"review", "verdict", "--issue", "7", "--worktree", f.wt, "--checks-set", f.set}, f.tok...)...))
}

// TestReviewFlowMakesOnlyOesOwnMergeCommit runs worker DONE, pin, and verdict end to end.
//   - oe merges the advanced base with a plain merge commit and records it as the head.
//   - The reviewer gets the pinned pair, and the approval binds exactly that head and base.
//   - The git trace shows no commit and one merge, oe's, with hooks and signing disabled.
//   - The shared checkout is never switched.
func TestReviewFlowMakesOnlyOesOwnMergeCommit(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "w.txt", "b.txt")
	before := gitIn(t, f.shared, "symbolic-ref", "HEAD")
	p := f.pin(t)
	wantPinned(t, f, p)
	v := f.verdict(t, p.Head)
	if v.Route != "BOUND" || v.Next != "ship" || v.State.Approval == nil || v.State.Approval.ReviewedSHA != p.Head ||
		v.State.Approval.VerifiedBase != f.base {
		t.Fatalf("verdict = %+v", v)
	}
	if again := f.pin(t); again.Route != "BOUND" || again.Head != p.Head {
		t.Errorf("pin on a bound pair = %+v", again)
	}
	wantOnlyOesMerge(t, f.tr)
	if after := gitIn(t, f.shared, "symbolic-ref", "HEAD"); after != before {
		t.Errorf("shared checkout switched to %s", after)
	}
}

// wantPinned checks a pin that merged the base.
// The new head is recorded, has the worker's head and then the base as parents, and is what the reviewer prompt pins.
func wantPinned(t *testing.T, f reviewFlow, p pinned) {
	t.Helper()
	if p.Route != "PINNED" || p.Next != "review" || p.Base != f.base || p.Head == f.head || *p.State.HeadSHA != p.Head {
		t.Fatalf("pin = %+v", p)
	}
	if parents := gitIn(t, f.wt, "log", "-1", "--format=%P", p.Head); parents != f.head+" "+f.base {
		t.Errorf("merge parents %q", parents)
	}
	for _, want := range []string{"REVIEW_HEAD: " + p.Head, "diff " + f.base + " " + p.Head, "Default branch: main"} {
		if !strings.Contains(p.Prompt, want) {
			t.Errorf("prompt lacks %q", want)
		}
	}
}

// wantOnlyOesMerge checks that the trace holds no commit and exactly one merge, oe's, with hooks, signing, the editor, and rerere disabled.
func wantOnlyOesMerge(t *testing.T, tr *trace) {
	t.Helper()
	var merges [][]string
	for _, args := range tr.git {
		switch subcommand(args) {
		case "commit", "rebase", "cherry-pick", "revert", "am", "push", "reset":
			t.Errorf("oe ran git %v", args)
		case "merge":
			if !slices.Contains(args, "--abort") {
				merges = append(merges, args)
			}
		}
	}
	if len(merges) != 1 {
		t.Fatalf("merges = %v, want exactly oe's one", merges)
	}
	m := strings.Join(merges[0], " ")
	for _, want := range []string{"core.hooksPath=" + os.DevNull, "--no-verify", "--no-gpg-sign", "--no-edit", "--no-ff", "rerere.enabled=false"} {
		if !strings.Contains(m, want) {
			t.Errorf("merge %q lacks %s", m, want)
		}
	}
}

// TestPinConflictQueuesAFixCycleAndRestoresTheWorktree shows that the loop never merges a conflicting base.
// The worktree stays clean at the recorded head, and a fresh worker gets the conflict as a fix-cycle finding.
func TestPinConflictQueuesAFixCycleAndRestoresTheWorktree(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "a.txt", "a.txt")
	p := f.pin(t)
	if p.Route != "FIX" || p.Next != "redispatch" || p.State.Cycle != 1 || !strings.Contains(strings.Join(p.State.PendingFindings, " "), "a.txt") {
		t.Fatalf("pin = %+v", p)
	}
	if got := gitIn(t, f.wt, "rev-parse", "HEAD"); got != f.head {
		t.Errorf("HEAD %s, want %s", got, f.head)
	}
	if status := gitIn(t, f.wt, "status", "--porcelain"); status != "" {
		t.Errorf("worktree left dirty: %q", status)
	}
}

// TestPinRecoversAnInterruptedMerge shows that the next pin aborts and redoes a merge left in progress in the worktree.
func TestPinRecoversAnInterruptedMerge(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "w.txt", "b.txt")
	gitIn(t, f.wt, "-c", "core.hooksPath="+os.DevNull, "merge", "--no-ff", "--no-commit", f.base)
	p := f.pin(t)
	if p.Route != "PINNED" || gitIn(t, f.wt, "log", "-1", "--format=%P", p.Head) != f.head+" "+f.base {
		t.Fatalf("pin = %+v", p)
	}
}

// TestUncommittedDiffApprovalDriftThroughTheCLI shows that with HEAD unchanged after the pin, an untracked file or a tracked file a check modified binds nothing.
func TestUncommittedDiffApprovalDriftThroughTheCLI(t *testing.T) {
	t.Parallel()

	for name, touch := range map[string]string{"untracked file": "new.txt", "check-modified tracked file": "w.txt"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newReviewFlow(t, "w.txt", "b.txt")
			p := f.pin(t)
			if err := os.WriteFile(filepath.Join(f.wt, touch), []byte("changed by a check\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			v := f.verdict(t, p.Head)
			if v.Route != "FIX" || v.State.Approval != nil || gitIn(t, f.wt, "rev-parse", "HEAD") != p.Head {
				t.Errorf("verdict = %+v", v)
			}
		})
	}
}

// TestVerdictWithAnOldChecksSetWritesNothing shows that a CHECKS_SET derived at an older commit exits 3 and never spends the session's staleness pass.
func TestVerdictWithAnOldChecksSetWritesNothing(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "w.txt", "b.txt")
	p := f.pin(t)
	f.set = checksSet(t, f.head)
	before := f.w.r.Mutations()
	text := "VERDICT: APPROVE\nREPO: o/r\nISSUE: #7\nBRANCH: feat/issue-7\nREVIEWED_HEAD: " + p.Head + "\n"
	r := f.w.runIn(f.tr, text, append([]string{"review", "verdict", "--issue", "7", "--worktree", f.wt, "--checks-set", f.set}, f.tok...)...)
	if r.code != 3 || f.w.r.Mutations() != before {
		t.Errorf("exit %d, stdout %q, mutations %d", r.code, r.stdout, f.w.r.Mutations()-before)
	}
}

// TestBoundPairOnAMovedWorktreeIsRefused shows that a worktree whose HEAD moved past the approved head is a divergence for a person and never ships the old approval.
func TestBoundPairOnAMovedWorktreeIsRefused(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "w.txt", "b.txt")
	p := f.pin(t)
	if v := f.verdict(t, p.Head); v.Route != "BOUND" {
		t.Fatalf("verdict = %+v", v)
	}
	commitIn(t, f.wt, "late.txt", "unreviewed\n")
	before := f.w.r.Mutations()
	r := f.w.runIn(f.tr, "", append([]string{"review", "pin", "--issue", "7", "--worktree", f.wt, "--checks-set", f.set}, f.tok...)...)
	if r.code != 8 || f.w.r.Mutations() != before {
		t.Errorf("exit %d, stdout %q", r.code, r.stdout)
	}
}

// TestChecksSetForAnotherBaseBranchIsRefused shows that a CHECKS_SET derived for another default branch at the same commit is refused before anything is written, since its push-triggered checks were filtered for that branch.
func TestChecksSetForAnotherBaseBranchIsRefused(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "w.txt", "b.txt")
	f.set = checksSetFor(t, "release", f.base)
	before := f.w.r.Mutations()
	r := f.w.runIn(f.tr, "", append([]string{"review", "pin", "--issue", "7", "--worktree", f.wt, "--checks-set", f.set}, f.tok...)...)
	if r.code != 3 || f.w.r.Mutations() != before || gitIn(t, f.wt, "rev-parse", "HEAD") != f.head {
		t.Errorf("exit %d, stdout %q", r.code, r.stdout)
	}
}

// TestPinOnADirtyTreeQueuesAFixCycle shows that uncommitted work found by pin becomes a fix-cycle finding and is never merged over.
func TestPinOnADirtyTreeQueuesAFixCycle(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "w.txt", "b.txt")
	if err := os.WriteFile(filepath.Join(f.wt, "stray.txt"), []byte("left behind\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := f.pin(t)
	if p.Route != "FIX" || p.State.Cycle != 1 || !strings.Contains(strings.Join(p.State.PendingFindings, " "), "stray.txt") ||
		gitIn(t, f.wt, "rev-parse", "HEAD") != f.head {
		t.Errorf("pin = %+v", p)
	}
}

// TestMalformedReportNeverPrintsASecret shows that a malformed report's error withholds a suspected secret it would quote.
func TestMalformedReportNeverPrintsASecret(t *testing.T) {
	t.Parallel()

	f := newReviewFlow(t, "w.txt", "b.txt")
	secret := "AKIA" + strings.Repeat("G", 16)
	r := f.w.runIn(f.tr, "VERDICT: "+secret+"\n", append([]string{"review", "verdict", "--issue", "7", "--worktree", f.wt, "--checks-set", f.set}, f.tok...)...)
	if r.code != 8 || strings.Contains(r.stdout+r.stderr, secret) {
		t.Errorf("exit %d, stdout %q", r.code, r.stdout)
	}
}
