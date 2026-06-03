---
name: pr-doc-review-pe
description: >
  ドキュメント・設計 PR (Layer-2) 専用の Principal Engineer 視点レビュースキル。
  Design Doc / ADR / RFC / 実装計画書 / AI 向け仕様書などの Markdown 中心 PR を対象に、メタ情報・設計健全性・既存コード整合・運用設計・認知負荷・暗黙の仮定・知識の呪いの 7 観点、文書内論理矛盾（責務二重定義・Policy Reversal・時系列矛盾）・WHY 欠落の自動検出・最強代替案との比較不足の指摘、AI 向け仕様固有の what/how 分離・Golden Rule・曖昧語検出を検査する。
  「Design Doc レビュー」「ADR を見て」「RFC レビュー」「実装計画書を確認して」「設計レビュー」「ドキュメント PR を見て」「プラン レビュー」「設計書のレビューをして」などの依頼で使う。
  引数に PR 番号または GitHub URL を渡す。
allowed-tools: Read, Glob, Grep, Bash(pr-review-pe-identify-pr.sh:*, pr-doc-review-textlint.sh:*, gh pr diff:*, gh pr view:*, rg:*, git grep:*, git log:*, echo:*), WebFetch, Agent
argument-hint: "<pr-number or url>"
---

# pr-doc-review-pe

ドキュメント・設計 PR を 4-phase (Brainstorm → Self-Refine → Filter → Meta-Review) で Layer-2 (7 観点) と Layer-3 (AI 仕様書条件付き) でレビューする orchestrator。

## Step 1: PR 特定とデータ収集

```bash
pr-review-pe-identify-pr.sh "$ARGUMENTS"
```

exit code 2 (PR 特定不能) または exit code 3 (gh 障害) は停止してユーザーに案内する。
返却 JSON の `number` を `$PR_NUMBER`、`baseRefName` を `$BASE`、`headRefName` を `$HEAD` として使う。

並列で取得する:

```bash
gh pr diff $PR_NUMBER                              # diff (ハルシネーション防止の基盤)
gh pr view $PR_NUMBER --json comments,reviews       # 既存コメント (重複防止)
git log --oneline -n 20 origin/$BASE..$HEAD         # コミット履歴
```

diff から記録する: 変更 .md ファイル一覧・ドキュメント種別推定 (ADR / RFC / Design Doc / 実装計画 / AI 仕様)・キーノウン (名詞・ドメイン概念語 5〜10 件)。

## Step 2: ドキュメント種別判定と AI 仕様検出

**曖昧語・弱表現の自動検出** (Step 1 で記録した .md ファイルを対象):

```bash
pr-doc-review-textlint.sh <changed-md-files>
```

結果 (検出語・ファイル名・行番号) を記録し、各 specialist への入力として提供する (語リストは `skills/pr-doc-review-pe/references/ai-instruction-spec.md` § Ambiguity Vocabulary Detection)。

**AI 仕様判定**: 次のいずれかで AI 向けと判定する。

- ファイルパスが `CLAUDE.md` / `SKILL.md` / `*prompt*.md` / `*spec*.md` を含む。
- 内容に AI 宛ての指示語 (`あなたは` / `AI は` / `モデルは` / `Claude` / `LLM`) が含まれる。
- 上記の自動検出で曖昧語 3 件以上発見。

AI 仕様と判定した場合は Step 3 で **ai-instruction-reviewer** を追加起動する。

**キーノウン git grep**:

```bash
git grep -n "<キーノウン>" -- '*.go' '*.ts' '*.py' '*.java' '*.kt' '*.rb'
```

ヒットしない語はユビキタス言語ドリフト候補、ヒット語は定義とドキュメント記述を照合する。
この手順は必ず実行し、結果をトランスクリプトに残す。Step 3 ubiquitous-language-reviewer の起動プロンプトにゼロヒット語リストと一致コード行を含める。

## Step 3: Brainstorm via Agent specialists

以下を `Agent` (subagent_type: general-purpose) で並列起動する。
各 specialist は冒頭で各行末の `参照:` ファイルをリポジトリルートからのパスで `Read` する。
低 confidence でも候補を保持し `doc-path:line` + 引用元 + 仮重要度を返す。

