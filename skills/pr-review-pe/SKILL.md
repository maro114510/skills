---
name: pr-review-pe
description: >
  コード差分 PR (Layer-1) 専用の Principal Engineer 視点レビュースキル。
  正確性・アーキテクチャ・スケーラビリティ・セキュリティ・API 設計・エラーハンドリング/並行/リソース・運用性の 7 観点と、Mandatory Pillars (既存コード整合・リリース/ロールバック・Observability)、および AI が書いたコード特有のリスク (ハルシネーション依存パッケージ、テスト確認バイアス、並行安全性欠如、ハッピーパス偏重) を検査する。
  「コードレビューして」「差分レビュー」「PE 視点でレビュー」「PR を見て」などの依頼で使う。
  引数に PR 番号または GitHub URL を渡す。
  Markdown のみの PR は /pr-doc-review-pe を使うこと。
allowed-tools: Read, Glob, Grep, Bash(pr-review-pe-identify-pr.sh:*, gh pr view:*, gh pr diff:*, gh api:*, git fetch:*, git -C:*, git log:*, git blame:*, git grep:*, ghq list:*, rg:*, npm:*, go:*, pip:*, echo:*), WebFetch, Agent
argument-hint: "<pr-number or url>"
---

# pr-review-pe

コード差分 PR を 4 phase (Brainstorm → Self-Refine → Filter → Meta-Review) でレビューする orchestrator。
本スキルは Layer-1 (コード差分) に専念する。

## Step 1: PR 特定とメタ取得

決定論的なパースとメタ取得は `bin/pr-review-pe-identify-pr.sh` に集約する。
`$ARGUMENTS` を渡すと、PR 番号・GitHub URL・未指定の 3 分岐を解決して `gh pr view` のメタ JSON を返す。

```bash
# このスクリプトは PATH に含まれている。スクリプト名のみで呼び出すこと。
# `bash <path>` 形式や推測パス（.claude/skills/.../bin/ など）は絶対に使わない。
pr-review-pe-identify-pr.sh "$ARGUMENTS"
```

exit code 2 (PR 特定不能) は「現在のブランチに PR が見つかりません。PR 番号または URL を引数で指定してください (例: `9` / `https://github.com/org/repo/pull/9`)。」で停止する。
exit code 3 (gh 一時障害) も同様に停止し、ユーザーに手動指定を促す。
返却 JSON の `number` フィールドを `$PR_NUMBER`、`headRefName` を `$HEAD`、`baseRefName` を `$BASE` として記録する。
また URL から `<org>/<repo>` 形式の `$REPO_SLUG` を抽出する。

**ローカルリポジトリ検出**: このスキルは PR と無関係なリポジトリで実行されることが多い。
`ghq` の慣習に従い対応するローカルパスを探索して `$LOCAL_REPO_PATH` に記録する。
未検出の場合は `$LOCAL_REPO_PATH=""` とし、以降の git コマンドは `gh` API に差し替える。

```bash
ghq list --full-path 2>/dev/null | grep -F "/$REPO_SLUG$" | head -1
```

**絶対遵守**: `$LOCAL_REPO_PATH` が確定するまでカレントディレクトリを起点にしたファイル読み込みや
git コマンド（`git log`・`git blame`・`Read <相対パス>`・`rg`・`git grep` 等）を実行してはならない。

## Step 2: データ収集

並列で次の補助情報を取得する。

1. PR 差分 (ハルシネーション防止の基盤): `gh pr diff $PR_NUMBER --repo $REPO_SLUG`。
2. コミット履歴 (PR description との整合確認): まず `gh pr view $PR_NUMBER --repo $REPO_SLUG --json commits`
   を使う（どのディレクトリからでも動作するため必ずこれを優先する）。
   `$LOCAL_REPO_PATH` が存在する場合は追加で以下を実行してもよい（ブランチが未 fetch の場合は先に fetch する）:
   ```bash
   git -C "$LOCAL_REPO_PATH" fetch origin "$HEAD" 2>/dev/null
   git -C "$LOCAL_REPO_PATH" log --oneline -n 20 "origin/$BASE".."origin/$HEAD"
   ```
3. 変更行の歴史 (必要時・`$LOCAL_REPO_PATH` 存在時のみ):
   `git -C "$LOCAL_REPO_PATH" blame -L <range> <file>`。

diff から記録する: 追加依存パッケージ、新規テストファイル、言語・フレームワーク、変更された公開面 (関数・型・API・CLI・設定キー)。

文脈を補完する:
- 呼び出し元の探索: `rg <pattern> "$LOCAL_REPO_PATH"` または `git -C "$LOCAL_REPO_PATH" grep`。
  `$LOCAL_REPO_PATH` が空の場合はスキップする。
