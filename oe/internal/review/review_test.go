package review_test

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/review"
)

const (
	head = "0123456789abcdef0123456789abcdef01234567"
	base = "fedcba9876543210fedcba9876543210fedcba98"
)

func report(verdict, behavior, criteria, checksText, findings string) string {
	return "VERDICT: " + verdict + "\nREPO: o/r\nISSUE: #7\nBRANCH: feat/issue-7\nREVIEWED_HEAD: " + head +
		"\nREVIEWED_BASE: " + base + "\nCHECKS_REVISION: " + base + "\nBEHAVIOR_CHANGE: " + behavior +
		"\nCRITERIA:\n" + criteria + "\nCHECKS:\n" + checksText + "\nFINDINGS:\n" + findings + "\n"
}

const (
	behaviorCriterion = "1. `oe review pin` merges the base -> verified [behavior] — ran TestPin, exit 0"
	staticCriterion   = "2. The contract names the field -> verified [static] — contract.md:99"
	greenChecks       = "1. go test ./... -> exit 0"
)

func mustParse(t *testing.T, text string) review.Report {
	t.Helper()
	r, err := review.Parse(text)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return r
}

func TestParseReadsEveryField(t *testing.T) {
	t.Parallel()

	text := "```\n" + report("APPROVE", "yes — the pin merges now", behaviorCriterion+"\n"+staticCriterion, greenChecks,
		"1. [nit] cmd/review.go:10 — wording\n   continues here") + "```\n"
	r := mustParse(t, text)
	got := map[string][2]string{
		"verdict":  {r.Verdict, review.VerdictApprove},
		"repo":     {r.Repo, "o/r"},
		"issue":    {strconv.Itoa(r.Issue), "7"},
		"branch":   {r.Branch, "feat/issue-7"},
		"head":     {r.ReviewedHead, head},
		"base":     {r.ReviewedBase, base},
		"revision": {r.ChecksRevision, base},
		"behavior": {r.BehaviorChange + "|" + r.Basis, "yes|the pin merges now"},
		"criteria": {strconv.Itoa(len(r.Criteria)), "2"},
		"c1": {r.Criteria[0].Kind + "|" + r.Criteria[0].Text + "|" + r.Criteria[0].Evidence,
			"behavior|`oe review pin` merges the base|ran TestPin, exit 0"},
		"c2":      {r.Criteria[1].Kind, review.KindStatic},
		"checks":  {fmt.Sprintf("%d|%s|%d", len(r.Checks), r.Checks[0].Label, r.Checks[0].Exit), "1|go test ./...|0"},
		"finding": {fmt.Sprintf("%d|%s", len(r.Findings), r.Findings[0].Severity), "1|nit"},
	}
	for name, gw := range got {
		if gw[0] != gw[1] {
			t.Errorf("%s = %q, want %q", name, gw[0], gw[1])
		}
	}
	if !strings.Contains(r.Findings[0].Text, "continues here") {
		t.Errorf("finding lost its continuation: %q", r.Findings[0].Text)
	}
}

// TestCriterionKeepsAnArrowItQuotes shows that a criterion that quotes an arrow is bound verbatim.
func TestCriterionKeepsAnArrowItQuotes(t *testing.T) {
	t.Parallel()

	r := mustParse(t, report("APPROVE", "no — docs", "1. (derived) a -> b maps -> verified [static] — x.go:1", "none", "none"))
	if r.Criteria[0].Text != "(derived) a -> b maps" || r.Criteria[0].Evidence != "x.go:1" {
		t.Errorf("criterion = %+v", r.Criteria[0])
	}
	if len(r.Findings) != 0 || len(r.Checks) != 0 {
		t.Errorf("none parsed as items: %+v %+v", r.Findings, r.Checks)
	}
}

