package land

import (
	"fmt"
	"strings"

	"github.com/maro114510/skills/oe/internal/state"
)

// maxDetail bounds a GitHub message quoted in a note.
const maxDetail = 300

func oneLine(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > maxDetail {
		return string(r[:maxDetail]) + "…"
	}
	return s
}

// MergeHoldNote says why a pull request is not merged and only a person can lift the hold.
func MergeHoldNote(pr int, head, reason string) string {
	return fmt.Sprintf("PR #%d は、ループでは解消できない理由があるためマージを保留しています。人の対応をお願いします。\n\n"+
		"HEAD: %s\n理由: %s\n\n"+
		"ループはリポジトリ側の制御を迂回しません（`--admin` もリポジトリ設定の変更も行いません）。"+
		"対応が済むと、次の landing pass か次回の実行で改めて判定します。\n", pr, head, oneLine(reason))
}

// meaning is the one line each merge result adds to its note.
func meaning(result string) string {
	switch result {
	case state.PhaseMerged:
		return "マージされました。"
	case state.PhaseMergedUnverifiedBase:
		return "マージされましたが、直前に default branch が進んでいたため、検証していない base の上に入りました。" +
			"Epic を凍結し、以降のマージを止めました。自動で revert はしません。default branch の状態を確認してください。"
	case state.PhaseHeadMoved:
		return "レビュー後に HEAD が変わったため GitHub がマージを拒否しました。再検証してからやり直します。"
	case state.PhaseRejected:
		return "リポジトリがマージを拒否しました。理由を確認してください。"
	case state.PhaseNotMerged:
		return "PR はマージされていません。マージ要求が届かなかったか、拒否されたものとして扱い、次の landing pass で改めて判定します。"
	default:
		return "マージ要求の応答を受け取れず、マージされたかも確認できませんでした。この実行ではこれ以上マージしません。"
	}
}

// MergeResultNote records how a merge request ended. The next pull request is not merged until it is written.
func MergeResultNote(pr int, reviewed, base, method, result, detail string) string {
	if method == "" {
		method = "不明"
	}
	return fmt.Sprintf("PR #%d のマージ結果: %s\n\n"+
		"- expected SHA (reviewed_sha): %s\n- verified_base: %s\n- 方式: %s\n- 詳細: %s\n\n%s\n",
		pr, result, reviewed, base, method, oneLine(detail), meaning(result))
}

// RepairNote records that a pull request's repair was handed to a worker, so the same head and window are never handed over twice.
func RepairNote(pr int, head string, kinds []string, since int64) string {
	return fmt.Sprintf("PR #%d の修復を worker に依頼しました（種類: %s）。\n\nHEAD: %s\n指摘の既読位置（since）: %d\n",
		pr, strings.Join(kinds, ", "), head, since)
}
