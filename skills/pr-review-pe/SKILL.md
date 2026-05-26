---
name: pr-review-pe
description: >
  コード差分 PR (Layer-1) 専用の Principal Engineer 視点レビュースキル。
  正確性・アーキテクチャ・スケーラビリティ・セキュリティ・API 設計・エラーハンドリング/並行/リソース・運用性の 7 観点と、Observability Gap、および AI が書いたコード特有のリスク (ハルシネーション依存パッケージ、テスト確認バイアス、並行安全性欠如、ハッピーパス偏重) を検査する。
  「コードレビューして」「差分レビュー」「PE 視点でレビュー」「PR を見て」などの依頼で使う。
  引数に PR 番号または GitHub URL を渡す。
  Markdown のみの PR は /pr-doc-review-pe を使うこと。
context: fork
allowed-tools: Read, Glob, Grep, Bash(pr-review-pe-identify-pr.sh:*, gh pr diff:*, git log:*, git blame:*, git grep:*, rg:*, npm:*, go:*, pip:*, echo:*), WebFetch, Agent
argument-hint: "<pr-number or url>"
---

# pr-review-pe

コード差分 PR を 4 phase (Brainstorm → Self-Refine → Filter → Meta-Review) でレビューする orchestrator。
本スキルは Layer-1 (コード差分) に専念する。

## Step 1: PR 特定とメタ取得

決定論的なパースとメタ取得は `bin/pr-review-pe-identify-pr.sh` に集約する。
`$ARGUMENTS` を渡すと、PR 番号・GitHub URL・未指定の 3 分岐を解決して `gh pr view` のメタ JSON を返す。

```bash
pr-review-pe-identify-pr.sh "$ARGUMENTS"
```

exit code 2 (PR 特定不能) は「現在のブランチに PR が見つかりません。PR 番号または URL を引数で指定してください (例: `9` / `https://github.com/org/repo/pull/9`)。」で停止する。
exit code 3 (gh 一時障害) も同様に停止し、ユーザーに手動指定を促す。
返却 JSON の `number` フィールドを以降のステップで `$PR_NUMBER` として使う。

## Step 2: データ収集

並列で次の補助情報を取得する。

1. PR 差分 (ハルシネーション防止の基盤): `gh pr diff $PR_NUMBER`。
2. コミット履歴 (PR description との整合確認): `git log --oneline -n 20 origin/$BASE..$HEAD`。
3. 変更行の歴史 (必要時のみ): `git blame -L <range> <file>`。

diff から記録する: 追加依存パッケージ、新規テストファイル、言語・フレームワーク、変更された公開面 (関数・型・API・CLI・設定キー)。

文脈を補完する: 変更シンボルの呼び出し元を `rg` または `git grep` で探し、ループ・外部 I/O・上限欠如を確認する。
関連 ADR・RFC・設計メモを `docs/` `adr/` `CLAUDE.md` 配下から `Read` し、同責務の既存 helper を 2〜3 件 `Read` で照合する。

## Step 3: Brainstorm via Agent specialists

以下 5 specialist を `Agent` (subagent_type: general-purpose) で並列起動する。
各プロンプトは責務に絞り、低 confidence でも候補に含めるよう指示する。
返却は `path:line` + 引用元 + 仮重要度を必須とする。
各 specialist の冒頭で `Read skills/pr-review-pe/references/<該当>.md` を読ませてからレビューさせる。

- **correctness-reviewer**: PR description と実装の一致、ビジネスロジック、状態遷移、条件分岐、エッジケース処理。
  必須サブ質問は null/nil/空配列/0/負数/MaxInt/空文字列の全パストレースと、AI 生成テストの確認バイアス (テストと実装が同じ誤前提を共有していないか)。
  参照: `references/ai-specific-risks.md`。
- **architecture-reviewer**: 責務分離、依存方向 (循環)、不必要な抽象化、Over-engineering、冗長性 (保守コスト・仕様同期リスクで説明可能な場合のみ) を、判断境界を明示して指摘する。
- **scalability-reviewer**: N+1、同期ブロッキング、キャッシュ設計、上限・ページング欠如、呼び出し元込みの計算量。
  必須サブ質問は 1000 倍データ時に OOM・タイムアウトを引き起こすパスの特定で、単体 O(n) → 呼び出し元で m 回実行されるため O(mn) のように増幅点を書く。
- **security-reviewer**: 入力検証、認証認可、シークレット扱い、SQLi・コマンドインジェクション・XSS・パストラバーサル・SSRF。
  必須サブ質問は最大長文字列・制御文字・SQL 特殊文字・パストラバーサル文字を入力した場合の挙動。
  AI 特有として、追加依存パッケージは `npm view` / `pip` (PyPI は WebFetch で必ず確認) / `go list -m` で存在確認し、非推奨・CVE 対象 API を確認する。
  参照: `references/ai-specific-risks.md`。