func TestMalformedReportsBindNothing(t *testing.T) {
	t.Parallel()

	for name, text := range map[string]string{
		"empty":                       "",
		"text before VERDICT":         "Here is my review\n" + report("APPROVE", "no — x", staticCriterion, greenChecks, "none"),
		"verdict not first":           "REPO: o/r\nVERDICT: APPROVE\n",
		"unknown verdict":             report("LGTM", "no — x", staticCriterion, greenChecks, "none"),
		"field twice":                 report("APPROVE", "no — x", staticCriterion, greenChecks, "none") + "REPO: o/r\n",
		"REQUEST_CHANGES without one": report("REQUEST_CHANGES", "no — x", staticCriterion, greenChecks, "none"),
		"REQUEST_CHANGES nits only":   report("REQUEST_CHANGES", "no — x", staticCriterion, greenChecks, "1. [nit] style"),
	} {
		if _, err := review.Parse(text); !errors.Is(err, review.ErrMalformed) {
			t.Errorf("%s: %v, want malformed", name, err)
		}
	}
}

// TestEvidenceFormIsValidated shows that each evidence problem fails as a blocking finding that names the criterion.
//   - A missing BEHAVIOR_CHANGE or CRITERIA.
//   - An unverified criterion or one without evidence.
//   - A behavior change with only static evidence.
func TestEvidenceFormIsValidated(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		text string
		want string
	}{
		"no BEHAVIOR_CHANGE":    {strings.Replace(report("APPROVE", "", staticCriterion, greenChecks, "none"), "BEHAVIOR_CHANGE: \n", "", 1), "BEHAVIOR_CHANGE is missing"},
		"no CRITERIA":           {report("APPROVE", "no — x", "", greenChecks, "none"), "CRITERIA lists no criterion"},
		"unverified":            {report("APPROVE", "no — x", "1. it works -> unverified — missing: an e2e run", greenChecks, "none"), `criterion 1 "it works" -> unverified`},
		"no evidence":           {report("APPROVE", "no — x", "1. it works -> verified [static]", greenChecks, "none"), "no evidence after its tag"},
		"no result tag":         {report("APPROVE", "no — x", "1. it works, trust me", greenChecks, "none"), "gives no `-> verified"},
		"behavior, static only": {report("APPROVE", "yes — new flag", staticCriterion, greenChecks, "none"), "no criterion carries [behavior] evidence"},
	}
	for name, tc := range tests {
		ev := review.Evaluate(mustParse(t, tc.text))
		if !strings.Contains(strings.Join(ev.Failures, "\n"), tc.want) {
			t.Errorf("%s: failures %q, want %q", name, ev.Failures, tc.want)
		}
	}
	ok := review.Evaluate(mustParse(t, report("APPROVE", "yes — new flag", behaviorCriterion+"\n"+staticCriterion, greenChecks, "none")))
	if len(ok.Failures) != 0 || !ok.Bound.BehaviorChange || len(ok.Bound.Criteria) != 2 || ok.Bound.Basis != "new flag" {
		t.Errorf("valid evidence = %+v", ok)
	}
}

// TestPassingChecksNeverApproveABehaviorChange shows that green checks and static reading never prove new behavior.
func TestPassingChecksNeverApproveABehaviorChange(t *testing.T) {
	t.Parallel()

	r := mustParse(t, report("APPROVE", "yes — adds review pin", "1. pin merges -> verified [static] — CHECKS_SET passed", greenChecks, "none"))
	if ev := review.Evaluate(r); len(ev.Failures) == 0 || len(review.CheckFailures(r, 1)) != 0 {
		t.Errorf("failures %q", ev.Failures)
	}
}

// TestRedCheckIsABlockingFinding shows that a red entry, an unreadable line, and no run at all while CHECKS_SET has runnable entries each block.
func TestRedCheckIsABlockingFinding(t *testing.T) {
	t.Parallel()

	for name, tc := range map[string]struct {
		checks   string
		runnable int
		want     string
	}{
		"red":        {"1. go test ./... -> exit 1", 1, `check "go test ./..." exited 1`},
		"unreadable": {"1. go test passed", 1, "gives no `-> exit <code>`"},
		"none run":   {"none", 2, "CHECKS lists no run although CHECKS_SET has 2 runnable entries"},
	} {
		got := review.CheckFailures(mustParse(t, report("APPROVE", "no — x", staticCriterion, tc.checks, "none")), tc.runnable)
		if !strings.Contains(strings.Join(got, "\n"), tc.want) {
			t.Errorf("%s: %q, want %q", name, got, tc.want)
		}
	}
	if got := review.CheckFailures(mustParse(t, report("APPROVE", "no — x", staticCriterion, "none", "none")), 0); len(got) != 0 {
		t.Errorf("no runnable entry: %q", got)
	}
}

