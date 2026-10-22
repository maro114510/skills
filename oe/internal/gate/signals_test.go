package gate_test

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gate"
	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

const runPlanBody = "<!-- oe:v2 note run-plan -->\nplan"

func comment(id int64, author, association, body string) snapshot.Comment {
	return snapshot.Comment{ID: id, CreatedAt: "2026-10-03T00:00:00Z", Author: author, Association: association, Body: body}
}

func plan(id int64) snapshot.Comment { return comment(id, "loop", "OWNER", runPlanBody) }

func human(id int64, body string) snapshot.Comment { return comment(id, "alice", "MEMBER", body) }

func read(t *testing.T, cs ...snapshot.Comment) gate.Signals {
	t.Helper()
	s, err := gate.Read(cs, "loop")
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// TestOnlyAStrictTrustedApproveAfterTheRunPlanApproves guards GT-05: an epic-approve before the
// Run Plan, by an untrusted author, or inside other text never approves.
func TestOnlyAStrictTrustedApproveAfterTheRunPlanApproves(t *testing.T) {
	t.Parallel()

	tests := map[string][]snapshot.Comment{
		"before the Run Plan": {human(10, "epic-approve"), plan(11)},
		"untrusted author":    {plan(10), comment(11, "mallory", "CONTRIBUTOR", "epic-approve"), comment(12, "bob", "NONE", "epic-approve")},
		"embedded in text":    {plan(10), human(11, "I will epic-approve after lunch"), human(12, "epic-approve\nplease")},
		"upper case":          {plan(10), human(11, "EPIC-APPROVE")},
		"no Run Plan":         {human(11, "epic-approve")},
		"loop's own comment":  {plan(10), comment(11, "loop", "OWNER", "<!-- oe:v2 note x -->\nepic-approve")},
		"someone else's plan": {comment(10, "alice", "MEMBER", runPlanBody), human(11, "epic-approve")},
	}
	for name, cs := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if s := read(t, cs...); s.Approved() || s.MergeAuthorized() {
				t.Errorf("signals = %+v; want no approval", s)
			}
		})
	}
	s := read(t, plan(10), human(11, "  epic-approve  \n\nepic-approve\n"), comment(12, "carol", "COLLABORATOR", "epic-approve"))
	if s.RunPlan != 10 || s.Approval != 12 {
		t.Errorf("signals = %+v; want Run Plan 10 approved by 12", s)
	}
}

// TestTheLatestGrantOrRevokeDecides guards MA-01: by comment ID, the latest of epic-auto-merge
// and epic-revoke-auto-merge after the Run Plan wins, whatever order the comments are listed in.
func TestTheLatestGrantOrRevokeDecides(t *testing.T) {
	t.Parallel()

	approve := human(11, "epic-approve")
	tests := []struct {
		name    string
		cs      []snapshot.Comment
		granted bool
		id      int64
	}{
		{"none", []snapshot.Comment{plan(10), approve}, false, 0},
		{"grant", []snapshot.Comment{plan(10), approve, human(12, "epic-auto-merge")}, true, 12},
		{"revoke after grant", []snapshot.Comment{plan(10), approve, human(12, "epic-auto-merge"), human(13, "epic-revoke-auto-merge")}, false, 13},
		{"grant after revoke", []snapshot.Comment{plan(10), approve, human(12, "epic-auto-merge"), human(13, "epic-revoke-auto-merge"), human(14, "epic-auto-merge")}, true, 14},
		{"listed out of order", []snapshot.Comment{human(14, "epic-revoke-auto-merge"), plan(10), approve, human(12, "epic-auto-merge")}, false, 14},
		{"grant before the Run Plan", []snapshot.Comment{human(9, "epic-auto-merge"), plan(10), approve}, false, 0},
		{"untrusted revoke", []snapshot.Comment{plan(10), approve, human(12, "epic-auto-merge"), comment(13, "m", "NONE", "epic-revoke-auto-merge")}, true, 12},
		{"embedded grant", []snapshot.Comment{plan(10), approve, human(12, "epic-auto-merge when green")}, false, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			s := read(t, tc.cs...)
			if s.MergeGrant.Granted != tc.granted || s.MergeGrant.CommentID != tc.id || s.MergeAuthorized() != tc.granted {
				t.Errorf("grant = %+v, authorized %v; want granted %v by %d", s.MergeGrant, s.MergeAuthorized(), tc.granted, tc.id)
			}
		})
	}
}

// TestApprovalAloneNeverAuthorizesAMerge guards GL-08, and a grant without an approval
// authorizes nothing either.
func TestApprovalAloneNeverAuthorizesAMerge(t *testing.T) {
	t.Parallel()

	if s := read(t, plan(10), human(11, "epic-approve")); !s.Approved() || s.MergeAuthorized() {
		t.Errorf("approval only: %+v", s)
	}
	s := read(t, plan(10), human(11, "epic-auto-merge"))
	if s.Approved() || !s.MergeGrant.Granted || s.MergeAuthorized() || s.MergeGrant.Command != signals.AutoMerge {
		t.Errorf("grant only: %+v", s)
	}
}

func TestTheFirstRunPlanOpensTheWindow(t *testing.T) {
	t.Parallel()

	s := read(t, plan(10), human(11, "epic-approve"), plan(12))
	if s.RunPlan != 10 || s.Approval != 11 {
		t.Errorf("signals = %+v; want the window from the first Run Plan", s)
	}
}

func TestAV1MarkerStopsTheGate(t *testing.T) {
	t.Parallel()

	_, err := gate.Read([]snapshot.Comment{comment(10, "loop", "OWNER", "<!-- orchestrate-epic:run-plan -->\nplan")}, "loop")
	if exitcode.CodeOf(err) != exitcode.Protocol {
		t.Errorf("err = %v, want exit 6", err)
	}
}
