# Output templates (Japanese)

すべてのユーザー向け出力は日本語で、このファイルの形式に従う。絵文字は使わず、`[!]` などのテキスト記号を使う。ここにあるのはセッションの本文出力だけで、GitHub のコメントは `oe` が自分のテンプレートで書く。値は `oe` の出力から取り、推測で埋めない。

## Approval Needed

`oe gate` が `run-plan-posted` または `awaiting-approval` を返したとき。

```
[!] Epic #<EPIC> は承認待ちのため、今回は何も実行しません。
Run Plan は Epic のコメントに投稿済みです。内容に問題がなければ、この Epic に `epic-approve` とだけ書いたコメントを投稿してください。この Run Plan より後に、OWNER・MEMBER・COLLABORATOR が投稿したものだけが承認になります。
`epic-approve` を文中に含めただけのコメントや、ラベルは承認になりません。
マージも任せる場合は、別に `epic-auto-merge` とだけ書いたコメントを投稿してください。取り消すときは `epic-revoke-auto-merge` です。
承認したら、もう一度実行してください。
```

## Frozen Epic

凍結中のとき。凍結の通知は GitHub に 1 度だけ出ているので、このメッセージは GitHub には投稿しません。

```
[!] Epic #<EPIC> は凍結中のため、今回は何も実行しません。
理由: <凍結の reason>
予算: worker dispatch <used>/<bound>、reviewer 実行 <used>/<bound>、fix cycle <used>/<bound>
再開するには、Epic に `epic-release` とだけ書いたコメントを投稿してから再実行してください。
```

## Ship Report

`oe ship publish` の結果をまとめる。

```
## Ship 完了

| Issue | PR | 状態 |
|-------|----|------|
| #14 | <PR URL> | 作成済み |
| #16 | - | [!] <route>（理由: <reason>） |
```

## Round Continuation

`oe round next` が `continue` を返したときだけ出力する。GitHub には投稿しない。

```
## Round <k> 完了 — 続けて次の round に進みます

この round でマージした PR: <PR URL 一覧>
前回の実行でマージし、チェック待ちだった PR: <PR URL 一覧、なければ なし>
GitHub の状態を読み直し、このマージで ready になった Issue を dispatch します。
次回の実行に回した Issue: <#N: 理由 の一覧、なければ なし>
これらの Issue は、この実行の以降の round でも扱いません。
```

## Round Boundary

`oe round next` が `end` を返したとき。GitHub には投稿しない。

```
## 今回の実行はここで止まります

止まった理由: <oe round next の reasons、または oe round poll の stop の reason>
今回マージした PR: <PR URL 一覧、なければ なし>
マージ待ち PR:
| PR | 理由 |
|----|------|
| <PR URL> | <マージ権限なし / リポジトリ側で人の確認待ち: <reason> / CI 待ちのポーリング上限 / 再検証待ち / 直前のマージの default branch チェック待ち> |
次回の実行に回した Issue: <#N: 理由 の一覧、なければ なし。理由は 回答待ちの BLOCKED / 再び stale / landing の順番を譲った のいずれか>
片付けなかった worktree: <oe round cleanup の kept の一覧、なければ なし>

続け方:
- いま続ける: マージ権限が無い場合は、上記 PR を 1 件だけマージしてから再実行してください。残りの PR は新しい default branch で再検証します。
- あとで続ける: このまま終了して構いません。再実行すれば GitHub の状態から再開します。

並列数上限で今回見送った Issue がある場合は、次の行を必ず添える:
「#19, #20 は並列数上限で見送っただけなので、マージを待たずに再実行すれば次のバッチを開始できます。」
```

## Escalation

`parked` になった Issue を報告するとき。

```
[!] #<N> は今回の round から止まっています。
理由: <oe の reason または blockers>
Issue には同内容が `oe` によってコメント済みです。再開するかは、人が `epic-retry`、`epic-redo`、`epic-drop` のどれか 1 つだけを書いたコメントで決めます。ループが自分で決めることはありません。
```

## Completion

`oe round complete` が完了を投稿したとき。本文は `oe` が書いたものをそのまま出す。

```
## Epic #<EPIC> 完了

oe が投稿した完了コメントの内容を、そのまま表示する。
Epic 本体と完了したコンテナは close していません。close するかどうかはあなたの判断です。
```
