package cmd_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/state"
)

const gateWorkflow = `on:
  pull_request:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: unit
        run: go test ./...
      - name: lint
        uses: golangci/golangci-lint-action@v9
`

const runPlanPrefix = "<!-- oe:v2 note run-plan -->"

// newGateWorld is newCoordWorld with a checkout whose origin/main holds one workflow.
func newGateWorld(t *testing.T) *coordWorld {
	t.Helper()
	w := newCoordWorld(t)
	w.r.On(ghfake.Git, func(v map[string]string) string {
		switch args := v["args"]; {
		case strings.HasPrefix(args, "rev-parse"):
			return "base1\n"
		case strings.HasPrefix(args, "ls-tree"):
			return ".github/workflows/ci.yml\n"
		case strings.HasPrefix(args, "show"):
			return gateWorkflow
		default:
			return ""
		}
	})
	return w
}

type gateOut struct {
	Status          string `json:"status"`
	Dispatch        bool   `json:"dispatch"`
	MergeAuthorized bool   `json:"merge_authorized"`
	Signals         struct {
		RunPlan  int64 `json:"run_plan"`
		Approval int64 `json:"approval"`
	} `json:"signals"`
	Ledger *struct {
		Status string        `json:"status"`
		Ledger *state.Ledger `json:"ledger"`
	} `json:"ledger"`
}

func (w *coordWorld) gate(t *testing.T, token string) (result, gateOut) {
	t.Helper()
	r := w.run("--epic", "277", "gate", "--lease-token", token)
	var out gateOut
	if r.code != 1 && r.code != 6 && r.code != 7 {
		if strings.Count(r.stdout, "\n") != 1 || json.Unmarshal([]byte(r.stdout), &out) != nil {
			t.Fatalf("gate printed %q, want one JSON payload", r.stdout)
		}
	}
	return r, out
}

func (w *coordWorld) wantGate(t *testing.T, token string, code int, status string, dispatch bool) gateOut {
	t.Helper()
	r, out := w.gate(t, token)
	if r.code != code || out.Status != status || out.Dispatch != dispatch {
		t.Fatalf("gate: exit %d, stdout %q; want exit %d, status %s, dispatch %v", r.code, r.stdout, code, status, dispatch)
	}
	return out
}

func (w *coordWorld) runPlans() []ghfake.Stored {
	var out []ghfake.Stored
	for _, c := range w.store.Comments(277) {
		if strings.HasPrefix(c.Body, runPlanPrefix) {
			out = append(out, c)
		}
	}
	return out
}

// TestGatePostsTheRunPlanOnceAndExits guards GT-02, GT-03, TP-02, CMD-13, and RD-05: with no
// Run Plan, the gate posts one stating the repository facts and bounds, then exits without
// approving; a later gate finds it and never posts a second one or edits it.
func TestGatePostsTheRunPlanOnceAndExits(t *testing.T) {
	t.Parallel()

	w := newGateWorld(t)
	token := w.acquire(t)
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	w.wantGate(t, token, 8, "run-plan-posted", false)
	plans := w.runPlans()
	if len(plans) != 1 {
		t.Fatalf("Run Plans = %d, want 1", len(plans))
	}
	for _, want := range []string{
		"branch protection (`main`): なし",
		"`go test ./...`",
		"`golangci/golangci-lint-action@v9`",
		"| #7 | T7 | ready | - | main |",
		"worker dispatch 5 回",
	} {
		if !strings.Contains(plans[0].Body, want) {
			t.Errorf("Run Plan lacks %q:\n%s", want, plans[0].Body)
		}
	}
	before := len(w.store.Writes())
	out := w.wantGate(t, token, 8, "awaiting-approval", false)
	if len(w.runPlans()) != 1 || len(w.store.Writes()) != before || out.Signals.RunPlan != plans[0].ID || out.Signals.Approval != 0 {
		t.Errorf("a second gate wrote %d times, Run Plans %d, signals %+v", len(w.store.Writes())-before, len(w.runPlans()), out.Signals)
	}
}

