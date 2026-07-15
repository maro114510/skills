# Output Templates (Japanese)

すべてのユーザー向け出力はこのファイルの形式に従う。絵文字は使わず、`[!]` などのテキスト記号を使う。

## Round Plan（Step 3）

```
## Round Plan — Epic #<EPIC> <Epicタイトル>

| Issue | タイトル | 状態 | 依存 | 今回 |
|-------|---------|------|------|------|
| #12 | ... | done | - | - |
| #13 | ... | awaiting-merge | #12 | - |
| #14 | ... | ready | #12 | 実行 |
| #15 | ... | in-progress (再開) | - | 実行 |
| #16 | ... | waiting | #13 | - |

今回のディスパッチ: <N> 件（max-parallel: <M>）
コスト目安: Sonnet worker x<N> + Opus reviewer x<N>（修正サイクルで増える可能性あり）

[!] worker はコミットしません。commit / push / PR 作成は wave 完了時の承認後に一括実行します。
```

状態の凡例が必要な場合のみ 1 行で添える。`[!]` 行は毎回必ず出す。

## Blocked Questions（Step 5）

AskUserQuestion の question 文には必ず Issue 番号と「worker が実装を止めて確認している」ことを含める。

```
#<N> の worker が実装前に確認を求めています: <質問内容>
```

選択肢は worker の QUESTIONS に示された具体案をそのまま使い、勝手に案を追加しない。

## Wave Gate（Step 7）

```
## Wave Gate — レビュー結果

### #14 <タイトル>
- branch: feat/issue-14 / worktree: <path>
- 変更: <ファイル数> files（主要: ...）
- テスト: <結果要約>
- reviewer: APPROVE（nit <n> 件: <一行要約>）

### #15 <タイトル>
- ...
- reviewer: REQUEST_CHANGES 未解消（blocking <n> 件）→ 詳細を下に記載

[!] ファイル重複: feat/issue-14 と feat/issue-15 が `src/foo.ts` を変更しています。
    推奨マージ順: #14 → #15（後者はマージ後 rebase が必要になる見込み）

difit で順に確認しますか？（コメントを付けると worker に差し戻して修正します）
```

未解消の blocking findings がある Issue は、finding の全文を file:line と障害シナリオ付きで必ず展開して見せる。

## Wave Approval（Step 7 の承認質問）

AskUserQuestion で行う。question 文の要旨:

```
この wave の commit / push / PR 作成を一括で実行してよいですか？
対象: #14 (feat/issue-14), #15 (feat/issue-15)
実行内容: 各 worktree で commit → push → PR 作成（Closes #N 付き）
```

選択肢は「一括承認」「一部のみ承認」「中断」の 3 つ。「一部のみ承認」を選んだ場合は対象 Issue を続けて確認する。「中断」を選んだ場合は commit も push も PR 作成も行わない。

## Ship Report（Step 8）

```
## Ship 完了

| Issue | PR | 状態 |
|-------|----|------|
| #14 | <PR URL> | 作成済み |
| #15 | <PR URL> | 作成済み |
| #16 | - | [!] push 失敗（詳細: ...） |
```

## Wave Boundary（Step 9）

```
## 次の wave はマージ待ちです

マージ待ち PR: <PR URL 一覧>
これらの Issue が close されると解放されるタスク: #17, #18

続け方:
- いま続ける: 上記 PR をマージしてから「続けて」と言ってください。状態を再取得して次の round を計画します。
- あとで続ける: このまま終了して構いません。`/orchestrate-epic epic <EPIC>` を再実行すれば GitHub の状態から再開します。
```

## Completion Report（Step 10）

```
## Epic #<EPIC> 完了

- 実装・マージ済み: #12, #13, #14, ...（<n> 件）
- スキップ/失敗: <あれば Issue と理由、なければ「なし」>
- 後片付け: worktree <n> 件削除済み

Epic 本体を close しますか？（自動では close しません）
```

## Escalation（失敗・未解消時）

```
[!] #<N> は今回の round から除外しました。
理由: <worker の 2 回目の失敗内容 / 未解消の blocking findings>
対応の選択肢: <再試行 / 手動対応 / Issue を分割し直す 等、状況に応じて>
```