- **logic-coherence-reviewer**: 文書内の論理矛盾を以下の手順で検出する。(1) 「責務割り当て文」を全件抽出: 「X が Y を担う」「Z は W の責任を持つ」「状態は A が保持する」「B はステータスを更新する」形式の文。(2) 同一概念・エンティティに複数の責務割り当てがある場合、Process 矛盾（二者が同一責務を主張 / 誰も責務を負わない穴）を検出する。(3) 「前提条件文」と「制約文」の組み合わせで Policy Reversal 矛盾（「常に X」と「Y の場合は X をしない」）を検出する。(4) 「タイミング・順序文」で Temporal 矛盾を検出する。(5) Specificity 矛盾（同一エンティティ・アクションに関する 2 つのクレームが、一方がより特定的（スコープが狭い）で他方がより一般的（スコープが広い）であり、互いに両立しない処方を定めている場合）を検出する。検出ルール: 同一主語・アクションのクレームペアを識別し、一方に追加限定子（条件・スコープ・閾値・役割）が含まれ一般クレームと矛盾するものを記録する。理由欄にはどちらのクレームがより特定的か・なぜ両立しないかを明記する。発見ごとに出力: Claim A 引用 / Claim B 引用 / 矛盾種別 (Process / Policy-Reversal / Temporal / Specificity) / 両立不能な理由を 1 文で記述する。
- **rationale-reviewer**:
  Pass 1 — Why-gap 検出: (a) 意思決定文を全件抽出: 「〜を選択した」「〜は対象外とした」「〜は X に保存しない」「〜を採用する」形式の選択文。(b) 各決定文について文書内に明示的な WHY（前後 3 段落以内）が存在するか確認する。存在しない場合: MISSING_RATIONALE としてその決定文を記録し、著者への具体的な probing question を生成する。
  Pass 2 — Counterfactual 比較 (内部判断のみ・出力に代替案は含めない): Pass 1 で MISSING_RATIONALE になった決定のうち設計影響が最も大きい 1〜2 件を対象とする。Step 1 (Abduction): この決定を形成した制約・トレードオフを列挙する。Step 2 (Intervention): 著者が選ばなかった最も強力な代替案をテーブル名・カラム名・API 名まで具体的に 1 件記述する。Step 3 (Prediction): 現在の選択 vs 代替案を scalability / ops-complexity / reversibility / debuggability の 4 軸で比較し各軸で優劣を明示する。Judgment: rationale が 4 軸の比較に対して十分かを判定し、不十分なら [ask] を発行する（代替案の具体内容は出力に含めない）。
  Nygard 5 構成要素・Olaf Zimmermann 7 質問・Consequences-negative の欠如も確認する。参照: `skills/pr-doc-review-pe/references/adr-checklist.md`, `skills/pr-doc-review-pe/references/design-doc-checklist.md`。
- **operational-reviewer**: Rollout / Rollback / Multi-DC / Metrics / カスタマーサポート対応の充足。参照: `skills/pr-doc-review-pe/references/operational-design.md`。
- **readability-reviewer**: BLUF / ピラミッド原則 / ワーキングメモリ ≤ 7±2 / split-attention / メタ情報 (Audience・Non-Goals・DoD)。参照: `skills/pr-doc-review-pe/references/cognitive-load.md`, `skills/pr-doc-review-pe/references/meta-information.md`。
- **ubiquitous-language-reviewer**: Step 2 の git grep 結果を使い、コードとの概念語乖離・Bounded Context 境界超え・同概念の別名混在を検出。参照: `skills/pr-doc-review-pe/references/ubiquitous-language.md`。
- **premortem-reviewer**: プリモーテム失敗シナリオ 3 件・5-Whys 根因分析・知識の呪い (ジャーゴン定義漏れ・Tapper-side)。参照: `skills/pr-doc-review-pe/references/premortem-and-5whys.md`, `skills/pr-doc-review-pe/references/curse-of-knowledge.md`。
  暗黙の仮定の抽出: 各仮定を必ず以下の形式で出力する。「この設計は [X] を前提とする。[X] が偽なら [具体的な障害 Y] が発生する。この前提は文書に明記されていない。」出力条件: (1) X が要件・制約として文書に明記されていない、かつ (2) Y が本番障害・データ不整合・CS 問い合わせ増加に直結する場合のみ出力する。
- **ai-instruction-reviewer** (AI 仕様のみ): what/how 分離 (SPDD)・Golden Rule (文脈なし読者テスト)・ambiguity 語検出・negative-only 指示の positive-example 欠如。参照: `skills/pr-doc-review-pe/references/ai-instruction-spec.md`。

specialist 共通: 既存コメント・PR description で対処済みの指摘は除外する。

## Step 4: Mandatory Pillars 確認

Filter の前に、以下 3 Pillar を specialist 候補から確認する。
発見ゼロの場合は担当 specialist を「force-investigate this pillar」プロンプトで再起動する。
再調査後も発見なければ `N/A: scope confirmed — <確認した具体的根拠 (ファイル名・ADR ID・ドキュメントセクション) を 20 語以上で記録>` とする。

1. **Existing-code alignment**: ADR・CLAUDE.md・既存実装パターン・ユビキタス言語との整合。
2. **Release / Rollback / Compat.**: マルチ PR 順序・フィーチャーフラグ・ロールバック経路・データ移行順。
3. **Observability**: 本番で壊れたとき root cause に到達できる metrics / logs / alerts / traces の充足。

Pillar 発見には `[pillar]` マーカーを指摘事項の severity に並記する (`**[must][pillar]**` 形式)。Pillar 発見は Confidence-Low でも Filter で除外しない。同一 Pillar に属する複数発見で修正アクションが同一の改善提案にまとめられる場合は 1 件にまとめること。
Mandatory Pillars テーブルと指摘事項の双方に記録する (テーブル: 発見要約、指摘事項: `[must][pillar]` 詳細)。

