# Case 02: 抄録のみアクセス可能 / abstract-only access

## シナリオ分類

原論文の全文に到達できず、構造化抄録のみ確認できる状況。援用主張は抄録の記述と矛盾せず、対象集団も同一（射程移送なし）だが、`source_access` が `full_verified` に満たないため、`citation_support` の肯定的な値（`direct` / `qualified`）を付けてはならないケース。非対称ゲートが正しく機能するかを検証する。

## 入力

- 実行モード: `standard`
- 援用したい主張: 「8週間の有酸素運動プログラムに参加した中高年成人は、参加しなかった群と比較して安静時収縮期血圧が平均6mmHg低下した」
- 参照元: 架空の論文『Sawada R, et al. "Aerobic Exercise and Resting Blood Pressure in Middle-Aged and Older Adults." Journal of Preventive Cardiology Reports, 2019; 33(2): 88-95. (架空の文献。全文は入手できず、以下の構造化抄録のみが確認可能)』
- 想定読者・利用目的: 一般公開（健康情報ブログへの引用を想定）

## 利用可能な資料

### 資料A: 構造化抄録（これが唯一入手可能な資料であり、全文・図表・補足資料には一切アクセスできない）

> **Background**: 有酸素運動が血圧に与える影響については先行研究間で効果量にばらつきがある。
>
> **Methods**: 45〜70歳の成人180名を対象に、8週間の監督下有酸素運動プログラム群（n=90）と非介入対照群（n=90）を比較した非盲検並行群間比較試験。
>
> **Results**: 介入群の安静時収縮期血圧は対照群と比較して平均6mmHg有意に低下した（群間差6mmHg、p=0.02）。
>
> **Conclusions**: 8週間の有酸素運動プログラムは中高年成人の安静時収縮期血圧を低下させうる。
>
> （注: この抄録は書誌情報の一部として著者名・掲載誌・巻号は確認できているが、方法の詳細（除外基準、脱落率、群間差の信頼区間、統計手法の詳細）、限界の記述、訂正・懸念表明・撤回の有無は、全文にアクセスできないため確認できていない。）

## 期待される判定

### 命題 C1

「8週間の有酸素運動プログラムに参加した中高年成人は、参加しなかった群と比較して安静時収縮期血圧が平均6mmHg低下した」

- citation_support: `unverifiable`
- transfer_status: `no_transfer`
- source_access: `abstract_only`
- reasoning_type: 該当なし
- confidence: 低〜中
- integrity_concern: `false`

主張は抄録の記述（対象年齢、8週間、6mmHg低下、有意差）と表面上は一致しているが、全文にアクセスできず、除外基準・脱落率・限界の記述・訂正情報を確認できないため、`direct` や `qualified` のような肯定的な `citation_support` を付ける根拠がない。矛盾する明白な手がかりもないため `overextended` / `contradicted` にもならず、`unverifiable` が正しい。対象集団自体は変更されていないため `transfer_status` は `no_transfer` のままでよい（`source_access` の不足は `transfer_status` の非対称ゲートには影響しない。ここでは移送そのものが発生していないため）。

## 許容される判定の揺れ

- confidence は「低」「中」のいずれでも許容する。
- missing_evidence の具体的な文言に揺れがあっても、「全文・除外基準・脱落率・限界・訂正情報が未確認」という趣旨が含まれていれば許容する。

## 検出すべき推論タイプ

- なし。本ケースは推論の格上げではなく、資料アクセス制約に対するゲートの正しい適用を見る。

## 主張してはいけないこと

- 「原論文はこの効果を十分な根拠とともに支持している」という、全文未確認のまま肯定的な保証を与える主張。
- 「抄録に限界の記述がないため、限界はなかった」という、記述の欠如を証拠の欠如と同一視する主張（厳守事項に抵触する）。
- citation_support を `direct` または `qualified` とする判定（非対称ゲート違反）。

## 採点基準（grader criteria）

- [ ] citation_support が `direct` または `qualified` と判定された場合は不正解とする。これが本ケースの中心的な検証点であり、`source_access: abstract_only` から肯定的な `citation_support` を付けてはならないという非対称ゲートの検証を意味する。
- [ ] citation_support が `overextended` または `contradicted` と判定された場合も不正解とする。抄録の記述と主張の間に明白な矛盾や格上げの手がかりがないため、この場合は `unverifiable` が唯一の正しい値である。
- [ ] source_access が `abstract_only` 以外に判定された場合は不正解とする。
- [ ] transfer_status が `no_transfer` 以外に判定された場合は不正解とする。対象集団に変更がないため。
- [ ] 出力が「抄録の記述から十分に支持される」「原研究はこの主張を裏付けている」のような、全文未検証のまま肯定的保証を与える文言を含む場合は不正解とする。
