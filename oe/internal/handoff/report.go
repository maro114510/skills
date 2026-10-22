// Package handoff is what passes between the loop and a worker, contract §16: the worker report
// oe parses strictly, the brief oe renders as the worker's whole prompt, and the notes that put
// questions, answers, and report records on the Issue. It reads and writes nothing itself.
package handoff

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The worker report statuses.
const (
	StatusDone    = "DONE"
	StatusBlocked = "BLOCKED"
	StatusFailed  = "FAILED"
)

// fields are the report's fields, in the order implement's Autonomous Mode prints them.
var fields = []string{ //nolint:gochecknoglobals // A fixed table of the report format.
	"STATUS", "ISSUE", "BRANCH", "WORKTREE", "HEAD_SHA", "CHANGED_FILES", "CHECKS",
	"CRITERIA", "SKIPPED", "FOUND", "SUMMARY", "QUESTIONS", "ERROR",
}

// Report is a parsed worker report.
type Report struct {
	Status       string
	Issue        int
	Branch       string
	Worktree     string
	HeadSHA      string
	ChangedFiles string
	Checks       string
	Criteria     string
	Skipped      string
	Found        string
	Summary      string
	Questions    string
	Error        string
}

// ErrMalformed marks a report that does not follow the format. Such a report is never DONE.
var ErrMalformed = errors.New("malformed worker report")

var (
	fieldRe = regexp.MustCompile(`^([A-Z_]+):(?:[ \t]+(.*)|)$`)
	shaRe   = regexp.MustCompile(`^[0-9a-f]{7,64}$`)
	issueRe = regexp.MustCompile(`^#([1-9][0-9]*)$`)
)

func malformed(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrMalformed, fmt.Sprintf(format, args...))
}

// Parse reads a report. The first non-blank line is STATUS; each known field starts a line and
// runs to the next one; a field given twice, an unknown status, or a field the status needs
// missing makes it malformed. One surrounding code fence is tolerated.
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
	r := Report{
		Status: get("STATUS"), Issue: 0, Branch: get("BRANCH"), Worktree: get("WORKTREE"), HeadSHA: get("HEAD_SHA"),
		ChangedFiles: get("CHANGED_FILES"), Checks: get("CHECKS"), Criteria: get("CRITERIA"), Skipped: get("SKIPPED"),
		Found: get("FOUND"), Summary: get("SUMMARY"), Questions: get("QUESTIONS"), Error: get("ERROR"),
	}
	if m := issueRe.FindStringSubmatch(get("ISSUE")); m != nil {
		r.Issue, _ = strconv.Atoi(m[1])
	}
	return r, r.check(vals)
}

// collect splits the lines into fields: each known field starts a line and runs to the next.
func collect(lines []string) (map[string]*strings.Builder, error) {
	vals := map[string]*strings.Builder{}
	var cur *strings.Builder
	for _, line := range lines {
		if m := fieldRe.FindStringSubmatch(line); m != nil && known(m[1]) {
			if _, dup := vals[m[1]]; dup {
				return nil, malformed("%s appears twice", m[1])
			}
			if len(vals) == 0 && m[1] != "STATUS" {
				return nil, malformed("the report must start with STATUS, not %s", m[1])
			}
			cur = &strings.Builder{}
			cur.WriteString(m[2])
			vals[m[1]] = cur
			continue
		}
		if cur == nil {
			if strings.TrimSpace(line) != "" {
				return nil, malformed("text before STATUS")
			}
			continue
		}
		cur.WriteString("\n" + line)
	}
	if len(vals) == 0 {
		return nil, malformed("the worker returned no report")
	}
	return vals, nil
}

func (r Report) check(vals map[string]*strings.Builder) error {
	for _, k := range []string{"ISSUE", "BRANCH", "WORKTREE"} {
		if _, ok := vals[k]; !ok {
			return malformed("%s is missing", k)
		}
	}
	if r.Issue == 0 {
		return malformed("ISSUE is not #<number>")
	}
	return r.checkStatus()
}

// checkStatus requires what each status carries: a head for DONE, questions for BLOCKED, and an
// error for FAILED, so a retry never starts without knowing what went wrong.
func (r Report) checkStatus() error {
	switch r.Status {
	case StatusDone:
		if !shaRe.MatchString(r.HeadSHA) {
			return malformed("a DONE report needs its HEAD_SHA, got %q", r.HeadSHA)
		}
	case StatusBlocked:
		if r.Questions == "" {
			return malformed("a BLOCKED report needs its QUESTIONS")
		}
	case StatusFailed:
		if r.Error == "" {
			return malformed("a FAILED report needs its ERROR")
		}
	default:
		return malformed("STATUS %q is not DONE, BLOCKED, or FAILED", r.Status)
	}
	return nil
}

func known(k string) bool { return slices.Contains(fields, k) }

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
