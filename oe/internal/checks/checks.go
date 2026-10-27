// Package checks is the one classification of the checks on a commit, shared by the merge
// readiness and the default-branch health classifiers. It decides what a single check run or
// commit status means, and keeps only the latest run of each check. It also derives CHECKS_SET
// from a repository's workflow files and runs its entries, see checkset.go.
package checks

import (
	"slices"
	"strconv"
)

// Class is what one check means. The classes are the union of what readiness and health need;
// each consumer maps the two it reads differently, see Cancelled and Action.
type Class string

// The check classes.
const (
	// Pass is a success, a neutral, or a skipped run.
	Pass Class = "pass"
	// Pending is a run that has not finished or a status that is not final.
	Pending Class = "pending"
	// Failed is any other finished result.
	Failed Class = "failed"
	// Action is a run that asks for a human. Readiness holds the merge for a person; health,
	// after a merge that already landed, counts it as a failure.
	Action Class = "action"
	// Cancelled is a cancelled run, usually superseded by a later push. Readiness counts it as a
	// failure; health leaves the result unconfirmed.
	Cancelled Class = "cancelled"
	// Unreadable is a check whose state is missing or of an unknown kind. It is never a pass.
	Unreadable Class = "unreadable"
)

// UnnamedCheck names a check that carries neither a name nor a context.
const UnnamedCheck = "unnamed check"

const (
	typeCheckRun      = "CheckRun"
	typeStatusContext = "StatusContext"
	statusCompleted   = "COMPLETED"
	keyStatus         = "status"
	keySuite          = "suite"
	keyUnkeyed        = "unkeyed"
)

// Check is one check, after superseded runs were dropped.
type Check struct {
	Name  string
	Class Class
	// URL is the link of the latest run, or empty when it has none.
	URL string
}

func (c Context) name() string {
	switch {
	case c.Name != nil:
		return *c.Name
	case c.Context != nil:
		return *c.Context
	default:
		return UnnamedCheck
	}
}

func (c Context) class() Class {
	switch c.Typename {
	case typeCheckRun:
		return c.runClass()
	case typeStatusContext:
		return c.statusClass()
	default:
		return Unreadable
	}
}

func (c Context) runClass() Class {
	switch {
	case c.Status == nil:
		return Unreadable
	case *c.Status != statusCompleted:
		return Pending
	case c.Conclusion == nil:
		return Unreadable
	}
	switch *c.Conclusion {
	case "SUCCESS", "NEUTRAL", "SKIPPED":
		return Pass
	case "ACTION_REQUIRED":
		return Action
	case "CANCELLED":
		return Cancelled
	default:
		return Failed
	}
}

func (c Context) statusClass() Class {
	if c.State == nil {
		return Unreadable
	}
	switch *c.State {
	case "SUCCESS":
		return Pass
	case "PENDING", "EXPECTED":
		return Pending
	default:
		return Failed
	}
}

// key identifies the check a run belongs to. A re-run leaves the superseded run in the rollup,
// so Latest keeps one run per key: the same check suite and name for a check run, the same
// context for a status. The suite id is the key because a workflow display name is not unique
// across files, and one file triggered twice on a head yields two suites; collapsing either
// would let a success hide a failure. A check run without a suite id is never collapsed.
func (c Context) key(index int) []string {
	switch {
	case c.Typename == typeStatusContext:
		return []string{keyStatus, c.name()}
	case c.CheckSuite != nil && c.CheckSuite.DatabaseID != nil:
		return []string{keySuite, strconv.FormatInt(*c.CheckSuite.DatabaseID, 10), c.name()}
	default:
		return []string{keyUnkeyed, strconv.Itoa(index)}
	}
}

// started is the run's timestamp. A run that has not started yet has none and counts as the
// latest, since it is the pending re-run.
func (c Context) started() *string {
	if c.StartedAt != nil {
		return c.StartedAt
	}
	return c.CreatedAt
}

// olderThan orders runs by time, with a missing time last.
func olderThan(a, b Context) int {
	ta, tb := a.started(), b.started()
	switch {
	case ta == nil && tb == nil:
		return 0
	case ta == nil:
		return 1
	case tb == nil:
		return -1
	}
	return compareStrings(*ta, *tb)
}

func compareStrings(a, b string) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

type group struct {
	key  []string
	runs []Context
}

// Latest classifies the nodes of a rollup, keeping only the latest run of each check. Checks
// come back ordered by their key, so every reason built from them is reproducible.
func Latest(nodes []Context) []Check {
	var groups []*group
	for i, n := range nodes {
		key := n.key(i)
		at := slices.IndexFunc(groups, func(g *group) bool { return slices.Equal(g.key, key) })
		if at < 0 {
			groups = append(groups, &group{key: key, runs: nil})
			at = len(groups) - 1
		}
		groups[at].runs = append(groups[at].runs, n)
	}
	slices.SortStableFunc(groups, func(a, b *group) int { return slices.Compare(a.key, b.key) })
	out := make([]Check, 0, len(groups))
	for _, g := range groups {
		slices.SortStableFunc(g.runs, olderThan)
		latest := g.runs[len(g.runs)-1]
		out = append(out, Check{Name: latest.name(), Class: latest.class(), URL: ""})
	}
	return out
}

// Named returns the names of the checks of one class, in order.
func Named(all []Check, class Class) []string {
	var names []string
	for _, c := range all {
		if c.Class == class {
			names = append(names, c.Name)
		}
	}
	return names
}