// TestGateApprovesOnlyAStrictTrustedApproveAfterTheRunPlan guards GT-05 and GL-05: an
// epic-approve before the Run Plan, by an untrusted author, or inside other text grants no
// dispatch, and nothing is written until a trusted strict one arrives.
func TestGateApprovesOnlyAStrictTrustedApproveAfterTheRunPlan(t *testing.T) {
	t.Parallel()

	w := newGateWorld(t)
	token := w.acquire(t)
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	w.wantGate(t, token, 8, "run-plan-posted", false)
	w.store.Add(277, "mallory", "CONTRIBUTOR", "epic-approve")
	w.store.Add(277, "bob", "NONE", "epic-approve")
	w.store.Add(277, "alice", "MEMBER", "looks good, epic-approve")
	w.store.Add(277, "alice", "MEMBER", "epic-approve\nepic-auto-merge")
	before := len(w.store.Writes())
	out := w.wantGate(t, token, 8, "awaiting-approval", false)
	if out.MergeAuthorized || out.Ledger != nil || len(w.store.Writes()) != before {
		t.Errorf("an unapproved gate: %+v, %d writes", out, len(w.store.Writes())-before)
	}
	id := w.store.Add(277, "carol", "COLLABORATOR", "epic-approve")
	out = w.wantGate(t, token, 0, "approved", true)
	if out.Signals.Approval != id || out.MergeAuthorized || out.Ledger == nil || out.Ledger.Ledger.N != 1 {
		t.Errorf("approved gate: %+v", out)
	}
}

// TestGateNeverReadsALabel guards GL-01 at the gate: no call it makes asks for a label, whether
// it posts the Run Plan, waits for approval, or approves.
func TestGateNeverReadsALabel(t *testing.T) {
	t.Parallel()

	w := newGateWorld(t)
	token := w.acquire(t)
	w.wantGate(t, token, 8, "run-plan-posted", false)
	w.wantGate(t, token, 8, "awaiting-approval", false)
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	w.wantGate(t, token, 0, "approved", true)
	if q := strings.ToLower(w.r.Queries()); strings.Contains(q, "label") {
		t.Errorf("the gate asked for a label:\n%s", q)
	}
}

// TestGateMergeGrantFollowsTheLatestCommand guards MA-01 and GL-08: approval alone never
// authorizes a merge; a revoke after a grant withdraws it, and a grant after that revoke
// restores it.
func TestGateMergeGrantFollowsTheLatestCommand(t *testing.T) {
	t.Parallel()

	w := newGateWorld(t)
	token := w.acquire(t)
	w.wantGate(t, token, 8, "run-plan-posted", false)
	w.store.Add(277, "alice", "MEMBER", "epic-auto-merge")
	w.wantGate(t, token, 8, "awaiting-approval", false)
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	for _, step := range []struct {
		post       string
		authorized bool
	}{
		{"", true},
		{"epic-revoke-auto-merge", false},
		{"epic-auto-merge", true},
		{"epic-revoke-auto-merge", false},
	} {
		if step.post != "" {
			w.store.Add(277, "alice", "MEMBER", step.post)
		}
		if out := w.wantGate(t, token, 0, "approved", true); out.MergeAuthorized != step.authorized {
			t.Errorf("after %q: merge_authorized %v, want %v", step.post, out.MergeAuthorized, step.authorized)
		}
	}
}

// TestGateStopsOnAFailedRunPlanLookup guards GT-02 and CMD-14: when the Run Plan cannot be
// looked up, or a fact it states cannot be read, nothing is posted and the gate stops.
func TestGateStopsOnAFailedRunPlanLookup(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		breakWorld func(w *coordWorld)
		code       int
	}{
		"comments unreadable": {func(w *coordWorld) { w.r.Exit(ghfake.CommentsName, 1) }, 1},
		"v1 Run Plan": {func(w *coordWorld) {
			w.store.Add(277, "loop", "OWNER", "<!-- orchestrate-epic:run-plan -->\nplan")
		}, 6},
		"protection hidden": {func(w *coordWorld) {
			w.r.On(ghfake.Protection, func(map[string]string) string { return `{"message":"Not Found"}` })
			w.r.Stderr(ghfake.Protection, "gh: Not Found (HTTP 404)")
		}, 1},
		"workflows unreadable": {func(w *coordWorld) { w.r.Exit(ghfake.Git, 128) }, 1},
		"another origin":       {func(w *coordWorld) { w.r.SetOrigin("https://github.com/x/y.git") }, 8},
		"stale origin ref": {func(w *coordWorld) {
			w.r.On(ghfake.Git, func(v map[string]string) string {
				if strings.HasPrefix(v["args"], "rev-parse") {
					return "old1\n"
				}
				return ""
			})
		}, 3},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w := newGateWorld(t)
			token := w.acquire(t)
			tc.breakWorld(w)
			before := w.r.Mutations()
			// --repo names the repository, so another origin is only the checkout's.
			r := w.run("--repo", "o/r", "--epic", "277", "gate", "--lease-token", token)
			if r.code != tc.code || w.r.Mutations() != before || len(w.runPlans()) != 0 {
				t.Errorf("exit %d (want %d), stdout %q, mutations %d", r.code, tc.code, r.stdout, w.r.Mutations()-before)
			}
		})
	}
}

