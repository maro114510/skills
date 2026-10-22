package handoff

import (
	"fmt"
	"strings"
)

// ShipClass is one kind of the closed ship-class set: questions that decide whether, or in how
// many pieces, work ships. The loop never answers one and parks the Issue instead.
type ShipClass string

// The ship-class kinds.
const (
	ShipSecret ShipClass = "secret"
	ShipSplit  ShipClass = "split"
	ShipScope  ShipClass = "scope"
)

// ParseShipClass accepts only a kind of the closed set.
func ParseShipClass(s string) (ShipClass, bool) {
	switch k := ShipClass(s); k {
	case ShipSecret, ShipSplit, ShipScope:
		return k, true
	default:
		return "", false
	}
}

func (k ShipClass) label() string {
	switch k {
	case ShipSecret:
		return "suspected secret（秘密情報の疑い）"
	case ShipSplit:
		return "change-size split（変更の分割）"
	case ShipScope:
		return "scope dispute（範囲の争い）"
	default:
		return string(k)
	}
}

// The first lines of a report note, which tell a FAILED record from a DONE one.
const (
	reportHeadDone   = "作業者の報告: DONE"
	reportHeadFailed = "作業者の報告: FAILED"
)

// sessionLine ends an answer the loop gave itself, naming the session's digest, so a second
// BLOCKED in the same session is never answered by the loop again.
const sessionLine = "<!-- oe:auto-answer %s -->"

// decideLine tells a person how a parked Issue moves again.
const decideLine = "再開するかは、`epic-retry`、`epic-redo`、`epic-drop` のどれか 1 つだけを書いたコメントで決めてください。" +
	"OWNER・MEMBER・COLLABORATOR のコメントだけを読み取ります。理由や方針は別のコメントに自由に書いてください。" +
	"そのコメントは次の worker への指示書に全文で入ります。"

// BlockedNote is the question a BLOCKED worker asked, put on the Issue before anything else
// records the report, so no later session re-dispatches without it.
func BlockedNote(n int, questions string) string {
	return fmt.Sprintf("worker が #%d の実装を止めて確認を求めています。\n\n%s\n\n"+
		"回答はこの Issue へのコメントとして自由に書いてください。OWNER・MEMBER・COLLABORATOR の回答は、"+
		"次の worker への指示書に全文で入ります。\n"+
		"この Issue は parked ではないため、`epic-retry` / `epic-redo` / `epic-drop` は不要です。\n",
		n, strings.TrimSpace(questions))
}

// AnswerNote is an answer the loop gave from written sources, with the session that gave it.
func AnswerNote(questions, answer, session string) string {
	return fmt.Sprintf("worker の質問に、記録済みの資料から回答しました。\n\n### 質問\n\n%s\n\n### 回答\n\n%s\n\n"+sessionLine+"\n",
		strings.TrimSpace(questions), strings.TrimSpace(answer), session)
}

// AnsweredIn reports whether an answer note was given by the session with this digest.
func AnsweredIn(body, session string) bool {
	return strings.Contains(body, fmt.Sprintf(sessionLine, session))
}

// ShipClassNote parks the Issue on a ship-class question. A secret's question text, or an empty
// one the caller withheld, is never posted, since posting it would publish what it is about.
func ShipClassNote(n int, kind ShipClass, questions string) string {
	body := strings.TrimSpace(questions)
	if kind == ShipSecret || body == "" {
		body = "質問の本文は、秘密情報を含むおそれがあるため掲載しません。worktree の変更を直接確認してください。"
	}
	return fmt.Sprintf("ship-class の判断が必要なため、#%d を保留しました。\n\n種類: %s\n\n%s\n\n"+
		"この問いはループ自身では決めません。時間の経過や無回答を承認として扱わず、回答が無い限り再開しません。\n%s\n",
		n, kind.label(), body, decideLine)
}

// DoneReportNote records what a DONE worker skipped, decided, and found, as the report gave it.
func DoneReportNote(head string, r Report) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s（%s）\n", reportHeadDone, head)
	section(&b, "見送った項目", r.Skipped)
	section(&b, "判断の記録", r.Summary)
	section(&b, "範囲外で見つけた不具合", r.Found)
	return b.String()
}

// FailedReportNote records why an attempt failed, so the retry's brief carries it.
func FailedReportNote(reason string) string {
	return fmt.Sprintf("%s\n\n%s\n", reportHeadFailed, strings.TrimSpace(reason))
}

// IsFailedReport reports whether a report note's text records a FAILED attempt.
func IsFailedReport(text string) bool { return strings.HasPrefix(text, reportHeadFailed) }

// ParkedNote says why the loop parked an Issue.
func ParkedNote(n int, why string) string {
	return fmt.Sprintf("#%d を停止しました。\n\n%s\n\n%s\n", n, strings.TrimSpace(why), decideLine)
}

func section(b *strings.Builder, title, text string) {
	text = strings.TrimSpace(text)
	if text == "" {
		text = "なし"
	}
	fmt.Fprintf(b, "\n### %s\n\n%s\n", title, text)
}
