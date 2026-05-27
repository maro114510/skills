# Existing-Pattern Matching: Confidence-Low Classification

## Purpose

「既存類似ファイルと一致するパターン」を発見しても、指摘を完全に廃棄しない。
Confidence-Low として保持し、リスク高い領域 (risk-exception passthrough) に該当する場合は通常 Confidence / Severity で出力する。

## Checklist

1. **既存パターン照合の手順**
   - 同種ファイル (GitHub Actions: 同命名ワークフロー / Go ハンドラ: 同ディレクトリ / IaC: 同種リソース) を 2〜3 件確認する。
   - 同じパターンが他にあるかを判定する:
     - YES → 候補を **Confidence-Low** に分類。
     - NO → 通常 Confidence で評価。
   - 既存ファイルが存在しない (新規追加のみ) は NO 扱いで通常 Confidence。

2. **risk-exception passthrough リスト (Confidence-Low バイパス)**

   以下のいずれかに該当する場合、既存パターン一致でも通常 Confidence / Severity で出力する。

   - **セキュリティ**: 認証・認可・シークレット漏洩・SQLi / コマンド / XSS / パストラバーサル / SSRF。
   - **データ整合性**: トランザクション破壊・順序逆転・ロスト更新・重複処理・整合性制約欠如。
   - **API 契約**: 既存公開 API の互換性破壊・型変更・パラメータ削除・エラーコード変更。
   - **runtime crash**: nil 参照・OOB アクセス・パニック伝播・unrecovered exception。
   - **計算可能なスケーラビリティ後退**: 呼び出し元 × データ量 × 外部 I/O で `O(n²)` 以上に増幅する数値根拠が示せるもの。

3. **判定の記録**
   - 候補ごとに「既存パターン一致: YES/NO」「risk-exception 該当: あり/なし (該当カテゴリ)」を内部メモに残し、Filter フェーズの False-Negative log に集計する。
   - risk-exception 該当で復活させた候補は別カウントで記録する。

## Anti-patterns

- 既存パターン一致を理由に指摘を完全に取り下げる (本ポリシーで廃止された旧ルール)。
- risk-exception 該当でも「慣習踏襲のため修正不要だが」と付記して隠蔽する。
- 既存ファイル 1 件だけ確認して NO と判定する (2〜3 件確認が最低ライン)。
- risk-exception の「計算可能なスケーラビリティ」を、根拠数値なしの推測で適用する。
- 「将来的な改善提案」「設計確認」という形で実質的に指摘を再投入する。

## Sources

- arXiv:2601.01129 — RovoDev 5-axis review with Confidence / Severity ranking。
  https://arxiv.org/abs/2601.01129
- arXiv:2501.15134 — BitsAI-CR detection / filtering separation。
  https://arxiv.org/abs/2501.15134
- Anthropic — Code Review Harness Guidance (filtering as post-processing)。
  https://docs.anthropic.com/
- Adam Shostack — Threat Modeling 4-question framework (risk-exception analogue)。
