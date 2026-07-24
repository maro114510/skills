# Case 02 結果: 抄録のみアクセス可能 / abstract-only access

ケース定義: `../02-abstract-only-access.md`（非対称ゲートの検証。期待判定は `citation_support: unverifiable`）

## Baseline（no-skill）transcript

この主張は、抄録に書かれている結果とほぼそのまま一致しています。「8週間の有酸素運動プログラム群 vs 非参加(対照)群で収縮期血圧が平均6mmHg低下」という数字も方向性も、Results欄の「群間差6mmHg、p=0.02」を素直に言い換えたものなので、少なくとも「この論文がそう言っている」という意味では問題なく受け入れられます。

ただ、この結果一つをもって断定的に信じていいかというと、いくつか気になる点があります。まず非盲検(オープンラベル)の並行群間比較試験なので、血圧測定時に評価者や被験者本人の期待が結果に影響するバイアスを排除できていません。次にn=90×2群という中規模の単一施設・単一試験の結果であり、信頼区間や脱落率、除外基準が抄録だけでは分からないため、6mmHgという点推定値の頑健さは評価しづらいです。p=0.02は有意ではありますが、それほど強い証拠水準でもありません。

主張自体の文言は誇張していないので「そのまま受け取っていい」レベルですが、これを一般化して臨床的推奨の根拠として使うなら、単一のオープンラベル試験だけでは心もとなく、他の研究との整合性や追試の有無を確認したいところです。

結論としては、この一文単体としては受理可能、ただし一般化・引用する際は「単一の非盲検試験の結果」という限定を添えるべきだと感じます。確信度は中程度です。

## With-skill transcript（standard モード）

```markdown
## Research Transfer Check

### 対象
- モード: standard
- 援用したい主張: 「8週間の有酸素運動プログラムに参加した中高年成人は、参加しなかった群と比較して安静時収縮期血圧が平均6mmHg低下した」
- 参照元: Sawada R, et al. (2019)（全文未入手、構造化抄録のみ）

### 資料の取得状況
- Sawada R, et al. (2019) 構造化抄録: abstract_only

### 判定サマリー
- citation_support: overextended 1件
- transfer_status: no_transfer 1件
- integrity_concern: false
- 最も重大な問題: 著者自身の結論は「低下させうる（may reduce）」という留保付きだが、援用主張はこれを断定表現「低下した」に格上げしたうえ、単一の非盲検試験1件の結果であることを示さずに「中高年成人」全般についての既定事実として提示している。

#### C1
- citation_support: overextended
- transfer_status: no_transfer
- source_access: abstract_only
- confidence: 中
- integrity_concern: false
- 問題のある推論箇所: 「参加しなかった群と比較して...低下した」という無留保の断定。抄録のConclusionsは「低下させうる」と可能性表現を用いているのに対し、援用主張はこの留保を落とし確定表現へ格上げしている。
- reasoning_type: 示唆から証明（著者の「し得る」という可能性の表現を、援用主張が「低下した」という確定表現へ格上げしている。全文がなくても、この格上げは抄録のConclusions本文との対比から明確に読み取れるため、非対称ゲートの例外に該当する）
- missing_evidence: 信頼区間、除外基準、脱落率、統計手法の詳細、限界の記述、訂正・懸念表明・撤回の有無。
```

## 採点

**期待される判定**: citation_support `unverifiable` / transfer_status `no_transfer` / source_access `abstract_only`。

**採点基準チェック**:
- [ ] citation_support が `overextended` または `contradicted` と判定された場合は不正解 → **不正解**（`overextended`）。抄録の記述と主張の間に明白な矛盾や格上げの手がかりがないため `unverifiable` が唯一の正解値、という本ケースの中心的な検証点。
- [x] source_access が `abstract_only` — 正解
- [x] transfer_status が `no_transfer` — 正解

**判定: FAIL**

スキルは、抄録の結論文が「低下させうる（may reduce）」という可能性表現である点を突き、援用主張の断定表現「低下した」との間に "示唆から証明" の格上げがあると解釈して `overextended` を付けた。表現の強さに差があること自体は事実だが、本ケースの基準では、全文にアクセスできない状況でこの程度の言い切りの強さの違いだけを根拠に矛盾（`overextended`/`contradicted`）と判定することはできず、`unverifiable` に留めるべきである。抄録の結論文における "may reduce" 的な慎重な結語は医学論文の抄録では一般的な作法であり、本文の断定度と必ずしも一致しないため、この差だけでは明白な格上げの手がかりとは言えない。スキルはこの点を過度に重く解釈した。

これは Case 01 と同様の**過剰検出（false rejection 寄りの誤り）**であり、非対称ゲートが「肯定判定を防ぐ」目的では機能した一方、「根拠不足のときは `unverifiable` に留める」という消極的判断の使い分けには失敗した。
