package round

import (
	"cmp"
	"fmt"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/protocol"
)

// The headings of a report note and an answer note, as the handoff package writes them. The
// round-trip test of assumptions fails if they drift apart.
const (
	headingSkipped  = "見送った項目"
	headingDecision = "判断の記録"
	headingQuestion = "質問"
	headingAnswer   = "回答"
	noneText        = "なし"
	decisionArrow   = " -> "
)

// addNotes reads the assumptions and the lost dispatches out of one Issue's notes, in the order
// the notes were posted. A FAILED record is no assumption.
func (ev *evidence) addNotes(n int, idx protocol.Index) {
	for key := range idx.Notes {
		if strings.HasPrefix(key, fmt.Sprintf("stale-start:%d:", n)) {
			ev.staleStarts++
		}
	}
	for _, c := range recordNotes(n, idx) {
		text := noteBody(c.Body)
		switch {
		case handoff.IsFailedReport(text):
		case strings.HasPrefix(text, "作業者の報告"):
			ev.assumptions = append(ev.assumptions, reportAssumptions(n, text)...)
		default:
			if q, a, ok := answerOf(text); ok {
				ev.assumptions = append(ev.assumptions, Assumption{Issue: n, Kind: AssumptionAnswer, Text: "質問: " + clip(q) + " / 回答: " + clip(a)})
			}
		}
	}
}

// recordNotes are the report and answered-Q&A notes of an Issue, the first posted of each key,
// so a note is read once however many times it was posted, in comment order.
func recordNotes(n int, idx protocol.Index) []protocol.Comment {
	var notes []protocol.Comment
	for key, cs := range idx.Notes {
		if !strings.HasPrefix(key, fmt.Sprintf("report:%d:", n)) && !strings.HasPrefix(key, fmt.Sprintf("qa:%d:", n)) {
			continue
		}
		notes = append(notes, slices.MinFunc(cs, func(a, b protocol.Comment) int { return cmp.Compare(a.ID, b.ID) }))
	}
	slices.SortFunc(notes, func(a, b protocol.Comment) int { return cmp.Compare(a.ID, b.ID) })
	return notes
}

// noteBody is a note's text without its marker line.
func noteBody(body string) string {
	_, text, _ := strings.Cut(strings.TrimLeft(body, " \t\r\n"), "\n")
	return text
}

// reportAssumptions are the skipped entries and the decision-log entries of a DONE record.
func reportAssumptions(n int, text string) []Assumption {
	var out []Assumption
	for _, line := range lines(under(text, headingSkipped)) {
		out = append(out, Assumption{Issue: n, Kind: AssumptionSkipped, Text: clip(line)})
	}
	for _, line := range lines(under(text, headingDecision)) {
		if strings.Contains(line, decisionArrow) {
			out = append(out, Assumption{Issue: n, Kind: AssumptionDecision, Text: clip(line)})
		}
	}
	return out
}

// answerOf reads the question and the answer of an answered-Q&A note.
func answerOf(text string) (question, answer string, ok bool) {
	question, answer = under(text, headingQuestion), under(text, headingAnswer)
	return question, answer, question != "" && answer != ""
}

// under is the text under a "### heading" up to the next heading, or "" when it is absent or says none.
func under(text, heading string) string {
	_, rest, found := strings.Cut(text, "### "+heading+"\n")
	if !found {
		return ""
	}
	body, _, _ := strings.Cut(rest, "\n### ")
	if body = strings.TrimSpace(body); body == noneText {
		return ""
	}
	return body
}

// lines are the non-blank lines of a text, without their list bullets.
func lines(text string) []string {
	var out []string
	for line := range strings.SplitSeq(text, "\n") {
		if line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "- ")); line != "" {
			out = append(out, line)
		}
	}
	return out
}
