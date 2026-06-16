---
name: pr-doc-review-pe
description: >
  設計ドキュメント (Design Doc / ADR / RFC / 実装計画書) 専用の Principal Engineer 視点レビュースキル。
  目的は 2 つだけ: (A) 書いてあることに潜む、著者が気づいていない可能性のある致命的になりうる欠陥・論理の漏れ (論理矛盾・根拠欠如・暗黙の仮定) を暴くこと。(B) 書いてないことのリスク (スケール限界・想定外挙動・移行・ロールバック・可観測性・ライブラリ制約・より良い設計の選択肢) を厳しく問うこと。
  すべての指摘は「この設計は X を前提とする。X が偽なら障害 Y が起きる」という具体的障害シナリオに接地し、本番障害・データ不整合・移行失敗・ロールバック不能・契約破壊に直結する致命度の高いものだけを出す。typo・表記揺れ・体裁・命名の好みといった textlint 的な些末指摘は一切しない。
  「Design Doc レビュー」「ADR を見て」「RFC レビュー」「実装計画書を確認して」「設計レビュー」「設計書のレビューをして」「この設計の穴を探して」などの依頼で使う。
  引数に PR 番号または GitHub URL を渡す。
allowed-tools: Read, Glob, Grep, Bash(pr-review-pe-identify-pr.sh:*, gh pr diff:*, gh pr view:*, rg:*, git grep:*, git log:*, echo:*), WebFetch, Agent
argument-hint: "<pr-number or url>"
---

# pr-doc-review-pe

設計ドキュメント PR を 2 パス (書いてあることの欠陥 / 書いてないことのリスク) でレビューし、致命的になりうるものだけを指摘する orchestrator。

## レビューの原則

1. **接地された致命度ファースト** — すべての指摘を次の形式に接地する。
   「この設計は [X] を前提とする。[X] が偽なら [具体的障害 Y] が発生する。」
   そのうえで致命度ゲートを通す: 本番障害・データ不整合・移行失敗・ロールバック不能・API/データ契約の破壊に直結するものだけ出力する。抽象的な「[X] を検討しては?」は禁止。落とした候補は FN log に残す。
2. **textlint 的指摘の全廃** — typo・表記揺れ・段落体裁・行番号誤り・命名の好み・曖昧語の孤発検出は一切しない。これらは指摘対象外。
3. **代替は設計レベルで問う** — API 名・テーブル名・カラム名レベルの代替は提示しない。主軸は「そもそもこれをやるべきか」「根本的に優れたアプローチはないか」。より良い設計が見えたら名指しで提示し 4 軸 (scalability / ops-complexity / reversibility / debuggability) で比較したうえで、採否は `[ask]` で著者に委ねる。

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

diff から記録する: 変更 .md ファイル一覧・ドキュメント種別推定 (ADR / RFC / Design Doc / 実装計画)・キーノウン (名詞・ドメイン概念語 5〜10 件)。

## Step 2: 接地調査

キーノウンをコードベースと照合する。書いてないことのリスクを repo 証拠に接地し、既存整合・ライブラリ制約を確かめるための基盤。

```bash
git grep -n "<キーノウン>" -- '*.go' '*.ts' '*.py' '*.java' '*.kt' '*.rb'
```

ヒットしない語はユビキタス言語ドリフト候補、ヒット語は定義とドキュメント記述を照合する。
この手順は必ず実行し、結果 (ゼロヒット語リスト・一致コード行) をトランスクリプトに残し、Pass 1 / Pass 2 の起動プロンプトに含める。

## Step 3: Pass 1 — 書いてあることの欠陥

`Agent` (subagent_type: general-purpose) を 1 つ起動する。Step 1・Step 2 のデータ (diff・既存コメント・git grep 結果) を渡す。文書を精読し、書いてある内容そのものに潜む論理の漏れを探す。低 confidence でも候補を保持し `doc-path:line` + 引用元を返す。

検査する観点:

- **文書内論理矛盾**: 責務割り当て文 (「X が Y を担う」「状態は A が保持する」) を全件抽出し、Process 矛盾 (二者が同一責務を主張 / 誰も担わない穴)・Policy Reversal (「常に X」と「Y の場合は X しない」)・Temporal (順序・タイミング)・Specificity (一般クレームと特定クレームが両立しない処方) を検出する。発見ごとに Claim A 引用 / Claim B 引用 / 矛盾種別 / 両立不能な理由を 1 文で出す。
- **WHY 欠落**: 意思決定文 (「〜を選択した」「〜は対象外とした」「〜を採用する」) を全件抽出し、前後 3 段落以内に明示的な根拠があるか確認する。なければ MISSING_RATIONALE として著者への probing question を生成する。Nygard 5 構成要素・Olaf Zimmermann 7 質問・Consequences-negative の欠如も確認する。参照: `skills/pr-doc-review-pe/references/adr-checklist.md`, `skills/pr-doc-review-pe/references/design-doc-checklist.md`。
- **暗黙の仮定**: 各仮定を必ず「この設計は [X] を前提とする。[X] が偽なら [具体的障害 Y] が発生する。この前提は文書に明記されていない。」形式で出す。出力条件は (1) X が要件・制約として明記されていない、かつ (2) Y が本番障害・データ不整合・CS 問い合わせ増加に直結する場合のみ。参照: `skills/pr-doc-review-pe/references/premortem-and-5whys.md`。
- **既存整合**: ゼロヒット語のユビキタス言語ドリフト、既存 ADR・CLAUDE.md・実装パターンに反する選択。参照: `skills/pr-doc-review-pe/references/ubiquitous-language.md`。