// TestGateStopsOnAFrozenEpic guards GT-07 and EC-06: an approved but frozen Epic exits 4 before
// any dispatch, and only a trusted epic-release after the freeze note lets the gate approve.
func TestGateStopsOnAFrozenEpic(t *testing.T) {
	t.Parallel()

	w := newGateWorld(t)
	token := w.acquire(t)
	w.wantGate(t, token, 8, "run-plan-posted", false)
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	w.store.Add(277, "alice", "MEMBER", "epic-auto-merge")
	l := frozenLedger()
	w.put(t, 277, &l)
	out := w.wantGate(t, token, 4, "frozen", false)
	if out.MergeAuthorized || out.Ledger == nil || out.Ledger.Status != "FROZEN" {
		t.Errorf("frozen gate: %+v", out)
	}
	if n := countPrefix(w.store.Comments(277), "<!-- oe:v2 note freeze:1 -->"); n != 1 {
		t.Errorf("freeze notes = %d, want the missing one posted once", n)
	}
	w.store.Add(277, "alice", "MEMBER", "epic-retry")
	w.wantGate(t, token, 4, "frozen", false)
	w.store.Add(277, "alice", "MEMBER", "epic-release")
	if out := w.wantGate(t, token, 0, "approved", true); !out.MergeAuthorized {
		t.Errorf("released gate: %+v", out)
	}
}

func frozenLedger() state.Ledger {
	var l state.Ledger
	l.Entity, l.Key, l.N, l.FreezeSeq = state.EntityLedger, state.KeyLedger, 1, 1
	l.Counters = state.Counters{
		WorkerDispatches: state.Counter{Used: 5, Bound: 5}, ReviewerPasses: state.Counter{Used: 0, Bound: 4},
		FixCycles: state.Counter{Used: 0, Bound: 2},
	}
	l.Freeze = &state.Freeze{Seq: 1, Reason: "worker_dispatches 5 + 1 > 5", MergeSHA: "", Health: "", Released: false}
	return l
}

const failingPull = `{"data":{"repository":{"pullRequest":{"number":7,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",` +
	`"mergeCommit":{"oid":"m111","statusCheckRollup":{"state":"FAILURE","contexts":{"totalCount":1,"nodes":[` +
	`{"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-19T00:00:10Z","checkSuite":{"databaseId":1}}]}}}}}}}`

// TestGateFreezesOnFailingPostMergeHealth guards GT-08: post-merge health already known to fail
// freezes the Epic at the gate, before any work starts, and a later gate stays frozen without
// freezing again.
func TestGateFreezesOnFailingPostMergeHealth(t *testing.T) {
	t.Parallel()

	w := newGateWorld(t)
	token := w.acquire(t)
	w.wantGate(t, token, 8, "run-plan-posted", false)
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	w.store.Add(277, "loop", "OWNER", ghfake.StateBody("post-merge", "post-merge",
		`,"pr":7,"issue":7,"reviewed_sha":"h","verified_base":"b","phase":"merged","merge_sha":"m111","requested_at":"t"`))
	w.r.On(ghfake.MergePull, func(map[string]string) string { return failingPull })
	out := w.wantGate(t, token, 4, "frozen", false)
	f := out.Ledger.Ledger.Freeze
	if f == nil || f.MergeSHA != "m111" || f.Health != "FAIL" || f.Released {
		t.Fatalf("freeze = %+v", f)
	}
	w.wantGate(t, token, 4, "frozen", false)
	if n := countPrefix(w.store.Comments(277), "<!-- oe:v2 note freeze:"); n != 1 {
		t.Errorf("freeze notes = %d, want 1", n)
	}
	w.store.Add(277, "alice", "MEMBER", "epic-release")
	w.wantGate(t, token, 0, "approved", true)
}

// TestGateLabelsOnlyAFreezeAsFrozen: a ledger write that fails is no freeze. The gate exits
// with the write's code and no payload, so it never asks for an epic-release that would lift
// nothing.
func TestGateLabelsOnlyAFreezeAsFrozen(t *testing.T) {
	t.Parallel()

	w := newGateWorld(t)
	token := w.acquire(t)
	w.wantGate(t, token, 8, "run-plan-posted", false)
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	w.store.OnWrite(func(_ *ghfake.Store, wr ghfake.Write) (int, bool) {
		if strings.Contains(wr.Body, "oe:v2 state ledger") {
			return 1, false
		}
		return 0, true
	})
	r, _ := w.gate(t, token)
	if r.code != 1 || strings.Contains(r.stdout, `"status":"frozen"`) || strings.Contains(r.stdout, "epic-release") {
		t.Errorf("exit %d, stdout %q; want exit 1 without a frozen payload", r.code, r.stdout)
	}
}
