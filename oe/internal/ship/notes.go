package ship

import (
	"errors"
	"fmt"

	"github.com/maro114510/skills/oe/internal/coord"
)

// ExternalPushNote says a branch is on the remote that no recorded publish explains.
// The loop stops and pushes nothing, since overwriting or building on it could lose someone's work.
func ExternalPushNote(n int, branch, remote string) string {
	where := fmt.Sprintf("`origin/%s` は `%s` にあります", branch, remote)
	if remote == "" {
		where = fmt.Sprintf("`origin/%s` は存在しません", branch)
	}
	return fmt.Sprintf("#%d の公開を止めました。\n\n%s。ループが記録した公開（publish）ではこの状態を説明できないため、"+
		"外部の push の可能性があります。何も push せず、PR も作っていません。\n\n"+
		"ブランチの内容を確認し、`epic-retry` または `epic-redo` を書いたコメントで再開してください。\n", n, where)
}

// LinkFailedNote says the pull request exists but is not linked to its Issue.
// Publishing went on, since the pull request itself is correct.
func LinkFailedNote(n, pr, exit int) string {
	return fmt.Sprintf("PR #%d を #%d に紐付けられませんでした（create-linked-pr.sh が exit %d）。\n\n"+
		"PR は作成済みで、公開は完了しています。手動で `Closes #%d` の紐付けを確認してください。\n", pr, n, exit, n)
}

// LinkMissingNote says an existing pull request was reused but its body does not name the Issue.
func LinkMissingNote(n, pr int) string {
	return fmt.Sprintf("PR #%d は既に存在し、本文に #%d への `Closes` / `Related` の行がありません。\n\n"+
		"公開は完了していますが、マージしても #%d は閉じません。PR 本文に `Closes #%d` を追加してください。\n", pr, n, n, n)
}

// asScan reports whether err is a note the secret scan refused.
func asScan(err error) (*coord.ScanError, bool) {
	scanErr, ok := errors.AsType[*coord.ScanError](err)
	return scanErr, ok
}
