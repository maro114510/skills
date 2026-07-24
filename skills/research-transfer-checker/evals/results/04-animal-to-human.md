# Case 04 結果: 動物実験からヒトへの一般化 / animal-to-human generalization

ケース定義: `../04-animal-to-human.md`

## Baseline（no-skill）transcript

この主張は却下すべきです。論文はマウス異種移植モデルでの前臨床試験であり、著者自身が「ヒトでの薬物動態・代謝・毒性は未検討」「ヒトでの有効性・安全性を保証しない」「臨床応用には薬物動態試験・毒性試験・第I相試験が必要」と明記しています。結論も「さらなる前臨床・臨床段階の検証が必要」としており、主張は論文の結論と正反対の方向に飛躍しています。

推論上の問題は、動物実験（それも免疫不全マウスへの異種移植というかなり人工的な系）の結果を、種の壁（マウスとヒトで肝代謝酵素の発現が大きく異なる、と論文自体が指摘）を無視していきなりヒト患者への投与という臨床判断に直結させている点です。腫瘍が縮小したという有効性のシグナルだけを取り出し、安全性・毒性・用量設定・薬物動態という臨床導入に不可欠な要素を完全に飛ばしています。

確信度は高いです。論文の「限界」節と「結論」節が主張と真っ向から矛盾することが明記されており、解釈の余地がほとんどありません。修正を求めるレベルではなく、この主張はそのままでは受け入れられない（却下）と判断します。

## With-skill transcript（standard モード）

```markdown
## Research Transfer Check

### 判定サマリー
- citation_support: qualified 1件 / contradicted 1件
- transfer_status: no_transfer 1件 / not_established 1件
- integrity_concern: true

#### C1（マウスでの所見）
- citation_support: qualified
- transfer_status: no_transfer
- reasoning_type: 該当なし
- 問題のある推論箇所: 主張中の「腫瘍縮小効果」という表現。原論文の結果は群間比較による増殖抑制（投与群180mm³ vs 対照群520mm³）であり、投与群自体の腫瘍が経時的に縮小（退縮）したことを示すデータ（ベースライン比較）は本資料からは確認できない。「縮小」は「抑制」より強い含意を持ちうるため限定語を補う必要がある。

#### C2（ヒトへの投与推奨）
- citation_support: contradicted
- transfer_status: not_established
- reasoning_type: 記述から規範／種の複合
- integrity_concern: true
- 問題のある推論箇所: 「医師は今すぐ…投与すべきだ」という規範的結論は、原論文の限界節が明記する「ヒトでの薬物動態・代謝・毒性は未検討」等と直接矛盾する。
```

## 採点

**期待される判定**: C1 = `direct`+`no_transfer`（必須）／C2 = `overextended`または`unverifiable`（`direct`/`qualified`は不正解）+`not_established`+reasoning_type `種`。

**採点基準チェック**:
- [x] C2 の transfer_status = `not_established` — 正解
- [x] C2 の citation_support は `direct`/`qualified` ではない（`contradicted`。ケースの「許容される揺れ」は`overextended`/`unverifiable`のみを明示するが、採点基準の文言は「`direct`または`qualified`のときのみ不正解」なので、`contradicted`はこの基準を字義通り満たす）— 正解
- [x] reasoning_type に「種」を含む — 正解
- [x] 「今すぐ投与すべき」を支持する文言なし — 正解
- [ ] C1 が `direct` かつ `no_transfer` と判定されていない場合は不正解 → **不正解**（C1 = `qualified`）

**判定: FAIL（軽微）**

主要な検証点（C2 のヒトへの飛躍の拒否、`種` の検出、投与推奨の明確な却下）はすべて正しく捉えている。唯一の失敗は、C1（マウスでの所見そのもの）に対して「腫瘍縮小」対「腫瘍増殖抑制」という原論文の用語との微妙な違いを理由に `qualified` を付けたこと。これは他の false-rejection 事例（Case 01, 03, 05）ほど恣意的な曖昧さの創出ではなく、より字義通りの厳密さに基づく判定だが、本ケースが「マウス実験の記述自体は正確に支持されるべき」という前提で設計されている以上、`direct` を要求する採点基準には反する。integrity_concern は期待値 `false` に対し `true` — 具体的な害の経路（安全性未確認のまま投与を要求する患者向け記事）を説明しており、許容の余地はあるが期待値とは異なる。
