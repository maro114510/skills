package cmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gate"
	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

// The gate's statuses, contract §15.
const (
	gateRunPlanPosted    = "run-plan-posted"
	gateAwaitingApproval = "awaiting-approval"
	gateFrozen           = "frozen"
	gateApproved         = "approved"
)

// gateResult is what the entry gate decided. Dispatch is true only with status approved and
// exit 0; MergeAuthorized is true only when Dispatch is and the merge grant holds.
type gateResult struct {
	Status          string              `json:"status"`
	Reason          string              `json:"reason"`
	Dispatch        bool                `json:"dispatch"`
	MergeAuthorized bool                `json:"merge_authorized"`
	Signals         gate.Signals        `json:"signals"`
	RunPlan         *coord.NoteResult   `json:"run_plan,omitempty"`
	Ledger          *coord.LedgerResult `json:"ledger,omitempty"`
	Health          health.Result       `json:"health"`
}

func newGateCmd(env Env, g *globals) *cobra.Command {
	var token string
	c := &cobra.Command{
		Use:   "gate",
		Short: "Entry gate: post the Run Plan once, then require epic-approve, a clear freeze, and health",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				return runGate(ctx, c, ss)
			})
		},
	}
	tokenFlag(c, &token)
	return c
}

// runGate decides, from one full read, whether and how far the loop may act. A read that fails
// writes nothing: a failed Run Plan lookup never posts a Run Plan.
func runGate(ctx context.Context, c *cobra.Command, ss session) error {
	res, b, err := classifyBoard(ctx, ss)
	if err != nil {
		return err
	}
	sig, err := gate.Read(b.Comments[b.Epic], ss.in.Me)
	if err != nil {
		return err
	}
	out := gateResult{Status: "", Reason: "", Dispatch: false, MergeAuthorized: false, Signals: sig, RunPlan: nil, Ledger: nil, Health: res.Health}
	if sig.RunPlan == 0 {
		note, err := postRunPlan(ctx, ss, res, b)
		if err != nil {
			return err
		}
		out.Status, out.RunPlan = gateRunPlanPosted, &note
		out.Reason = "posted the Run Plan; nothing runs until a trusted epic-approve is posted after it"
		return emit(c, out, exitcode.New(exitcode.Refused, out.Reason))
	}
	if !sig.Approved() {
		out.Status = gateAwaitingApproval
		out.Reason = "no trusted comment holding only epic-approve after the Run Plan; no label counts as approval"
		return emit(c, out, exitcode.New(exitcode.Refused, out.Reason))
	}
	if stop, err := checkFreezeAndHealth(ctx, ss, res, &out); stop {
		// Only exit 4 means frozen. A failed or raced ledger write is no freeze, and a retry, not
		// an epic-release, is what it needs.
		if exitcode.CodeOf(err) != exitcode.Stop {
			return err
		}
		out.Status = gateFrozen
		return emit(c, out, err)
	}
	out.Status, out.Dispatch, out.MergeAuthorized = gateApproved, true, sig.MergeAuthorized()
	out.Reason = "approved; merging needs a trusted epic-auto-merge not revoked since"
	if out.MergeAuthorized {
		out.Reason = "approved; merging is granted"
	}
	return emit(c, out, nil)
}

// checkFreezeAndHealth runs after the approval and before anything acts: it creates a missing
// ledger, applies an epic-release to a frozen one, and freezes the Epic on post-merge health
// already known to fail. stop is true when the gate must exit; err then carries the exit code.
func checkFreezeAndHealth(ctx context.Context, ss session, res board.Result, out *gateResult) (bool, error) {
	n := countNotDone(res)
	if _, err := ss.s.CreateLedger(ctx, n); err != nil {
		return true, err
	}
	lr, err := ss.s.Release(ctx, n)
	out.Ledger = &lr
	if err != nil {
		out.Reason = "the Epic is frozen; only a trusted epic-release after its freeze note lifts it"
		return true, err
	}
	if res.Health.Next != health.NextFreeze {
		return false, nil
	}
	h := res.Health
	// Freeze always stops with exit 4, also when another session froze the Epic first.
	fr, err := ss.s.Freeze(ctx, "post-merge health "+string(h.Status)+" on "+h.Merge+": "+h.Reason, h.Merge, string(h.Status))
	out.Ledger = &fr
	out.Reason = "post-merge health is " + string(h.Status) + " on " + h.Merge + "; the Epic is frozen before any work starts"
	return true, err
}

// postRunPlan gathers the repository facts and posts the Run Plan once through the comment
// writer, which looks the key up again with a full read before posting.
func postRunPlan(ctx context.Context, ss session, res board.Result, b *snapshot.Board) (coord.NoteResult, error) {
	prot, err := snapshot.ReadProtection(ctx, ss.client, ss.in.Repo, ss.in.DefaultBranch)
	if err != nil {
		return coord.NoteResult{}, err
	}
	if err := checkoutOfRepo(ctx, ss); err != nil {
		return coord.NoteResult{}, err
	}
	set, err := checks.Derive(ctx, ss.client, ss.in.DefaultBranch, "origin/"+ss.in.DefaultBranch)
	if err != nil {
		return coord.NoteResult{}, err
	}
	// The Run Plan is never posted again, so it must not state the workflows of a stale ref.
	if set.Revision != b.BaseSHA {
		return coord.NoteResult{}, exitcode.New(exitcode.Stale, fmt.Sprintf(
			"origin/%s is %s but GitHub's %s is %s; run git fetch origin %s, then the gate again",
			ss.in.DefaultBranch, set.Revision, ss.in.DefaultBranch, b.BaseSHA, ss.in.DefaultBranch))
	}
	budget := coord.NewLedger(countNotDone(res))
	if b.Ledger != nil {
		budget = *b.Ledger
	}
	text := gate.Render(gate.Plan{
		Epic: ss.in.Epic, DefaultBranch: ss.in.DefaultBranch, Protection: prot, Checks: set,
		Issues: res.Issues, MaxParallel: ss.in.MaxParallel, Budget: budget,
	})
	return ss.s.PostNote(ctx, ss.in.Epic, gate.RunPlanKey, text)
}

// checkoutOfRepo refuses to derive CHECKS_SET from a checkout whose origin is another
// repository, since its workflows would not be this repository's.
func checkoutOfRepo(ctx context.Context, ss session) error {
	url, err := ss.client.Git(ctx, "remote", "get-url", "origin")
	if err != nil {
		return exitcode.Wrap(exitcode.Unreadable, err, "CHECKS_SET is derived from this checkout, whose origin is unreadable")
	}
	origin, err := inputs.ParseRemote(string(url))
	if err != nil || !strings.EqualFold(origin, ss.in.Repo) {
		return exitcode.New(exitcode.Refused, "CHECKS_SET is derived from this checkout, whose origin is not "+ss.in.Repo+"; run oe from its checkout")
	}
	return nil
}

// countNotDone counts the dispatchable Issues that are not done.
func countNotDone(res board.Result) int {
	n := 0
	for _, i := range res.Issues {
		if i.State != board.Done {
			n++
		}
	}
	return n
}