- ファイル読み込み: 必ず `Read "$LOCAL_REPO_PATH/<相対パス>"` で絶対パスを使う。
  `$LOCAL_REPO_PATH` が空の場合は `gh api "repos/$REPO_SLUG/contents/<path>?ref=$HEAD" --jq '.content' | base64 -d` で取得する。
- 関連 ADR・RFC・設計メモ・CLAUDE.md: `"$LOCAL_REPO_PATH/docs/"` `"$LOCAL_REPO_PATH/adr/"` `"$LOCAL_REPO_PATH/CLAUDE.md"` 配下から `Read`。
- 同責務の既存 helper を 2〜3 件 `Read "$LOCAL_REPO_PATH/..."` で照合する。

## Step 3: Brainstorm via Agent specialists

以下 5 specialist を `Agent` (subagent_type: general-purpose) で並列起動する。
各プロンプトは責務に絞り、低 confidence でも候補に含めるよう指示する。
返却は `path:line` + 引用元 + 仮重要度を必須とする。
各 specialist の冒頭で `Read ~/.claude/skills/pr-review-pe/references/<該当>.md` を読ませてからレビューさせる
（インストール済みパスを使う。`skills/pr-review-pe/references/` のようなカレントディレクトリ相対パスは使わない）。

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

## Step 5: Mandatory Pillars 確認

Filter の前に、以下 3 Pillar を specialist 候補から確認する。
各 Pillar について候補がゼロの場合は、担当 specialist を「force-investigate this pillar: <pillar name>」プロンプトで再起動する。
再起動後も発見なければ `N/A: scope confirmed — <確認した具体的根拠 (ファイルパス・ADR ID・メトリクス名) を 20 語以上で記録>` とする。

1. **Existing-code alignment**: ADR・CLAUDE.md・既存実装パターン・ユビキタス言語との整合。担当: architecture-reviewer。
2. **Release / Rollback / Compat.**: マルチ PR 順序・フィーチャーフラグ・ロールバック経路・データ移行順。担当: operational-reviewer。
3. **Observability**: 本番で壊れたとき root cause に到達できる metrics / logs / alerts / traces の充足。担当: operational-reviewer。

Pillar 発見には `[pillar]` マーカーを指摘事項の severity に並記する (`**[must][pillar]**` 形式)。Pillar 発見は Confidence-Low でも Filter で除外しない。同一 Pillar に属する複数発見で修正アクションが同一の改善提案にまとめられる場合は 1 件にまとめること。
Mandatory Pillars テーブルと指摘事項の双方に記録する (テーブル: 発見要約、指摘事項: `[must][pillar]` 詳細)。

## Step 6: Filter

各候補を 4 軸 (actionable / specific / verifiable / non-redundant) で評価し、Confidence と Severity を割り当てる。

- **Confidence**: High (2 source 以上で裏付け) / Medium (1 source) / Low (弱い裏付け)。
- **Severity**: `[must]` (本番影響・API 互換性破壊・セキュリティ・仕様乖離) / `[imo]` (改善望ましいが任意) / `[ask]` (設計意図確認) / `[good]` (優れた設計判断) / `[next]` (今回スコープ外)。
  `[nits]` は原則使わない。

旧 3 anti-pattern を以下で置換する。

1. 既存パターン一致でも指摘を廃棄しない: Confidence-Low に分類したうえで、`references/existing-pattern-matching.md` の risk-exception passthrough リスト (セキュリティ・データ整合性・API 契約・runtime crash・計算可能なスケーラビリティ後退) のいずれかに該当する場合は通常 Confidence・Severity で出力する。
2. PR description の設計意図と矛盾する指摘も廃棄しない: 3 つの reverse-generated alternative intents (各 1 文) を内部生成し、PR description が選択意図をいずれの代替に対しても正当化できていない場合は `[ask]` でその正当化を求める (出力に代替は列挙しない)。
3. 引用は diff hunk に限らない: { diff hunk / 関連既存コード / 関連 ADR・RFC / CLAUDE.md・プロジェクト規約 / 関連過去 PR } のうち少なくとも 1 件を引用元として持てば候補に残す。

Confidence-Low かつ risk-exception に該当せず Pillar でない候補は除外し、除外件数と理由を False-Negative log として記録する。
**deep** に分類された候補が除外される場合は、specialist 名・指摘概要（10 語以内）・除外理由を個別に記録し、最終出力の FN log に含める。

### Quality Gates (R-1〜R-3)

上記 Filter の通過候補に対して、さらに以下の 3 gate を順に適用する。

**R-1: Typo Quota** — surface 候補（typo・命名スタイル・段落体裁）は最大 3 件に制限する。
4 件目以降の surface 候補は出力に含めず FN log に記録する（除外理由: `surface quota 超過`）。
制限で空いた枠は mid/deep 指摘で埋めることを優先する。

