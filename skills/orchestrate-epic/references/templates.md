# Output Templates (Japanese)

すべてのユーザー向け出力はこのファイルの形式に従う。絵文字は使わず、`[!]` などのテキスト記号を使う。GitHub コメントとして投稿するテンプレートは Markdown 全文をそのままコメント本文にする。

## Run Plan（Step 3、Epic コメント）

先頭にマーカー `<!-- orchestrate-epic:run-plan -->` を必ず付ける。同じ Epic に対して二度目以降は投稿し直さない。

```
<!-- orchestrate-epic:run-plan -->
## Run Plan — Epic #<EPIC> <Epicタイトル>

### リポジトリ事実
- branch protection: <あり/なし>（required checks: <一覧 or なし>、required reviewers: <人数 or なし>）
- 導出した CHECKS_SET（`.github/workflows/` から derive、script 名からの推測ではない）:
  - 実行可能: <command のリスト、working directory 付き。無ければ「なし」>
  - ローカル検証不可: <`${{ }}` / sudo / グローバルインストール / `uses:` アクションを理由付きで列挙。無ければ「なし」>
- [!] required checks も required reviewers も未設定です。このループの reviewer pass と CHECKS_SET の実行可能エントリが、マージ前の唯一のゲートです。   ← 該当する場合のみ

### Issue 一覧
| Issue | タイトル | 状態 | 依存 | base branch |
|-------|---------|------|------|-------------|
| #12 | ... | done | - | - |
| #13 | ... | awaiting-merge | #12 | main |
| #14 | ... | ready | #12 | main |
| #15 | ... | waiting | #13 | main |

状態はブランチ・PR・このループのコメントから判定しています。ラベルは読み取りも付与もしません。

### Bounds
- max-parallel: <M>
- fix-cycle cap: 2（Issue あたり。reviewer 指摘を受けた worker 再 dispatch と再 review は blocking 修正・nit のみの修正を問わず 1 cycle として数えるため、nit のみの修正も同じ上限で止まります）
- 今回のワースト想定（予測ではなく上限）: <N 件 Issue> × 最大 5 回試行（初回 + 回答済みBLOCKEDの再送1回 + FAILED再試行1回 + reviewer修正2回 = blocking/nit いずれも1 cycle、を積み上げた最悪ケース）× 最大 4 回 reviewer 実行（初回 + fix cycle 2 回 + default branch 前進・HEAD 移動による staleness 再検証 1 回。FAILED再試行時は reviewer を呼ばない。cap 到達後は残指摘のまま park し、それ以上は dispatch しません。同じ round で再び stale になった Issue は再検証せず次回実行に回します）
- Epic 全体の予算（セッションや再実行をまたいで累積。N = 未完了 Issue <N> 件）: worker dispatch <5N> 回、reviewer 実行 <4N> 回（他の PR のマージなどで承認が古くなった際の staleness 再検証は数えません）、fix cycle <2N> 回。Epic のコメントに記録し、spawn の前に毎回差し引きます。超える操作をしようとした時点で Epic を凍結し、`epic-release` が投稿されるまで dispatch・review・PR 作成・マージをすべて止めます。`epic-retry` で Issue 単位の cycle を戻しても、この予算は戻りません
- [!] 予算は spawn の回数だけを数えます。wall-clock やトークン消費量による自動停止はありません
- PR の修復（CI 失敗・レビュー指摘・conflict）は fix cycle として数え、上記の fix-cycle cap と Epic 全体の予算に含めます。修復専用の上限は設けません
- CI 待ちのポーリング: 1 回の実行につき 60 秒間隔で最大 30 回（マージのたびに数え直し）。チェックが 1 件も報告されない PR は push から 5 回で打ち切り、人の対応待ちにします。使い切ったら待ち中の PR は次回の実行に回します

### 次のアクション
このプランに問題がなければ、この Epic に `epic-approve` とだけ書いたコメントを投稿してください。この Run Plan より後に、OWNER・MEMBER・COLLABORATOR が投稿したものだけが承認になります。投稿されるまで dispatch は行われません。
`epic-approve` を文中に含めただけのコメント（例: 「確認したら epic-approve します」）は承認になりません。補足や条件は別のコメントに書いてください。ラベルは承認として読み取りません。
承認した後は、通常どおり実行しても問題があれば Issue や Epic へのコメントで介入できます — 以後このループが対話で確認を求めることはありません。

### マージ権限
`epic-approve` が許可するのは実装と PR 作成までです。PR の自動マージは許可しません。
ループに自動マージも任せる場合は、この Run Plan より後に `epic-auto-merge` とだけ書いたコメントを別に投稿してください。取り消すときは `epic-revoke-auto-merge` とだけ書いたコメントを投稿します。両者のうち最も新しいコメントが有効で、ループはマージの直前に毎回読み直します。取り消した後に始まるマージは行いません。
自動マージを許可しても、必須レビュー・ruleset・人の確認を求めるリポジトリ側の制御は迂回しません。
マージは 1 件ずつ、レビュー済みの HEAD を expected SHA として指定して行います。GitHub の auto-merge は使いません。
CI 失敗・レビュー指摘・conflict の修復は `epic-approve` だけで行います。マージ権限が無い場合も PR を修復し、マージはあなたに任せます。
```

## Blocked Question（Step 5、Issue コメント）

```
orchestrate-epic: worker が実装を止めて確認を求めています。

Q1: <workerのQUESTIONS 1つ目>
選択肢: <workerが示した具体案をそのまま列挙>

Q2: <あれば>
...

回答はこの Issue へのコメントとして自由に書いてください。次回このループを実行すると worker が読み取ります。
この Issue は parked ではないため、`epic-retry` / `epic-redo` / `epic-drop` は不要です。これらのコマンドは、parked または rejected になった Issue の判断にだけ使います。
```

回答済みの問いを次回コメントするときは、既存の Q&A 形式（commands §2）に従う。

## Ship-class Question（Step 5–7、Issue コメント）

worker の BLOCKED 質問（Step 5）、reviewer の指摘（Step 6）、secret screen（Step 7）のどこで発生しても、この形式を使う。

suspected secret、change-size split、scope dispute（どの Issue でも）は、ループ自身が決めてはいけない ship-class の問いです。回答が来るまで Issue は parked のままにし、時間経過・無回答を承認として扱いません。

```
orchestrate-epic: ship-class の判断が必要なため、この Issue を保留しました。

種類: <suspected secret / change-size split / scope dispute>
内容: <何を判断する必要があるか>
選択肢: <考えられる選択肢をそのまま列挙>

この問いはループ自身では決めません。回答が無い限り再開しません。
判断は、次のコマンドのどれか 1 つだけを書いたコメントとして投稿してください。OWNER・MEMBER・COLLABORATOR のコメントだけを読み取ります。
- `epic-retry` — 同じ worktree で修正を続ける
- `epic-redo` — 新しいブランチでやり直す
- `epic-drop` — 出荷しない
コマンドを文中に含めただけのコメント（例: 「まだ epic-retry しないで」）は判断として読み取られず、Issue は parked のままになります。理由や修正方針は、コマンドより先に別のコメントとして書いてください。コマンドを読み取った時点までに投稿されたコメントだけを、`epic-retry` / `epic-redo` のときに worker へ渡します。
```

scope dispute に例外はありません。どの Issue でも park し、ループが解釈を選ぶことはありません。

## Freeze Comment（Step 3–7、Epic コメント）

先頭にマーカー `<!-- orchestrate-epic:freeze -->` を必ず付ける。凍結 1 回につき 1 度だけ投稿し、凍結中は再投稿しない。`- reason:` 行と各カウンタ行は 1 行のまま書く。ループが再実行時に読み戻すため。

```
<!-- orchestrate-epic:freeze -->
orchestrate-epic: この Epic を凍結しました。解除されるまで、worker の dispatch、review、PR 作成、マージを一切行いません。

- reason: <freeze check の reason= の値。例: fix_cycles 8 + 1 > 8>
- worker_dispatches: <used> / <bound>
- reviewer_passes: <used> / <bound>
- fix_cycles: <used> / <bound>

再実行やセッションの再起動では解除されません。
理由を確認して続けてよければ、この Epic に `epic-release` とだけ書いたコメントを投稿してください。このコメントより後に OWNER・MEMBER・COLLABORATOR が投稿したものだけを読み取ります。コマンドを文中に含めただけのコメント（例: 「確認したら epic-release します」）は解除になりません。
解除後の実行は、GitHub から状態をすべて読み直してから動きます。予算の使用量は 0 に戻り、上限は残りの Issue 数から計算し直します。parked の Issue、無効になった承認、マージ権限は解除によって変わりません。
```

## Frozen Epic（Step 3–7、本文出力）

```
[!] Epic #<EPIC> は凍結中のため、今回は何も実行しません。
理由: <freeze comment の reason>
凍結コメント: <freeze comment の URL または id>
予算: worker dispatch <used>/<bound>、reviewer 実行 <used>/<bound>、fix cycle <used>/<bound>
再開するには、Epic に `epic-release` とだけ書いたコメントを投稿してから再実行してください。Epic への通知は凍結時の 1 回だけで、このメッセージは GitHub には投稿しません。
```

## Ship Report（Step 7）

```
## Ship 完了

| Issue | PR | 状態 |
|-------|----|------|
| #14 | <PR URL> | 作成済み |
| #15 | <PR URL> | 作成済み |
| #16 | - | [!] push 失敗（詳細: ...） |
```

## Merge Hold（Step 8、Issue コメント）

`next=human` として扱うとき（pr-readiness.sh の `next=human`、信頼できない作成者の未解決レビュー、前回の修復以降に新しい指摘が無い、マージ要求の拒否）、PR の HEAD と理由の組ごとに 1 度だけ投稿する。先頭にマーカー `<!-- orchestrate-epic:merge-hold <PR> <HEAD> <理由の cksum> -->` を付ける（commands §3.6 が付ける）。

```
orchestrate-epic: PR #<PR> は、ループでは解消できない理由があるためマージを保留しています。人の対応をお願いします。

HEAD: <HEAD>
理由: <pr-readiness.sh の reason= の値 / 信頼できない作成者の未解決レビュー / 前回の修復以降に新しい指摘が無く、レビュアーまたは CI の反応待ち / マージ要求の拒否: GitHub のメッセージ>

ループはリポジトリ側の制御を迂回しません（`--admin` もリポジトリ設定の変更も行いません）。対応が済むと、次の landing pass か次回の実行で改めて判定します。
```

## Merge Result（Step 8、Issue コメント）

マージを試みるたびに投稿する。先頭にマーカー `<!-- orchestrate-epic:merge-result <PR> <reviewed_sha> <result> -->` を付ける（commands §3.6 が付ける）。この記録が書けるまで、次の PR はマージしない。

```
orchestrate-epic: PR #<PR> のマージ結果: <merged / head-moved / rejected / unknown>

- expected SHA (reviewed_sha): <reviewed_sha>
- verified_base: <verified_base>
- 方式: <merge / squash>
- 詳細: <merged ならマージコミットの SHA、それ以外は GitHub のメッセージ>
```

結果ごとの意味（コメントには該当する 1 行だけを書き足す）:
- merged: マージされました。
- head-moved: レビュー後に HEAD が変わったため GitHub がマージを拒否しました。再検証してからやり直します。
- rejected: リポジトリがマージを拒否しました。理由を確認してください。
- unknown: マージ要求の応答を受け取れず、マージされたかも確認できませんでした。この実行ではこれ以上マージしません。

## Round Boundary（Step 9）

```
## 次の round はマージ待ちです

今回マージした PR: <PR URL 一覧、なければ なし>
マージ待ち PR:
| PR | 理由 |
|----|------|
| <PR URL> | <マージ権限なし / リポジトリ側で人の確認待ち: <reason> / CI 待ちのポーリング上限 / 再検証待ち> |
これらの Issue が close されると解放されるタスク: #17, #18

続け方:
- いま続ける: マージ権限が無い場合は、上記 PR を 1 件だけマージしてから `/orchestrate-epic epic <EPIC>` を再実行してください。残りの PR は新しい default branch で再検証します。人の確認待ちの PR は、その確認が済んでから再実行してください。
- あとで続ける: このまま終了して構いません。再実行すれば GitHub の状態から再開します。

並列数上限で今回見送った ready Issue がある場合は、次の行を必ず添える:
「#19, #20 は並列数上限で見送っただけなので、マージを待たずに再実行すれば次のバッチを開始できます。」
```

## Completion Exit Comment（Step 10、Epic コメント）

先頭にマーカー `<!-- orchestrate-epic:completion -->` を必ず付ける。既に投稿済みなら再投稿しない。

```
<!-- orchestrate-epic:completion -->
## Epic #<EPIC> 完了

### 実装・マージ済み
#12, #13, #14, ...（<n> 件）

### 記録された前提・仮定
<各 Issue の Q&A コメント、worker report の SKIPPED と SUMMARY の decision log から集約、なければ「なし」>

### 保留・失敗した Issue
| Issue | 理由 |
|-------|------|
| #16 | <2回目の失敗内容 / 未解消の blocking findings / secret screen ヒット 等> |

### メトリクス（#141）
1. ループが実行しなかったチェックに起因する CI 失敗: <件数。CHECKS_SET の requires-runner エントリに起因する失敗は除く>
2. reviewer 初回 APPROVE 率: <n/m>
3. fix-cycle cap 到達件数: <n 件>
4. worker dispatch 数（計画時想定 vs 実績）: <計画 vs 実績>
5. orphan になった Issue 数: <n 件>
6. shipped PR あたりの wall clock: <目安>

Epic 本体は close していません。close するかどうかはあなたの判断です。
```

## Escalation（本文出力、失敗・保留時）

```
[!] #<N> は今回の round から除外しました。
理由: <worker の2回目の失敗内容 / 未解消の blocking findings / secret screen ヒット 等>
Issue には同内容をコメント済みです。BLOCKED の再送はこのまま次回も自動で試みますが、fix-cycle cap 到達 / secret screen ヒットで parked になった Issue は、`epic-retry` / `epic-redo` / `epic-drop` のどれか 1 つだけを書いたコメントがこの Issue に投稿されない限り再開しません。理由や修正方針は、コマンドより先に別のコメントとして書いてください。
```
