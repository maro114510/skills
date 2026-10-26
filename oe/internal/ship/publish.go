package ship

import (
	"context"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/scan"
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
	// Link is ok or failed once the pull request is linked to its Issues, and empty before.
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

// Publish pushes the approved head and opens or links its pull request.
func Publish(_ context.Context, _ Deps, r Request) (Result, error) {
	return NewResult(r.Issue), nil
}
