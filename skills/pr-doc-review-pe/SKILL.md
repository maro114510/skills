---
name: pr-doc-review-pe
description: >
  ドキュメント・設計 PR (Layer-2) 専用の Principal Engineer 視点レビュースキル。
  Design Doc / ADR / RFC / 実装計画書 / AI 向け仕様書などの Markdown 中心 PR を対象に、メタ情報・設計健全性・既存コード整合・運用設計・認知負荷・暗黙の仮定・知識の呪いの 7 観点と、AI 向け仕様固有の what/how 分離・Golden Rule・曖昧語検出を検査する。
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

- **rationale-reviewer**: Nygard 5 構成要素・Olaf Zimmermann 7 質問・逆生成代替案 3 件生成・Consequences-negative の欠如。参照: `skills/pr-doc-review-pe/references/adr-checklist.md`, `skills/pr-doc-review-pe/references/design-doc-checklist.md`。
- **operational-reviewer**: Rollout / Rollback / Multi-DC / Metrics / カスタマーサポート対応の充足。参照: `skills/pr-doc-review-pe/references/operational-design.md`。
- **readability-reviewer**: BLUF / ピラミッド原則 / ワーキングメモリ ≤ 7±2 / split-attention / メタ情報 (Audience・Non-Goals・DoD)。参照: `skills/pr-doc-review-pe/references/cognitive-load.md`, `skills/pr-doc-review-pe/references/meta-information.md`。
- **ubiquitous-language-reviewer**: Step 2 の git grep 結果を使い、コードとの概念語乖離・Bounded Context 境界超え・同概念の別名混在を検出。参照: `skills/pr-doc-review-pe/references/ubiquitous-language.md`。
- **premortem-reviewer**: プリモーテム失敗シナリオ 3 件・5-Whys 根因分析・暗黙の仮定の可視化・知識の呪い (ジャーゴン定義漏れ・Tapper-side)。参照: `skills/pr-doc-review-pe/references/premortem-and-5whys.md`, `skills/pr-doc-review-pe/references/curse-of-knowledge.md`。
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

- **surface**: typo・表記揺れ・段落体裁のみ。
- **mid**: 個別論理 (条件漏れ・根拠欠如・アウトカム未定義・曖昧語の孤発)。
- **deep**: 設計健全性 (意思決定根拠欠如・代替案未検討・ubiquitous drift・Rollback 欠如・Observability Gap・AI 仕様の what/how 混在)。

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

```markdown
## PR #NNN レビュー: <タイトル>

### 総評
（3〜4 文。ドキュメント種別・全体印象・最重要懸念。AI 仕様の場合は what/how 分離の評価を含む）

### Mandatory Pillars

| Pillar | 発見 / N/A |
|--------|-----------|
| [pillar] Existing-code alignment | <発見または N/A: scope confirmed — ファイル名・セクションを含む 20 語以上の根拠> |
| [pillar] Release / Rollback / Compat. | <発見または N/A: scope confirmed — ファイル名・セクションを含む 20 語以上の根拠> |
| [pillar] Observability | <発見または N/A: scope confirmed — ファイル名・セクションを含む 20 語以上の根拠> |

### 指摘事項

**[must] `path/to/doc.md:42`**: 問題の説明
> `ドキュメント引用`
→ 改善案:

**[ask] `path/to/doc.md:15`**: 設計意図の確認
> `引用`
→ 確認事項:

### Risk Register

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| ... | High/Med/Low | High/Med/Low | ... |

### Open Questions

1. <PR の逆解析から導いた未確認事項>

### 良い点
- [good] ...: 評価できる設計判断

### 自己検証結果
Brainstorm N → Self-Refine M → Filter K → Meta-Review L 件
除外: X 件 (うち Confidence-Low 廃棄: Y、risk-exception 経由復活: Z)
FN log — deep 除外: <specialist 名 / 指摘概要（10 語以内）/ 除外理由 を改行区切りで列挙。除外なしの場合は「なし」>
```

指摘事項がない場合は「指摘事項なし。Approve 推奨。」と書く。`[good]` は `### 良い点` 専用。
