package round

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/coord"
)

// Poster is the single comment writer, contract §7. *coord.Session satisfies it.
type Poster interface {
	PostNote(ctx context.Context, on int, key, text string) (coord.NoteResult, error)
}

// NotifyResult is what executing the board's notifications did.
type NotifyResult struct {
	// Notes are the writer's answers: Posted is false for a note that was already there.
	Notes []coord.NoteResult `json:"notes"`
	// Skipped are the proposed notes another command posts, by key.
	Skipped []string `json:"skipped"`
}

// Notify posts the notes the board proposes for a leftover placeholder token, a dependency
// cycle, a rejected Issue, a merged pull request on an open Issue, and a dispatch whose branch
// is gone. The stale-verdict and freeze notes belong to the review and the ledger, which post
// them where they write the state, so they are skipped. Each note goes through the writer, which
// posts a key once, so proposing the same note on every invocation posts it once. It stops at
// the first note the writer refuses and returns what it had posted.
func Notify(ctx context.Context, p Poster, notes []board.Notification) (NotifyResult, error) {
	res := NotifyResult{Notes: []coord.NoteResult{}, Skipped: []string{}}
	for _, n := range notes {
		text, ok := noteText(n)
		if !ok {
			res.Skipped = append(res.Skipped, n.Key)
			continue
		}
		out, err := p.PostNote(ctx, n.On, n.Key, text)
		if err != nil {
			return res, err
		}
		res.Notes = append(res.Notes, out)
	}
	return res, nil
}

// noteText is the Japanese prose of a note this command posts, from oe's own templates. It names
// only what the board found, and never quotes an Issue body.
func noteText(n board.Notification) (string, bool) {
	// A key is <kind>:<Issue>:<detail>, and a branch name never holds a colon.
	parts := strings.SplitN(n.Key, ":", keyParts)
	detail := parts[len(parts)-1]
	switch n.Kind {
	case board.NoteDepCycle:
		return depCycleText(n.Issues), true
	case board.NoteLeftoverToken:
		return fmt.Sprintf("#%d の本文にプレースホルダー %s が残っています。\n\n"+
			"Issue の作成が途中で失敗した可能性があります。リンクを確認し、本文の置き換えを手動で行ってください。"+
			"ループは本文を書き換えません。\n", n.On, strings.Join(n.Tokens, "、")), true
	case board.NoteRejected:
		return fmt.Sprintf("#%d の PR #%s は、マージされないまま閉じられました。\n\n"+
			"ループは自動では再開しません。新しいブランチで実装し直すなら `epic-redo`、このまま見送るなら `epic-drop` を、"+
			"そのどちらか 1 つだけを書いたコメントで決めてください。OWNER・MEMBER・COLLABORATOR のコメントだけを読み取ります。"+
			"理由は別のコメントに自由に書いてください。\n", n.On, detail), true
	case board.NoteMergedOpen:
		return fmt.Sprintf("#%d のブランチの PR #%s はマージ済みですが、Issue はまだ open です。\n\n"+
			"マージ済みのブランチへは再 dispatch しません。作業が完了しているなら Issue を閉じてください。"+
			"ループは Issue を閉じません。続きの作業が必要なら、`epic-redo` を書いたコメントで新しいブランチを使えます。\n", n.On, detail), true
	case board.NoteStaleStart:
		return fmt.Sprintf("#%d の dispatch は記録されていますが、ブランチ `%s` はどこにも残っていません。\n\n"+
			"次の dispatch で、default branch から同じ名前のブランチを作り直します。\n", n.On, detail), true
	case board.NoteStale, board.NoteFreeze:
		return "", false
	}
	return "", false
}

// keyParts is how many colon-separated parts a note key has at most: kind, Issue, detail.
const keyParts = 3

func depCycleText(issues []int) string {
	names := make([]string, 0, len(issues))
	for _, n := range issues {
		names = append(names, "#"+strconv.Itoa(n))
	}
	return fmt.Sprintf("Issue %s は依存関係（blocked-by）が循環しているため、dispatch・再検証・マージを行いません。\n\n"+
		"循環を解消してください。解消後の次の実行で、改めて判定します。\n", strings.Join(names, "、"))
}
