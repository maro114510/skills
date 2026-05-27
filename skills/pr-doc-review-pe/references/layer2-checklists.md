# Layer-2 Observation Groups: Documentation / Design PR Checklists

## § Meta Information

**Audience & Scope**
- 想定読者が明示されているか (エンジニア / PM / SRE / 全員？)。
- Non-Goals が明示されているか (スコープ外の混入を防ぐ)。
- ドキュメント種別が明示されているか (ADR / RFC / Design Doc / 実装計画)。
- Definition of Done (DoD) が定義されているか。

**Anti-patterns**
- 暗黙の想定読者 (「全員が知っているはずの前提」を無修飾で使う)。
- Non-Goals なし → スコープクリープを招く。

---

## § Design Soundness

**Nygard ADR 5 構成要素** (Documenting Architecture Decisions, 2011)
1. Context — 決定を行った状況・制約・優先事項。
2. Decision — 採択した設計選択。
3. Status — Proposed / Accepted / Deprecated / Superseded。
4. Consequences — 正と負の両側。Consequences-negative が欠如していないか。
5. Alternatives — 検討した代替案とその棄却理由。

**Olaf Zimmermann ADR レビュー 7 質問** (ozimmer.ch, 2023)
1. 決定の対象 (what) が明確か？
2. なぜこの決定が必要か (why)？
3. 採択の根拠 (justification) が示されているか？
4. 代替案とトレードオフが比較されているか？
5. ステークホルダーが識別されているか？
6. Consequences (positive/negative/risks) が記述されているか？
7. レビュー・改訂の基準が明示されているか？

**逆生成代替案チェック**
- 文書から 3 件の「書かれていない代替案」を逆生成し、採択案がそれらより優れている根拠が文書内にあるかを確認する。
- 根拠がない代替案があれば `[ask]` または `[must]` として指摘する。

---

## § Existing-Code Alignment

**ユビキタス言語チェック**
- 変更ドキュメント内のキーノウン (名詞・ドメイン概念語) を 5〜10 件抽出する。
- `git grep -n "<noun>" -- '*.go' '*.ts' '*.py'` でコードとの表記一致を確認する。
- コードでは `isNewCustomer`、ドキュメントでは「新規ユーザー」のような乖離はユビキタスドリフト。

**Bounded Context 境界**
- 変更ドキュメントが複数の Bounded Context にまたがる用語を混在させていないか。
- 同概念が複数の名前で使われていないか (例: order / purchase / transaction を混用)。

**ADR・CLAUDE.md 整合**
- 既存 ADR / CLAUDE.md に反する設計選択が採択されていないか。
- 採択前に既存 ADR との衝突を確認済みか。

---

## § Operational Design

Uber RFC テンプレートに基づく必須フィールド確認:

1. **Rollout 計画**: デプロイ順序・フィーチャーフラグ・段階的展開の記述があるか。
2. **Rollback 計画**: 失敗時に元の状態に戻す手順・条件が明示されているか。
3. **Multi-DC / Multi-Region**: 地理的冗長性・データ整合性 (eventual / strong) が考慮されているか。
4. **Metrics / Alerting**: 成功・失敗を判定するメトリクスと閾値が定義されているか。
5. **カスタマーサポート対応**: ユーザー影響発生時のサポート手順が記述されているか。

**Anti-patterns**
- Rollback 欄なし or「手動で対応」のみ。
- 「段階的展開」と書くが具体的な閾値・中断条件がない。
- メトリクス欄に「既存ダッシュボードを参照」のみ (新指標の定義がない)。

---

## § Cognitive Load

**BLUF / ピラミッド原則** (Minto)
- 結論先行 (BLUF: Bottom Line Up Front) になっているか。
- 各セクションが主張 → 根拠 → 詳細の順になっているか。
- 前提説明が長すぎて結論が後ろに隠れていないか。

**ワーキングメモリ 7±2 ルール** (Sweller, Cognitive Load Theory)
- 1 セクション内の箇条書きが 9 件を超えていないか。
- 1 文内で参照する概念が 5 個を超えていないか。

**Split-attention 回避**
- 図と説明文が遠くに置かれていないか (図の直後に説明を置く)。
- 表のヘッダと内容が対応しているか。

---

## § Implicit Assumptions

**プリモーテム** (Klein, HBR 2007)
- 「このプランが 6 ヶ月後に失敗したとしたら、最もあり得る理由 3 件は何か」を逆生成する。
- それらのリスクが文書内で識別・緩和されているかを確認する。

**5-Whys 根因分析**
- 提案の動機を 5-Whys で掘り下げて、根本原因と提案の解決が対応しているかを確認する。
- 表面的な症状だけを解決していないか。

**暗黙の仮定の可視化**
- 「これは自明だから書かなかった」が読者に通じない前提になっていないか。
- インフラ・コスト・チーム体制・スケジュール・規制について、文書外に依存した前提がないか。

---

## § Curse of Knowledge

**ジャーゴン定義チェック** (Pinker / Heath)
- 技術用語・社内略語が初出時に定義されているか。
- 定義なしで使われている用語リストを抽出し、初見読者が理解できるかを判定する。

**Tapper-side チェック**
- 作成者が「誰でも分かる」と思っているが、背景を持たない読者には分からない箇所はないか。
- 「詳細は X を参照」が、X を読まないと本文が理解できない依存になっていないか。

**曖昧語検出**
- 「適切に」「必要に応じて」「考慮する」「十分に」「基本的に」「など」が、判断基準なしで使われていないか。
- これらが使われている場合、実行条件・対象範囲・失敗時判断が読めるかを確認する。

---

## Sources

- Nygard — Documenting Architecture Decisions (cognitect.com, 2011)
- Zimmermann — How to review ADRs and how not to (ozimmer.ch, 2023)
- Uber RFC template — Pragmatic Engineer newsletter
- Eric Evans — Domain-Driven Design (Ubiquitous Language, Bounded Context)
- Martin Fowler — Ubiquitous Language (bliki)
- Sweller — Cognitive Load Theory
- Minto — The Pyramid Principle
- Klein — Performing a Project Premortem (HBR, 2007)
- Pinker — The Sense of Style; Heath & Heath — Made to Stick (Curse of Knowledge)
- arXiv:2504.20781 — Design Rationale auto-generation