## Step 4: Pass 2 — 書いてないことのリスク

Pass 1 とは独立に `Agent` (subagent_type: general-purpose) を起動する。**Pass 1 の発見は渡さない** — 「書いてある内容」に引きずられず、「あるべきなのに無いもの」を白紙から想像させるため。Step 1・Step 2 のデータのみ渡す。これが本スキルの主眼。

各観点で「あるべきなのに文書に無いもの」を探し、見つけたら具体的障害シナリオに接地して出す。

- **スケール**: ユーザー数・データ量・トラフィックが増えたとき破綻する設計か。前提となる規模が明記されているか。参照: `skills/pr-doc-review-pe/references/scale-and-failure-modes.md`。
- **想定外挙動**: 異常系・エッジケース・並行性・冪等性・失敗時の振る舞いが未定義でないか。「正常系しか書いていない」を疑う。参照: `skills/pr-doc-review-pe/references/scale-and-failure-modes.md`。
- **移行**: 移行期間・後方互換・データ移行順序・デュアルライト・新旧併存中の挙動が抜けていないか。
- **ロールバック**: 失敗時の切り戻し経路・不可逆操作が考慮されているか。「手動で対応」のみは不可。参照: `skills/pr-doc-review-pe/references/operational-design.md`。
- **可観測性**: 本番で壊れたとき root cause に到達できる metrics / logs / alerts があるか。「既存ダッシュボード参照」のみは不可。参照: `skills/pr-doc-review-pe/references/operational-design.md`。
- **ベストプラクティス / ライブラリ制約**: 採用技術・ライブラリの既知の制約・誤用・非準拠がないか。不確かな場合は `WebFetch` で一次情報を確認する。
- **より良い設計の選択肢**: 原則 3 に従い、設計レベルで「本当にやるべきか」「根本的に優れたアプローチはないか」を問う。見つけたら名指し + 4 軸比較し `[ask]` で採否を委ねる。

プリモーテム (「6 ヶ月後に失敗するとしたら理由 3 件」を逆生成し文書内で識別・緩和されているか) を補助に使う。参照: `skills/pr-doc-review-pe/references/premortem-and-5whys.md`。

## Step 5: 自己検証ゲート

両 Pass の候補を統合し、以下を 1 回だけ通す。

1. **重複排除**: 同一 doc-path:line で重複する候補をまとめる。
2. **致命度ゲート**: 各候補が本番障害・データ不整合・移行失敗・ロールバック不能・API/データ契約の破壊のいずれかに直結するか判定する。直結しないものは除外し FN log に記録する。
3. **接地検証**: 各指摘が「具体的障害シナリオに接地しているか」「actionable / specific / verifiable か」を確認する。抽象的な提案・接地のない懸念は除外する。
4. **重複コメント除外**: 既存コメント・PR description で対処済みの指摘は除外する。
5. **Severity 付与**: `[must]` (意思決定不能・整合性破壊・致命的リスク) / `[ask]` (設計意図・採否の確認) / `[imo]` (改善望ましい) / `[good]` (優れた判断) / `[next]` (今回スコープ外)。`[nits]` は使わない。

## Step 6: 出力フォーマット

block quote (`▎` 記号・複数行 `>` 引用ブロック) は使わない。行番号は参照先として十分で、引用文を別記する必要はない。

```markdown
## PR #NNN レビュー: <タイトル>

**総評**: 2〜3 文。ドキュメント種別・全体印象・最重要懸念 (致命的になりうる欠陥か、書いてないリスクか)。

### 観点カバレッジ
| 観点 | 状態 |
|------|------|
| 論理矛盾 / WHY 欠落 / 暗黙の仮定 | <発見概要 または N/A: 根拠 20 語以上> |
| スケール / 想定外挙動 | <発見概要 または N/A: 根拠 20 語以上> |
| 移行 / ロールバック / 可観測性 | <発見概要 または N/A: 根拠 20 語以上> |
| ライブラリ制約 / より良い選択肢 | <発見概要 または N/A: 根拠 20 語以上> |

### 指摘

**[must]** `path/to/doc.md:42` — 論点タイトル (15 語以内)
現状: ドキュメントの記述と問題の具体的な説明。致命的になりうる理由を障害シナリオで示す (1〜2 行)
あるべき姿: 修正の方向性 (1〜2 行)

**[ask]** `path/to/doc.md:15` — 論点タイトル
現状: 書いていない前提・検討されていない代替の具体的な説明 (1〜2 行)
確認: 著者に問うべき具体的な質問 (1 行)

**[imo]** `path/to/doc.md:50` — 論点タイトル
現状: ...
あるべき姿: ...

### 良い点
- `path/to/doc.md:line` — 優れた設計判断 (1 行)

### 検証ログ
Pass 1 (欠陥) N 件 / Pass 2 (欠落) M 件 → 統合・致命度ゲート後 K 件
除外: X 件 (FN: <観点 / 指摘概要 10 語以内 / 除外理由> 改行区切り。なしの場合は「なし」)
```

指摘事項がない場合は「指摘なし。Approve 推奨。」と書く。`[good]` は `### 良い点` 専用。
