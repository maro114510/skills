# Case 10 結果: 橋渡し根拠によって正当化される移送 / transfer justified by bridging evidence

ケース定義: `../10-bridging-evidence-justified.md`（`deep`モードの陽性対照。橋渡し研究が検証済みで `transfer_status: justified` を付けるべきケース。）

## Baseline（no-skill）transcript

この主張、単独では微妙です。文面は「都市部で検証された効果が地方でも同様に期待できる」と言っていて、これは資料Aの実験デザイン（都市部400名のRCT）の話に見えます。でも資料Aは自分で「地方への一般化には追加研究が必要」とはっきり書いていて、まさにこの主張を先回りして否定している。資料Aだけを根拠にこの主張をするなら、これは論文の限界セクションを無視した拡大解釈です。

ただし資料Bがまさにその「追加研究」そのもので、都市部と地方部で同一プログラムを直接比較し、交互作用が有意でない（p=0.58）ことを示している。効果量も都市部28%/12%、地方24%/11%とかなり近い。なのでこの主張の中身自体は、資料Bを根拠にするなら十分support可能です。

判断としては「主張自体は妥当、ただし引用元がずれている」という感じです。実務的には「地方在住者にも同様の効果が期待できる（資料B）」と出典を明示するよう修正を求めます。confidence: 中程度。

## With-skill transcript（deep モード）

```markdown
## Research Transfer Check

### 資料の取得状況
- 資料A（Ichinose K, et al., 2019）: full_verified
- 資料B（Segawa N, Umeda K, 2022／橋渡し根拠、Step 5 の探索で確認）: full_verified

### 判定サマリー
- citation_support: direct 1件
- transfer_status: justified 1件
- integrity_concern: false

#### C1
- citation_support: direct
- transfer_status: justified
- source_access（citation_support の根拠資料＝資料A）: full_verified
- source_access（transfer_status の根拠資料＝資料B）: full_verified
- confidence: 高
- integrity_concern: false
- reasoning_type: 該当なし
- 問題のある推論箇所: 該当なし

### 追加探索
- 探索日: 2026-07-24
- 検索範囲: 資料Aと同一の禁煙支援プログラムを対象に、都市部・地方部を直接比較した一次研究、追試研究、体系的レビュー
- 確認した情報源の種類: 査読誌掲載の一次研究論文（多施設RCT）1件（資料B、全文確認済み）
- 確認できた支持・反証・境界条件: 支持=資料B（地域×プログラムの交互作用は非有意、p=0.58）。反証=本探索範囲内では確認できなかった。境界条件=地方部の一部施設で遠隔面談への切替。
- 限界: 対象を絞った探索であり、根拠の不存在を証明するものではない
```

## 採点

**期待される判定**: citation_support `direct` / transfer_status `justified`（両source_accessともfull_verified）。

**採点基準チェック**:
- [x] transfer_status は `justified` — 正解
- [x] `deep`モードの出力に探索日・検索語・確認した情報源の種類の記録がある — 正解
- [x] citation_support は `direct` — 正解

**判定: PASS（全採点基準を満たす）**

`deep`モードの陽性対照として設計された本ケースで、スキルは橋渡し根拠（資料B）を正しく評価し、非対称ゲートを満たした上での肯定判定（`direct`＋`justified`）を過不足なく行った。baseline（no-skill）判断は「資料Aだけでは根拠不足、資料Bを引用すれば妥当」という部分的に正しい直感を示したが、非対称ゲートの理論（source_accessが軸ごとに判定される、橋渡し資料の検証水準が移送判定を決める）までは踏み込めておらず、with-skill実行の方が構造的に優れていた数少ない明確な事例。
