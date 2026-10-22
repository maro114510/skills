package review

import (
	"fmt"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/state"
)

// Evidence is the report's evidence as an approval would bind it, with every reason it cannot.
// Each failure reads as a blocking finding that a fresh worker can act on.
type Evidence struct {
	Bound    state.ReviewEvidence
	Failures []string
}

// Evaluate checks the form of the evidence and never judges whether it proves its criterion.
//   - BEHAVIOR_CHANGE and CRITERIA are given.
//   - Every criterion is verified with a kind and evidence after its tag.
//   - A behavior change has behavior evidence.
func Evaluate(r Report) Evidence {
	ev := Evidence{
		Bound:    state.ReviewEvidence{BehaviorChange: r.BehaviorChange == "yes", Basis: r.Basis, Criteria: []state.Criterion{}},
		Failures: nil,
	}
	fail := func(format string, args ...any) { ev.Failures = append(ev.Failures, fmt.Sprintf(format, args...)) }
	if r.BehaviorChange == "" {
		fail("BEHAVIOR_CHANGE is missing or is neither yes nor no; the review must say whether behavior changed and why")
	}
	if !r.HasCriteria || len(r.Criteria) == 0 {
		fail("CRITERIA lists no criterion; the review must quote every acceptance criterion with its evidence")
	}
	behavior := false
	for _, c := range r.Criteria {
		if why := criterionFailure(c); why != "" {
			fail("criterion %d %q -> %s", c.Index, oneLine(c.Text), why)
			continue
		}
		behavior = behavior || c.Kind == KindBehavior
		ev.Bound.Criteria = append(ev.Bound.Criteria, state.Criterion{Text: c.Text, Result: c.Result, Kind: c.Kind, Evidence: c.Evidence})
	}
	if r.BehaviorChange == "yes" && !behavior {
		fail("BEHAVIOR_CHANGE is yes and no criterion carries [behavior] evidence; demonstrate the new behavior through its interface, " +
			"since passing checks and reading alone never show it exists")
	}
	return ev
}

func criterionFailure(c Criterion) string {
	switch {
	case c.Problem != "":
		return c.Problem
	case c.Result == ResultUnverified:
		missing := oneLine(c.Evidence)
		if missing == "" {
			missing = "evidence"
		}
		return "unverified; verify it and give its evidence (" + missing + ")"
	case c.Evidence == "":
		return "verified with no evidence after its tag; give the evidence"
	}
	return ""
}

// CheckFailures lists every CHECKS problem that blocks binding.
//   - A red entry.
//   - A line oe cannot read.
//   - No line at all while CHECKS_SET has runnable entries.
//   - No line numbered for one of the runnable entries.
func CheckFailures(r Report, runnable int) []string {
	var out []string
	if runnable > 0 && len(r.Checks) == 0 {
		out = append(out, fmt.Sprintf("CHECKS lists no run although CHECKS_SET has %d runnable entries; run them and report each exit status", runnable))
	}
	for e := 1; len(r.Checks) > 0 && e <= runnable; e++ {
		if !slices.ContainsFunc(r.Checks, func(c Check) bool { return c.Entry == e }) {
			out = append(out, fmt.Sprintf("CHECKS has no line for runnable entry %d; run every entry and report it under its number", e))
		}
	}
	for i, c := range r.Checks {
		switch {
		case c.Problem != "":
			out = append(out, fmt.Sprintf("CHECKS line %d %q: %s", i+1, oneLine(c.Label), c.Problem))
		case c.Exit != 0:
			out = append(out, fmt.Sprintf("check %q exited %d; a red CHECKS_SET entry blocks approval", oneLine(c.Label), c.Exit))
		}
	}
	return out
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }
