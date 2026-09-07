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
| Issue | タイトル | 状態 | risk | 依存 | base branch |
|-------|---------|------|------|------|-------------|
| #12 | ... | done | - | - | - |
| #13 | ... | awaiting-merge | risk:low | #12 | main |
| #14 | ... | ready | risk:high | #12 | main |
| #15 | ... | waiting | risk:low（未設定→risk:high 扱い） | #13 | main |

risk ラベルが無い Issue は risk:high 扱いです（表示のみで、実行順や出荷可否は変えません）。

### Bounds
- max-parallel: <M>
- fix-cycle cap: 2（Issue あたり）
- 今回のワースト想定（予測ではなく上限）: <N 件 Issue> × 最大 5 回試行（初回 + 回答済みBLOCKEDの再送1回 + FAILED再試行1回 + reviewer修正2回、を積み上げた最悪ケース）× 最大 3 回 reviewer 実行（FAILED再試行時は reviewer を呼ばない）
- [!] wall-clock / 予算による自動停止はまだありません（#171 未実装）

### 次のアクション
このプランに問題がなければ、Epic に `oe:go` ラベルを追加してください。追加されるまで dispatch は行われません。
ラベルを追加した後は、通常どおり実行しても問題があれば Issue や Epic へのコメントで介入できます — 以後このループが対話で確認を求めることはありません。
```

## Blocked Question（Step 5、Issue コメント）

```
orchestrate-epic: worker が実装を止めて確認を求めています。

Q1: <workerのQUESTIONS 1つ目>
選択肢: <workerが示した具体案をそのまま列挙>

Q2: <あれば>
...

回答はこの Issue へのコメントとして残してください。次回このループを実行すると worker が読み取ります。
```

回答済みの問いを次回コメントするときは、既存の Q&A 形式（commands §2）に従う。

## Ship Report（Step 7）

```
## Ship 完了

| Issue | PR | 状態 |
|-------|----|------|
| #14 | <PR URL> | 作成済み |
| #15 | <PR URL> | 作成済み |
| #16 | - | [!] push 失敗（詳細: ...） |
```

## Round Boundary（Step 8）

```
## 次の round はマージ待ちです

マージ待ち PR: <PR URL 一覧>
これらの Issue が close されると解放されるタスク: #17, #18

続け方:
- いま続ける: 上記 PR をマージしてから `/orchestrate-epic epic <EPIC>` を再実行してください。状態を再取得して次の round を計画します。
- あとで続ける: このまま終了して構いません。再実行すれば GitHub の状態から再開します。

並列数上限で今回見送った ready Issue がある場合は、次の行を必ず添える:
「#19, #20 は並列数上限で見送っただけなので、マージを待たずに再実行すれば次のバッチを開始できます。」
```

## Completion Exit Comment（Step 9、Epic コメント）

先頭にマーカー `<!-- orchestrate-epic:completion -->` を必ず付ける。既に投稿済みなら再投稿しない。

```
<!-- orchestrate-epic:completion -->
## Epic #<EPIC> 完了

### 実装・マージ済み
#12, #13, #14, ...（<n> 件）

### 記録された前提・仮定
<各 Issue の Q&A コメントおよび worker report の SKIPPED から集約、なければ「なし」>

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
Issue には同内容をコメント済みです。BLOCKED の再送はこのまま次回も自動で試みますが、fix-cycle cap 到達 / secret screen ヒットで parked になった Issue は、この Issue に対応方針をコメントしない限り再開しません。
```
