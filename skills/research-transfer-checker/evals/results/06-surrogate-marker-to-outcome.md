# Case 06 結果: 代理指標から実体的な結果への格上げ / surrogate-marker-to-outcome

ケース定義: `../06-surrogate-marker-to-outcome.md`

## Baseline（no-skill）transcript

この主張は受け入れられません。要修正、というより実質リジェクトです。

論文は「薬剤ZがLDLコレステロールを24週で下げた」という代理指標のRCTであり、心筋梗塞・脳卒中・心血管死といった臨床イベントは評価項目にも追跡対象にも含まれていません。それにもかかわらず「心筋梗塞を減らせる」という臨床アウトカムの主張をしているので、これは典型的な代理指標から臨床アウトカムへの飛躍です。

さらに悪いことに、著者自身が限界の項でわざわざ「代理指標の改善が臨床アウトカムの改善に直結するとは限らない」「過去に代理指標が改善しても臨床イベントが減らなかった、あるいは増加した例がある」と明記し、結論でも「臨床アウトカムへの効果は今回の試験デザインでは評価できない」と釘を刺しています。

言えるのは「薬剤ZはLDLコレステロールを有意に低下させた（群間差35mg/dL, p<0.001）」までで、「心筋梗塞を減らせる」は言えません。この点はかなり確信を持って言えます。

## With-skill transcript（standard モード）

```markdown
## Research Transfer Check

### 判定サマリー
- citation_support: contradicted 1件
- transfer_status: not_established 1件
- integrity_concern: true
- 最も重大な問題: 援用主張は、原論文が明示的に「証明するものではない」と述べている心血管イベント（心筋梗塞）の減少を、そのまま起きたことのように断定している。

#### C1
- citation_support: contradicted
- transfer_status: not_established
- source_access: full_verified
- confidence: 高
- integrity_concern: true
- reasoning_type: 代理指標から実体
- 問題のある推論箇所: 原論文の限界セクションは「本試験は代理指標(LDLコレステロール)を評価したものであり、心筋梗塞や脳卒中などの実際の心血管イベントの減少を証明するものではない」と明記している。心血管イベントは本試験の評価項目に含まれておらず、追跡もしていない事実に明示的に言及。
- corrected_claim: 「薬剤Zは24週間のRCTで、LDLコレステロール値を有意に低下させた（群間差35mg/dL、p<0.001）。ただし、この試験は心筋梗塞などの心血管イベントを評価項目としておらず…」
```

## 採点

**期待される判定**: citation_support `overextended`（`contradicted`も許容）/ transfer_status `no_transfer`（`not_established`等も reasoning_type が伴えば許容）/ reasoning_type `代理指標から実体`。

**採点基準チェック**:
- [x] citation_support は `direct`/`qualified` ではない（`contradicted`、許容範囲内）— 正解
- [x] transfer_status は `justified` ではない（`not_established`）— 正解
- [x] reasoning_type に「代理指標から実体」を含む — 正解
- [x] 「心筋梗塞を減らす」を支持する文言なし — 正解
- [x] 心血管イベントを測定・追跡していない事実への言及あり — 正解

**判定: PASS（全採点基準を満たす）**

明示的な採点基準はすべて満たした。integrity_concern は期待値 `false` に対し `true` と判定しており（採点基準には含まれない項目だが）、この一点は期待される判定からの乖離として記録しておく。
