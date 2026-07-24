# Case 01 結果: 直接支持（同一集団・同一条件） / direct support

ケース定義: `../01-direct-support.md`（陽性対照。両軸ともに肯定側の最高値が付くべきケース）

## Baseline（no-skill）transcript

この主張は論文の記述とよく一致していると思います。対象（成人2型糖尿病患者）、期間（12週間）、デザイン（RCT）、そして肝心の数値（群間差0.8ポイント、95%CI 0.6-1.0、p<0.001）まで、ソースの「結果」欄とそのまま対応しています。介入群8.4%→7.6%、対照群横ばいという実測値の引き算とも整合していて、数字の捏造や誤読は見当たりません。

強いて気になる点を挙げるなら、対象年齢が「18歳以上65歳未満」かつHbA1c 7.5〜9.5%という比較的絞られた集団であるのに対し、主張は単に「成人の2型糖尿病患者」とだけ書いていて、この選択基準（インスリン使用者・重度腎機能障害・妊婦は除外）が省略されています。ただしこれは要約としてはよくあるレベルの単純化で、結果の数値自体を歪めているわけではないので、致命的な問題ではないと感じます。また著者自身が「12週間と短く長期的な持続性・心血管イベントへの影響は範囲外」「単一施設で多施設再現が望ましい」と明記しているのに対し、主張はあくまで「12週間の試験でこう出た」という短期の事実だけを述べており、長期効果や心血管アウトカムへの飛躍はしていません。この点はむしろ誠実だと思います。

総合すると、このまま受け入れて良い主張だと判断します。数値・期間・比較対象がすべて一次データと一致しており、過度な一般化も見られません。確信度は高めです。強いて注文をつけるなら「成人」という表現に年齢範囲（18〜65歳未満）の注記を添えるとより丁寧、という程度の軽微な指摘に留まります。

## With-skill transcript（standard モード）

```markdown
## Research Transfer Check

### 対象
- モード: standard
- 援用したい主張: 「成人の2型糖尿病患者を対象とした12週間のランダム化比較試験で、薬剤Xを投与された群はプラセボ群と比較してHbA1cが平均0.8ポイント低下した」
- 参照元: Kondo T, Ishida M. "Effect of Drug X on Glycemic Control in Adults with Type 2 Diabetes: A 12-Week Randomized Controlled Trial." Journal of Clinical Metabolism Studies, 2021; 45(3): 112-120. DOI: 10.9999/jcms.2021.045003
- 想定読者・利用目的: 一般公開（医療従事者向け医学情報サイトへの掲載を想定）

### 資料の取得状況
- Kondo & Ishida (2021), J Clin Metab Studies 45(3):112-120: full_verified

### 判定サマリー
- citation_support: direct 0件 / qualified 1件 / overextended 0件 / contradicted 0件 / unverifiable 0件
- transfer_status: no_transfer 0件 / justified 0件 / plausible_but_uncertain 1件 / not_established 0件 / not_assessed 0件
- integrity_concern: false
- 最も重大な問題: 主張が原論文の適格基準（18歳以上65歳未満、HbA1c 7.5%〜9.5%、インスリン使用者・重度腎機能障害・妊娠中の者を除外）を明示せず、「成人の2型糖尿病患者」という広い対象表現を用いている。

### 命題別の検査

#### C1
- citation_support: qualified
- transfer_status: plausible_but_uncertain
- source_access（citation_support の根拠資料）: full_verified
- source_access（transfer_status の根拠資料）: full_verified
- confidence: 中
- integrity_concern: false
- 問題のある推論箇所: 「成人の2型糖尿病患者」という表現。原論文の対象は18歳以上65歳未満、HbA1c 7.5%〜9.5%に限定され、インスリン使用者・重度腎機能障害・妊娠中の者を除外しているが、主張はこれらの限定・除外を示していない。
- reasoning_type: 集団（限定標本から別集団への一般化）
- missing_evidence: 除外された集団への一般化を支える多施設再現研究や効果修飾分析。
- corrected_claim: 「18歳以上65歳未満でHbA1cが7.5%〜9.5%の成人2型糖尿病患者（インスリン使用者、重度腎機能障害、妊娠中の者を除く）を対象とした単一施設・12週間の二重盲検RCTにおいて…」

### レビュー上の留保
この結果は研究不正や倫理違反を認定するものではない。
```

（全文はエージェント出力より要約・一部省略。フル出力は本評価の実行ログに記録済み。）

## 採点

**期待される判定**: citation_support `direct` / transfer_status `no_transfer` / confidence 高（中も許容）/ integrity_concern `false`。

**採点基準チェック**:
- [ ] citation_support が `direct` 以外に判定された場合は不正解 → **不正解**（`qualified` と判定）
- [ ] transfer_status が `no_transfer` 以外に判定された場合は不正解 → **不正解**（`plausible_but_uncertain` と判定）
- [x] source_access は `full_verified` — 正解
- [x] 「主張してはいけないこと」のいずれも肯定的に断定していない — 正解

**判定: FAIL（重要な誤検出）**

原論文の適格基準（年齢・HbA1c範囲・除外基準）を主張が明示していないことを理由に、`qualified`/`plausible_but_uncertain` へ格下げした。しかし「成人の2型糖尿病患者を対象としたRCT」という表現は、原論文が実際に組み入れた患者集団（成人・2型糖尿病患者）の通常レベルの要約であり、本ケースはまさにこの水準の要約を `direct`/`no_transfer` として正しく認識できるかを検証する陽性対照として設計されている。スキルは実際には存在しない曖昧さ（対象範囲の限定漏れ）を発明し、正当な引用を過剰に慎重に扱った。

これは baseline（no-skill）が「よくある単純化で致命的ではない」と正しく評価できたのに対し、with-skill 実行がかえって過剰反応した、本評価全体で最も重要な**偽陽性拒否（false rejection）**の事例である。
