# Case 05 結果: 集団平均から個人への判断 / group-average-to-individual judgment

ケース定義: `../05-group-to-individual.md`

## Baseline（no-skill）transcript

この主張は論文からそのまま導けないので、そのままでは受け入れられません。書き直しを求めるか、事実上棄却すべきレベルだと思います。

理由は単純です。論文が示しているのはクラス単位の集団平均の差（A: 72.5点 vs B: 67.1点、p=0.01）であって、個々の生徒にとってどちらの指導法が有効かを予測するための研究ではありません。しかも著者自身が「両群の得点分布は大きく重なっており、B群の生徒の約4割はA群の中央値を上回っている」「個人差の方が指導法の違いより大きい」「個人レベルの効果予測には別の研究が必要」とはっきり書いています。主張はまさにその禁止事項をやってしまっている、典型的な生態学的誤謬です。

なので判断としては「A塾方式の方が集団平均としてはやや高い傾向がある、という程度までは言えるが、この生徒個人に当てはめて成績向上を保証する根拠にはならない」に書き換えるべきです。この点は結構自信を持って言えます。論文の「限界」節がほぼそのまま反証になっているので。

## With-skill transcript（standard モード）

```markdown
## Research Transfer Check

### 判定サマリー
- citation_support: qualified 1件 / overextended 1件 / contradicted 1件
- transfer_status: not_established 2件 / not_assessed 1件
- integrity_concern: true

#### C1（研究によればA方式の生徒群はB方式の生徒群より平均点が高かった）
- citation_support: qualified
- transfer_status: not_assessed
- source_access（transfer_status の根拠資料）: unavailable
- 問題のある推論箇所: 「A塾方式」を原論文の「指導法A(演習中心型)」とそのまま同一視している。原論文は学校の授業内における指導法比較であり、学習塾という別の運営主体・学習環境における指導との対応関係は原論文からは確認できない。加えて、著者が明記した「両群の得点分布は大きく重なる」という限定情報を省いたまま平均差だけを提示している。

#### C2（この生徒個人も、A方式にすれば成績が上がるはずだ）
- citation_support: contradicted
- transfer_status: not_established
- reasoning_type: 集団から個人
- integrity_concern: true

#### C3（この生徒はB塾ではなくA塾の学習方法を使うべきだ）
- citation_support: overextended
- transfer_status: not_established
- reasoning_type: 記述から規範
```

## 採点

**期待される判定**: C1（集団平均の記述） = `direct`+`no_transfer`（必須）／C2（個人への適用） = `overextended`/`unverifiable` + `not_established` + reasoning_type `集団から個人`。

**採点基準チェック**:
- [x] C2 の transfer_status = `not_established` — 正解
- [x] C2 の citation_support は `direct`/`qualified` ではない — 正解
- [x] reasoning_type に「集団から個人」を含む — 正解
- [x] 分布の重なりに言及 — 正解（望ましい要素として満たしている）
- [ ] C1（集団平均の記述そのもの）が `direct` かつ `no_transfer` と判定されていない場合は不正解 → **不正解**（C1 = `qualified`+`not_assessed`）

**判定: FAIL**

C2（個人への機械的適用の拒否、`集団から個人` の検出）は模範解答どおり正確に検出できている。しかし C1 は、主張文の「A塾方式」という通称的な言い回しを、原論文の「指導法A（演習中心型、学校クラス内）」と厳密に同一視できるかという、本ケースが意図していない曖昧さを自ら創出し、`qualified`＋`not_assessed`（原研究との対応関係が「unavailable」）へ格下げした。これは Case 01・03 と同系統の**過剰な慎重さによる誤検出**であり、素の baseline 判断（C1相当部分を明確に集団平均の事実として受理している）よりもかえって保守的になっている。
