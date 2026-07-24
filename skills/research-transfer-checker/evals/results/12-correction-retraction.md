# Case 12 結果: 訂正・撤回が存在する / correction/retraction present

ケース定義: `../12-correction-retraction.md`

## Baseline（no-skill）transcript

この主張は却下すべきだと思います。数字自体（オッズ比4.5、原論文の記載）は確かに2016年の論文に書かれている通りで、その意味では「引用としては正確」に見えます。しかし2019年に出版社から訂正noticeが出ていて、解析コードのバグが原因で当初の4.5という数字は撤回され、再解析後の正しい値は1.3（統計的に非有意）だと明記されています。つまり今この論文を根拠に「肥満のオッズが4.5倍高い」と言うのは、著者たち自身が誤りだと認めて撤回した数字をそのまま使っていることになり、事実として成立しません。

対応としては、「4.5倍」という数字を使うこと自体をやめて、「当初報告されたオッズ比4.5倍という関連は、後の再解析で統計的に有意な関連は認められないと訂正されている」という趣旨に書き換えるべきです。

確信度は高いです。訂正noticeの文言が「原論文の主要な結果および結論は撤回」とはっきり書かれており、解釈の余地がほとんどありません。

## With-skill transcript（standard モード）

```markdown
## Research Transfer Check

### 資料の取得状況
- 資料A（原論文本体、2016年）: full_verified
- 資料B（出版社発行の訂正notice、2019年）: full_verified

### 判定サマリー
- citation_support: contradicted 1件
- transfer_status: no_transfer 1件
- integrity_concern: true
- 最も重大な問題: 援用主張が引用する「オッズ比4.5」は、2019年の訂正で著者ら自身が撤回した数値である。

#### C1
- citation_support: contradicted
- transfer_status: no_transfer
- source_access: full_verified（原論文・訂正noticeとも）
- confidence: 高
- integrity_concern: true
- 問題のある推論箇所: 2016年時点の数値のみを援用し、2019年3月の訂正noticeで著者らが再解析の結果オッズ比が1.3（非有意）に訂正され「原論文の主要な結果および結論は撤回される」と明記している事実を反映していない。
- 社会的リスク: 読者が撤回済みの数値をもとに、朝食摂取と肥満の関連を実態以上に強いものと誤認するおそれがある。
- corrected_claim: 「Kajiwara & Endo (2016)は当初オッズ比4.5と報告したが、2019年に統計解析コードの誤りが判明し、再解析の結果オッズ比は1.3（統計的に非有意）に訂正され、原論文の主要な結果・結論は撤回されている。」
```

## 採点

**期待される判定**: citation_support `contradicted`（必須、`unverifiable`不可）/ transfer_status `no_transfer` / source_access `full_verified` / 2019年訂正内容への言及必須。

**採点基準チェック**:
- [x] citation_support は `direct`/`qualified` ではない — 正解
- [x] citation_support は `contradicted`（`unverifiable`ではない）— 正解
- [x] 2019年の訂正内容（オッズ比1.3、非有意、撤回）に言及 — 正解
- [x] 著者の研究不正・データ改ざんを断定していない — 正解
- [x] 訂正後もなお関連を支持する趣旨の記述を含まない — 正解

**判定: PASS（許容される揺れの範囲内を含め全採点基準を満たす）**

integrity_concern は期待の基本値 `false` に対し `true` だが、ケース自身の「許容される判定の揺れ」が定める条件（訂正情報を確認せず公開し続けることの具体的な害の経路を説明し、かつ著者の研究不正やブログ執筆者の意図的欺瞞を断定しない）を正確に満たしており、明示的に許容される変動として正解と判定する。baseline（no-skill）も同等の結論に到達しており、両者の判断は一致している。