## Step 5: Self-Refine

specialist 返却を surface / mid / deep に分類する。

- **surface**: typo・表記揺れ・段落体裁・行番号誤り・正確性に影響しない命名提案のみ。**surface に分類された指摘は [imo] を上限とし、[must] を付与してはならない。** mid/deep 指摘が 3 件以上ある場合は surface 指摘を FN log に記録して出力を省略してよい。surface 指摘のみの場合は [imo] として出力する。
- **mid**: 個別論理 (条件漏れ・根拠欠如・アウトカム未定義・曖昧語の孤発)。
- **deep**: 設計健全性 (意思決定根拠欠如・代替案未検討・文書内論理矛盾・ubiquitous drift・Rollback 欠如・Observability Gap・AI 仕様の what/how 混在)。

deep 候補が 0〜2 件しかない specialist は「go deeper: design-layer の漏れを 2 件追加で出す」で再起動する。

## Step 6: Filter

各候補を 4 軸 (actionable / specific / verifiable / non-redundant) で評価し Confidence + Severity を付与する。

- **Confidence**: High (2+ source 裏付け) / Medium (1 source) / Low (弱い裏付け)。
- **Severity**: `[must]` (意思決定不能・整合性破壊・リリースリスク) / `[imo]` (改善望ましい) / `[ask]` (設計意図確認) / `[good]` (優れた判断) / `[next]` (今回スコープ外)。`[nits]` は使わない。

旧 3 anti-pattern を以下で置換する。

1. 既存パターン一致でも指摘を廃棄しない: Confidence-Low に分類したうえで、`skills/pr-review-pe/references/existing-pattern-matching.md` の risk-exception passthrough リスト (セキュリティ・データ整合性・API 契約・runtime crash・計算可能なスケーラビリティ後退) のいずれかに該当する場合は通常 Confidence・Severity で出力する。
2. 設計意図と矛盾する指摘も廃棄しない: rationale-reviewer が Step 3 で内部生成した逆生成代替案 (reverse-generated alternative intents、3 件) を参照し、ドキュメントが選択意図をいずれの代替に対しても正当化できていない場合は `[ask]` でその正当化を求める (出力に代替は列挙しない)。
3. 引用はドキュメント本文に限らない: { ドキュメント引用 / 既存コード・実装 / ADR・RFC / CLAUDE.md・プロジェクト規約 / 関連過去 PR } のうち少なくとも 1 件を引用元として持てば候補に残す。

Confidence-Low かつ risk-exception に該当せず Pillar でない候補は除外し、除外件数と理由を False-Negative log として記録する。
**deep** に分類された候補が除外される場合は、specialist 名・指摘概要（10 語以内）・除外理由を個別に記録し、最終出力の FN log に含める。

## Step 7: Meta-Review

最終出力前に全指摘を再読し、曖昧表現・誤読される可能性・非プロフェッショナルな口調・引用元と本文の対応漏れを修正または除外する。

## Step 8: 出力フォーマット

Risk Register・Open Questions は独立セクションとして出力しない。重大リスクは [must] 指摘に統合し、未確認事項は [ask] 指摘に統合する。block quote（`▎` 記号・複数行 `>` 引用ブロック）は使用しない。行番号は参照先として十分であり引用文を別記する必要はない。

```markdown
## PR #NNN レビュー: <タイトル>

**総評**: 2〜3 文。ドキュメント種別・全体印象・最重要懸念。AI 仕様の場合は what/how 分離の評価を含む。

### Pillars
| Pillar | 状態 |
|--------|------|
| Existing-code alignment | <発見概要 または N/A: 根拠 20 語以上> |
| Release / Rollback | <発見概要 または N/A: 根拠 20 語以上> |
| Observability | <発見概要 または N/A: 根拠 20 語以上> |

### 指摘

**[must]** `path/to/doc.md:42` — 論点タイトル（15 語以内）
現状: ドキュメントの記述と問題の具体的な説明（1〜2 行）
あるべき姿: 修正の方向性（1〜2 行）

**[must][pillar]** `path/to/doc.md:89` — 論点タイトル
現状: ...
あるべき姿: ...

**[ask]** `path/to/doc.md:15` — 論点タイトル
現状: ...
確認: 著者に問うべき具体的な質問（1 行）

**[imo]** `path/to/doc.md:50` — 論点タイトル
現状: ...
あるべき姿: ...

### 良い点
- `path/to/doc.md:line` — 優れた設計判断（1 行）

### 検証ログ
Brainstorm N → Self-Refine M → Filter K 件
除外: X 件（FN: <specialist / 指摘概要 10 語以内 / 除外理由> 改行区切り。なしの場合は「なし」）
```

指摘事項がない場合は「指摘なし。Approve 推奨。」と書く。`[good]` は `### 良い点` 専用。