**R-2: Why-Chain-3** — mid/deep 候補ごとに次の 3 ステップ推論チェーンを内部で構築する。
1. **Problem**: 何が問題か（diff またはコードベースで確認した事実）
2. **Root Cause**: なぜそれが起きているか（設計判断・実装上の欠落）
3. **Why it matters**: 本番影響・保守コスト・セキュリティリスク等の具体的な結果

**チェーンの完成基準**: 各ステップは当該指摘に固有の tool 呼び出し結果（Read・Grep・Bash 出力）・diff hunk・またはコードベース引用に紐付けられていなければならない。一般的知識のみで補完されたステップは「根拠なし（evidence-free）」とみなし、そのステップを「不完全」として扱う。

チェーンを 3 ステップ完成させられない候補は FN log に除外する（除外理由: `Why-Chain-3 failure: <不足または evidence-free のステップ名>`）。
ただし Mandatory Pillar または risk-exception（セキュリティ・データ整合性・API 契約・runtime crash・計算可能なスケーラビリティ後退）に該当する候補はチェーン不完全でも通過させる。
チェーンの内容は内部処理として保持し、最終出力には露出しない。

**R-3: CRITIC Tool Reference** — mid/deep 候補ごとに per-finding で 2 件以上のツール呼び出しが裏付けとして必要。
カウント対象: Step 3 以降に当該指摘に固有で実行した Grep / Read / Bash / WebFetch の呼び出し。
例外: Step 2 の `git blame -L <range> <file>`（指摘のファイル・行範囲に直接対応する場合のみ 1 件としてカウント可）。
Step 2 の共有収集（`gh pr diff`・`gh pr view --json commits`）はカウント対象外とする。
裏付け件数が 1 件以下の候補は FN log に除外する（除外理由: `CRITIC: tool-evidence <実件数>/2`）。
ただし Mandatory Pillar 候補は tool-evidence 1 件でも通過させる（Pillar の完全性を優先）。

## Step 7: Meta-Review

最終出力前に各指摘を再読し、次を訂正または除外する: 曖昧表現、誤読される可能性のある表現、professional でない口調、引用元と本文の対応漏れ、severity と本文の影響規模の不整合。

## Step 8: 出力フォーマット

**メトリクス計算ルール（R-4）**:
- `T` = 全出力指摘件数（surface + mid/deep 合計）
- `D` = 出力に含まれる mid/deep 指摘件数（surface を除く）
- `A` = D のうち per-finding tool call ≥2 件を満たした件数（Pillar bypass で 1 件通過した場合は A に含めない）
- `B` = D のうち evidence 引用付きの complete chain（全 3 ステップが evidence-grounded）を持つ件数（Pillar bypass でチェーン不完全の場合は B に含めない）
- `C` = 出力に含まれる surface 指摘件数
- `D=0` の場合（surface のみ）、`tool-evidence` と `why-chain-3` は `N/A` と表示する（0 除算を行わない）

```markdown
## PR #NNN レビュー: <タイトル>

### 総評
（3〜4 文。Layer-1 観点での全体印象・正確性評価・最重要懸念・AI 特有リスクの評価）

### Mandatory Pillars

| Pillar | 発見 / N/A |
|--------|-----------|
| [pillar] Existing-code alignment | <発見または N/A: scope confirmed — ファイルパス・ADR ID・確認した根拠を 20 語以上> |
| [pillar] Release / Rollback / Compat. | <発見または N/A: scope confirmed — デプロイ手順・ロールバックパス・確認した根拠を 20 語以上> |
| [pillar] Observability | <発見または N/A: scope confirmed — logs / metrics / traces の確認根拠を 20 語以上> |

### 指摘事項

**[must] `path/to/file:42`**: 問題の説明
> `diff hunk または関連既存コード・ADR・CLAUDE.md からの引用`
→ 改善案: 具体的なコードまたは手順

（[imo] は影響と改善案、[ask] は確認事項を同形式で記載する。reverse-generated 代替への正当化要求は [ask] 内で行う）

### 良い点
- [good] `path/to/file:15`: 評価できる設計判断 (引用不要)

### 自己検証結果
Brainstorm N → Self-Refine M → Filter K → Quality Gates → Meta-Review L 件
除外: X 件 (うち Confidence-Low 廃棄: Y、risk-exception 経由復活: Z、Why-Chain-3 失敗: W、CRITIC 証拠不足: V、surface quota 超過: U)
Findings: T (tool-evidence: A/D or N/A, why-chain-3: B/D or N/A, surface: C/3 quota)
FN log — deep 除外: <specialist 名 / 指摘概要（10 語以内）/ 除外理由 を改行区切りで列挙。除外なしの場合は「なし」>
```

指摘事項がない場合は `### 指摘事項` 内に「指摘事項なし。Approve 推奨。」と書く (見出しは省略しない)。
`[good]` は `### 良い点` セクション専用。`### 良い点` は指摘事項なしでも出力してよい。
