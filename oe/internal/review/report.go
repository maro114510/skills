// Package review holds what passes between the loop and a reviewer.
//   - Parse reads the reviewer report strictly.
//   - Evaluate and CheckFailures check the form of its evidence.
//   - Render writes the reviewer's whole prompt.
//
// Whether evidence proves its criterion stays the reviewer's judgment, and oe checks form only.
// The package reads and writes nothing.
package review

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The verdicts a reviewer gives.
const (
	VerdictApprove        = "APPROVE"
	VerdictRequestChanges = "REQUEST_CHANGES"
)

// The severities a finding carries.
const (
	SeverityBlocking = "blocking"
	SeverityNit      = "nit"
)

// The criterion results and kinds a CRITERIA item gives.
const (
	ResultVerified   = "verified"
	ResultUnverified = "unverified"
	KindBehavior     = "behavior"
	KindStatic       = "static"
)

// none is what a reviewer writes for an empty FINDINGS or CHECKS.
const none = "none"

// fields are the report's fields, in the order the reviewer prints them.
var fields = []string{ //nolint:gochecknoglobals // A fixed table of the report format.
	"VERDICT", "REPO", "ISSUE", "BRANCH", "REVIEWED_HEAD", "REVIEWED_BASE", "CHECKS_REVISION",
	"BEHAVIOR_CHANGE", "CRITERIA", "CHECKS", "FINDINGS",
}

// Criterion is one CRITERIA item as the reviewer wrote it.
// Text and Evidence stay verbatim, so an approval binds the reviewer's own words and never a summary.
type Criterion struct {
	Index    int
	Text     string
	Result   string
	Kind     string
	Evidence string
	// Problem says why the item has no readable result, and is empty otherwise.
	Problem string
}

// Check is one CHECKS line with the command and the exit status the reviewer saw.
type Check struct {
	Label string
	Exit  int
	// Problem says why the line has no readable exit status, and is empty otherwise.
	Problem string
}

// Finding is one FINDINGS item.
// Severity is blocking unless the item names itself a nit.
type Finding struct {
	Severity string
	Text     string
}

// String is the finding as a fix cycle carries it.
func (f Finding) String() string { return "[" + f.Severity + "] " + f.Text }

// Report is a parsed reviewer report.
// A missing field is empty and never makes the report malformed.
//   - A missing identity makes the report another review's.
//   - Missing evidence fails validation.
type Report struct {
	Verdict        string
	Repo           string
	Issue          int
	Branch         string
	ReviewedHead   string
	ReviewedBase   string
	ChecksRevision string
	// BehaviorChange is yes or no, and empty when the field is missing or gives neither.
	BehaviorChange string
	Basis          string
	// HasCriteria and HasChecks say whether the field was given at all.
	HasCriteria bool
	Criteria    []Criterion
	HasChecks   bool
	Checks      []Check
	Findings    []Finding
}

// ErrMalformed marks a report that does not follow the format and so binds nothing.
var ErrMalformed = errors.New("malformed reviewer report")

var (
	fieldRe    = regexp.MustCompile(`^([A-Z_]+):(?:[ \t]+(.*)|)$`)
	issueRe    = regexp.MustCompile(`^#?([1-9][0-9]*)$`)
	itemRe     = regexp.MustCompile(`^\s*([0-9]+)[.)][ \t]+(.*)$`)
	behaviorRe = regexp.MustCompile(`(?i)^(yes|no)\b[ \t]*(?:[—–:-][ \t]*)?(.*)$`)
	verifiedRe = regexp.MustCompile(`(?s)^verified[ \t]*\[(behavior|static)\][ \t]*(?:[—–:-][ \t]*)?(.*)$`)
	unverifRe  = regexp.MustCompile(`(?s)^unverified\b[ \t]*(?:[—–:-][ \t]*)?(.*)$`)
	checkRe    = regexp.MustCompile(`^(.*?)[ \t]*->[ \t]*exit[ \t]+(-?[0-9]+)[ \t]*$`)
	severityRe = regexp.MustCompile(`(?i)^(?:\[(blocking|nit)\]|(blocking|nit)\b)(?:[ \t]*[:—–-])?[ \t]*`)
	resultRe   = regexp.MustCompile(` -> (?:verified[ \t]*\[|unverified\b)`)
)

func malformed(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrMalformed, fmt.Sprintf(format, args...))
}