func TestFindingWithoutASeverityIsBlocking(t *testing.T) {
	t.Parallel()

	r := mustParse(t, report("REQUEST_CHANGES", "no — x", staticCriterion, greenChecks, "1. x.go:3 — nil deref\n2. blocking: y.go:4 — leak"))
	if len(r.Findings) != 2 || r.Findings[0].Severity != review.SeverityBlocking || r.Findings[1].Text != "y.go:4 — leak" {
		t.Errorf("findings = %+v", r.Findings)
	}
	if r.Findings[0].String() != "[blocking] x.go:3 — nil deref" {
		t.Errorf("string = %q", r.Findings[0].String())
	}
}

// TestArrowInTheEvidenceKeepsAVerifiedCriterion shows that evidence that quotes an arrow is never misread as a malformed criterion.
func TestArrowInTheEvidenceKeepsAVerifiedCriterion(t *testing.T) {
	t.Parallel()

	r := mustParse(t, report("APPROVE", "yes — x", "1. pin merges -> verified [behavior] — ran `oe review pin` -> got PINNED", greenChecks, "none"))
	c := r.Criteria[0]
	if c.Problem != "" || c.Text != "pin merges" || c.Evidence != "ran `oe review pin` -> got PINNED" {
		t.Errorf("criterion = %+v", c)
	}
	if ev := review.Evaluate(r); len(ev.Failures) != 0 {
		t.Errorf("failures = %q", ev.Failures)
	}
}

// TestSeverityIsAWholeWord shows that an untagged finding that merely starts with the letters of a severity keeps its text and stays blocking.
func TestSeverityIsAWholeWord(t *testing.T) {
	t.Parallel()

	r := mustParse(t, report("REQUEST_CHANGES", "no — x", staticCriterion, greenChecks, "1. Nitrogen flag is ignored\n2. nit: typo"))
	if r.Findings[0].Severity != review.SeverityBlocking || r.Findings[0].Text != "Nitrogen flag is ignored" ||
		r.Findings[1].Severity != review.SeverityNit || r.Findings[1].Text != "typo" {
		t.Errorf("findings = %+v", r.Findings)
	}
}

// TestOmittedCheckIsABlockingFinding shows that every runnable entry needs its own numbered CHECKS line, so a report cannot leave a red entry out.
func TestOmittedCheckIsABlockingFinding(t *testing.T) {
	t.Parallel()

	r := mustParse(t, report("APPROVE", "no — x", staticCriterion, "1. go test ./... -> exit 0", "none"))
	got := strings.Join(review.CheckFailures(r, 2), "\n")
	if !strings.Contains(got, "no line for runnable entry 2") || strings.Contains(got, "entry 1") {
		t.Errorf("failures = %q", got)
	}
	if got := review.CheckFailures(mustParse(t, report("APPROVE", "no — x", staticCriterion, "1. a -> exit 0\n2. b -> exit 0", "none")), 2); len(got) != 0 {
		t.Errorf("complete CHECKS: %q", got)
	}
}

// TestCriterionWithoutTextFailsValidation shows that an item with a result but no criterion text is a blocking finding and is never bound.
func TestCriterionWithoutTextFailsValidation(t *testing.T) {
	t.Parallel()

	ev := review.Evaluate(mustParse(t, report("APPROVE", "no — x", "1. -> verified [static] — x.go:1", greenChecks, "none")))
	if !strings.Contains(strings.Join(ev.Failures, "\n"), "no criterion text") || len(ev.Bound.Criteria) != 0 {
		t.Errorf("evidence = %+v", ev)
	}
}
