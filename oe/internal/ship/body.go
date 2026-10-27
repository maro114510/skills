package ship

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/maro114510/skills/oe/internal/state"
)

// none stands in for an empty section.
const none = "なし"

// evidenceLead says what the evidence in a body is, and that the state is the authority.
const evidenceLead = "Gathered by the independent reviewer on reviewed_sha against verified_base; valid only while both still match. " +
	"This is a snapshot taken when the PR was created; the Issue's state holds the evidence currently bound, and is the one every gate reads."

// Body is what the pull request body is composed from.
type Body struct {
	// Summary and Checks are the worker report's SUMMARY and CHECKS.
	Summary string
	Checks  string
	// Nits is how each reviewer nit was resolved, empty for none.
	Nits string
	// Evidence is the reviewer's bound evidence, never the worker's CRITERIA.
	Evidence     state.ReviewEvidence
	ReviewedSHA  string
	VerifiedBase string
	// Closing are the closing lines for the body.
	Closing []string
	Epic    int
}

// Render composes the body.
func (b Body) Render() string {
	var w strings.Builder
	section := func(title, text string) {
		fmt.Fprintf(&w, "## %s\n%s\n\n", title, orNone(text))
	}
	section("Summary", b.Summary)
	section("Check evidence", b.Checks)

	change := "no"
	if b.Evidence.BehaviorChange {
		change = "yes"
	}
	fmt.Fprintf(&w, "## Acceptance evidence\n%s\nBEHAVIOR_CHANGE: %s — %s\n", evidenceLead, change, strings.TrimSpace(b.Evidence.Basis))
	for i, c := range b.Evidence.Criteria {
		fmt.Fprintf(&w, "%d. %s -> %s [%s] — %s\n", i+1, c.Text, c.Result, c.Kind, c.Evidence)
	}
	fmt.Fprintf(&w, "\n## Review\n- reviewed_sha: %s\n- verified_base: %s\n- Reviewer nits and resolution: %s\n\n",
		b.ReviewedSHA, b.VerifiedBase, orNone(b.Nits))
	for _, line := range b.Closing {
		w.WriteString(line + "\n")
	}
	fmt.Fprintf(&w, "Part of Epic #%d\n", b.Epic)
	return w.String()
}

func orNone(text string) string {
	if text = strings.TrimSpace(text); text == "" {
		return none
	}
	return text
}

var refRE = regexp.MustCompile(`#([0-9]+)\s*$`)

// ClosingLines turns the output of issue-refs.sh into the closing lines of the body.
// An Issue the script printed nothing for gets Closes when nothing was skipped, else Related.
func ClosingLines(refs string, issue int, skipped bool) []string {
	lines := []string{}
	named := false
	for line := range strings.SplitSeq(refs, "\n") {
		if line = strings.TrimSpace(line); line == "" {
			continue
		}
		lines = append(lines, line)
		if m := refRE.FindStringSubmatch(line); m != nil && m[1] == strconv.Itoa(issue) {
			named = true
		}
	}
	if !named {
		keyword := "Closes"
		if skipped {
			keyword = "Related"
		}
		lines = append(lines, fmt.Sprintf("%s #%d", keyword, issue))
	}
	return lines
}

// Skipped reports whether a worker report's SKIPPED field names anything deferred.
func Skipped(field string) bool {
	switch strings.ToLower(strings.TrimSpace(field)) {
	case "", "none", none:
		return false
	}
	return true
}

var prRE = regexp.MustCompile(`/pull/([0-9]+)\s*$`)

// PRNumber reads the pull request number from the URL line create-linked-pr.sh printed.
// The script prints notices before it and link results after it, so the first URL line counts.
func PRNumber(out string) (int, bool) {
	for line := range strings.SplitSeq(out, "\n") {
		if m := prRE.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			var n int
			if _, err := fmt.Sscan(m[1], &n); err == nil && n > 0 {
				return n, true
			}
		}
	}
	return 0, false
}

var referenceRE = regexp.MustCompile(`(?i)^\s*(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|related):?\s+#([0-9]+)\b`)
var fenceRE = regexp.MustCompile("^\\s*(?:```|~~~)")

// References reports whether a pull request body names the Issue on a Closes or Related line outside a code fence.
func References(body string, issue int) bool {
	fenced := false
	for line := range strings.SplitSeq(body, "\n") {
		if fenceRE.MatchString(line) {
			fenced = !fenced
			continue
		}
		if m := referenceRE.FindStringSubmatch(line); !fenced && m != nil && m[1] == strconv.Itoa(issue) {
			return true
		}
	}
	return false
}