// Parse reads a reviewer report.
// The first non-blank line is VERDICT, and each known field runs from its line to the next field.
// One surrounding code fence is tolerated.
// These make the report malformed.
//   - A field given twice.
//   - Text before VERDICT.
//   - A verdict other than APPROVE or REQUEST_CHANGES.
//   - REQUEST_CHANGES without a blocking finding.
func Parse(text string) (Report, error) {
	vals, err := collect(unfence(strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")))
	if err != nil {
		return Report{}, err
	}
	get := func(k string) string {
		if b, ok := vals[k]; ok {
			return strings.TrimSpace(b.String())
		}
		return ""
	}
	_, hasCriteria := vals["CRITERIA"]
	_, hasChecks := vals["CHECKS"]
	r := Report{
		Verdict: get("VERDICT"), Repo: get("REPO"), Issue: 0, Branch: get("BRANCH"),
		ReviewedHead: get("REVIEWED_HEAD"), ReviewedBase: get("REVIEWED_BASE"), ChecksRevision: get("CHECKS_REVISION"),
		BehaviorChange: "", Basis: "", HasCriteria: hasCriteria, Criteria: parseCriteria(get("CRITERIA")),
		HasChecks: hasChecks, Checks: parseChecks(get("CHECKS")), Findings: parseFindings(get("FINDINGS")),
	}
	if m := issueRe.FindStringSubmatch(get("ISSUE")); m != nil {
		r.Issue, _ = strconv.Atoi(m[1])
	}
	if m := behaviorRe.FindStringSubmatch(get("BEHAVIOR_CHANGE")); m != nil {
		r.BehaviorChange, r.Basis = strings.ToLower(m[1]), strings.TrimSpace(m[2])
	}
	return r, r.check()
}

func (r Report) check() error {
	switch r.Verdict {
	case VerdictApprove:
		return nil
	case VerdictRequestChanges:
		if !slices.ContainsFunc(r.Findings, func(f Finding) bool { return f.Severity == SeverityBlocking }) {
			return malformed("REQUEST_CHANGES needs at least one blocking finding")
		}
		return nil
	default:
		return malformed("VERDICT %q is not APPROVE or REQUEST_CHANGES", r.Verdict)
	}
}

// collect splits the lines into fields, each running from its line to the next field.
func collect(lines []string) (map[string]*strings.Builder, error) {
	vals := map[string]*strings.Builder{}
	var cur *strings.Builder
	for _, line := range lines {
		if m := fieldRe.FindStringSubmatch(line); m != nil && slices.Contains(fields, m[1]) {
			if _, dup := vals[m[1]]; dup {
				return nil, malformed("%s appears twice", m[1])
			}
			if len(vals) == 0 && m[1] != "VERDICT" {
				return nil, malformed("the report must start with VERDICT, not %s", m[1])
			}
			cur = &strings.Builder{}
			cur.WriteString(m[2])
			vals[m[1]] = cur
			continue
		}
		if cur == nil {
			if strings.TrimSpace(line) != "" {
				return nil, malformed("text before VERDICT")
			}
			continue
		}
		cur.WriteString("\n" + line)
	}
	if len(vals) == 0 {
		return nil, malformed("the reviewer returned no report")
	}
	return vals, nil
}

// items splits a numbered list, where each numbered line starts an item and later lines continue it.
// Text before the first number becomes an item of its own, so nothing is dropped.
func items(text string) []string {
	if strings.TrimSpace(text) == "" || strings.EqualFold(strings.TrimSpace(text), none) {
		return nil
	}
	var out []string
	for line := range strings.SplitSeq(text, "\n") {
		if m := itemRe.FindStringSubmatch(line); m != nil {
			out = append(out, m[2])
			continue
		}
		if len(out) == 0 {
			if strings.TrimSpace(line) != "" {
				out = append(out, strings.TrimSpace(line))
			}
			continue
		}
		out[len(out)-1] += "\n" + line
	}
	for i := range out {
		out[i] = strings.TrimSpace(out[i])
	}
	return out
}

func parseCriteria(text string) []Criterion {
	list := items(text)
	out := make([]Criterion, 0, len(list))
	for i, it := range list {
		out = append(out, parseCriterion(i+1, it))
	}
	return out
}

// parseCriterion splits an item at the first arrow followed by a result word.
// An arrow quoted in the criterion or in the evidence is kept.
func parseCriterion(i int, item string) Criterion {
	c := Criterion{Index: i, Text: item, Result: "", Kind: "", Evidence: "", Problem: ""}
	loc := resultRe.FindStringIndex(item)
	if loc == nil {
		c.Problem = "it gives no `-> verified [behavior|static]` or `-> unverified` result"
		return c
	}
	at := loc[0]
	c.Text = strings.TrimSpace(item[:at])
	rest := strings.TrimSpace(item[at+len(" -> "):])
	if m := verifiedRe.FindStringSubmatch(rest); m != nil {
		c.Result, c.Kind, c.Evidence = ResultVerified, m[1], strings.TrimSpace(m[2])
		return c
	}
	if m := unverifRe.FindStringSubmatch(rest); m != nil {
		c.Result, c.Evidence = ResultUnverified, strings.TrimSpace(m[1])
		return c
	}
	c.Problem = "its result is neither `verified [behavior|static]` nor `unverified`"
	return c
}

func parseChecks(text string) []Check {
	list := items(text)
	out := make([]Check, 0, len(list))
	for _, it := range list {
		c := Check{Label: it, Exit: 0, Problem: ""}
		m := checkRe.FindStringSubmatch(it)
		if m == nil {
			c.Problem = "it gives no `-> exit <code>`"
			out = append(out, c)
			continue
		}
		code, err := strconv.Atoi(m[2])
		c.Label, c.Exit = strings.TrimSpace(m[1]), code
		if err != nil {
			c.Problem = "its exit code is not a number"
		}
		out = append(out, c)
	}
	return out
}

// parseFindings reads each item's severity.
// An item that names none is blocking, since every finding blocks binding anyway.
func parseFindings(text string) []Finding {
	list := items(text)
	out := make([]Finding, 0, len(list))
	for _, it := range list {
		f := Finding{Severity: SeverityBlocking, Text: it}
		if m := severityRe.FindStringSubmatch(it); m != nil {
			f.Severity, f.Text = strings.ToLower(m[1]+m[2]), strings.TrimSpace(it[len(m[0]):])
		}
		out = append(out, f)
	}
	return out
}

// unfence drops blank edges and one code fence wrapping the whole report.
func unfence(lines []string) []string {
	for len(lines) > 0 && strings.TrimSpace(lines[0]) == "" {
		lines = lines[1:]
	}
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) >= 2 && strings.HasPrefix(strings.TrimSpace(lines[0]), "```") && strings.TrimSpace(lines[len(lines)-1]) == "```" {
		return lines[1 : len(lines)-1]
	}
	return lines
}