- **operational-reviewer**: エラーハンドリング、並行安全性 (check-then-act・スレッドセーフでないコレクション・グローバル状態・デッドロック)、リソース管理 (defer / finally / using・ゴルーチンリーク)、ログ・メトリクス・トレース・アラート、デプロイ影響、マイグレーション後方互換、設定外部化。
  必須サブ質問は Observability Gap として「この変更が本番で壊れたとき既存の logs / metrics / traces で root cause まで到達できるか」を問い、到達できなければ欠如している telemetry を `[must]` または `[imo]` で指摘する。
  並行アクセスとネットワーク切断時の防御も必須検査。
  参照: `references/observability-gap.md`。

specialist 共通注記: 既存コメント・PR description で対処済みの指摘は出さない。
指摘ごとに { diff hunk, 関連既存コード, 関連 ADR・RFC, CLAUDE.md・プロジェクト規約, 関連過去 PR } の少なくとも 1 件を引用元として記録する。

## Step 4: Self-Refine

specialist 返却を 1 件ずつ surface / mid / deep に分類する。

- **surface**: typo、命名スタイル、局所重複、段落体裁。
- **mid**: 観点単位のリスク (個別 null 漏れ、個別 error 握りつぶし、個別 N+1)。
- **deep**: 設計層 (責務漏れ、依存方向逆転、Observability Gap、リリース順依存、並行安全性、API 契約破壊)。

deep 候補が 0〜2 件しかない specialist は「go deeper: design-layer の漏れを 2 件追加で出す」プロンプトで再起動する。

## Step 5: Filter

各候補を 4 軸 (actionable / specific / verifiable / non-redundant) で評価し、Confidence と Severity を割り当てる。

- **Confidence**: High (2 source 以上で裏付け) / Medium (1 source) / Low (弱い裏付け)。
- **Severity**: `[must]` (本番影響・API 互換性破壊・セキュリティ・仕様乖離) / `[imo]` (改善望ましいが任意) / `[ask]` (設計意図確認) / `[good]` (優れた設計判断) / `[next]` (今回スコープ外)。
  `[nits]` は原則使わない。

旧 3 anti-pattern を以下で置換する。

1. 既存パターン一致でも指摘を廃棄しない: Confidence-Low に分類したうえで、`references/existing-pattern-matching.md` の risk-exception passthrough リスト (セキュリティ・データ整合性・API 契約・runtime crash・計算可能なスケーラビリティ後退) のいずれかに該当する場合は通常 Confidence・Severity で出力する。
2. PR description の設計意図と矛盾する指摘も廃棄しない: 3 つの reverse-generated alternative intents (各 1 文) を内部生成し、PR description が選択意図をいずれの代替に対しても正当化できていない場合は `[ask]` でその正当化を求める (出力に代替は列挙しない)。
3. 引用は diff hunk に限らない: { diff hunk / 関連既存コード / 関連 ADR・RFC / CLAUDE.md・プロジェクト規約 / 関連過去 PR } のうち少なくとも 1 件を引用元として持てば候補に残す。

Confidence-Low かつ risk-exception に該当しない候補は除外し、除外件数と理由を False-Negative log として内部集計する。

## Step 6: Meta-Review

最終出力前に各指摘を再読し、次を訂正または除外する: 曖昧表現、誤読される可能性のある表現、professional でない口調、引用元と本文の対応漏れ、severity と本文の影響規模の不整合。

## Step 7: 出力フォーマット

```
## PR #NNN レビュー: <タイトル>

### 総評
（3〜4 文。Layer-1 観点での全体印象・正確性評価・最重要懸念・AI 特有リスクの評価）

### Observability Gap
本番障害時に root cause に到達できるかの判定と、欠如している telemetry の指摘。
欠如なしの場合は「N/A: 確認済み — <確認した logs / metrics / traces の根拠>」と書く。

### 指摘事項

**[must] `path/to/file:42`**: 問題の説明
> `diff hunk または関連既存コード・ADR・CLAUDE.md からの引用`
→ 改善案: 具体的なコードまたは手順

（[imo] は影響と改善案、[ask] は確認事項を同形式で記載する。reverse-generated 代替への正当化要求は [ask] 内で行う）

### 良い点
- [good] `path/to/file:15`: 評価できる設計判断 (引用不要)

### 自己検証結果
Brainstorm N → Self-Refine M → Filter K → Meta-Review L 件
除外: X 件 (うち Confidence-Low 廃棄: Y、risk-exception 経由復活: Z)
```

指摘事項がない場合は `### 指摘事項` 内に「指摘事項なし。Approve 推奨。」と書く (見出しは省略しない)。
`[good]` は `### 良い点` セクション専用。`### 良い点` は指摘事項なしでも出力してよい。
