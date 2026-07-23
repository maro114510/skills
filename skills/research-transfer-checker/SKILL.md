---
name: research-transfer-checker
description: >
  研究結果を別の対象・集団・制度・時代・概念・政策判断へ援用する主張について、
  原研究の射程、推論の飛躍、橋渡し根拠、社会的リスクを検査するスキル。
  「この論文からこの主張を言えるか」「研究結果を別分野へ応用してよいか」
  「相関を因果として扱っていないか」「動物研究を人間へ一般化できるか」
  「この引用は原論文に忠実か」「エビデンスの援用範囲を確認して」
  「研究を政策・教育・採用・医療・報道に使ってよいか」といった依頼で使う。
  研究不正や倫理違反を断定せず、根拠の強さと深刻な誤導リスクを分けて報告する。
allowed-tools: AskUserQuestion, Read, Glob, Grep, WebFetch, WebSearch
---

# research-transfer-checker

研究結果の援用が原研究の射程内にあるかを検査する。目的は、主張の真偽を最終決定することではなく、原研究から援用主張へ至る推論を監査可能にすることである。

## 厳守事項

- `citation_support` の `direct`・`qualified`、`transfer_status` の `justified` は、全文を検証できた資料（`source_access: full_verified`）からしか付けない。抄録や二次資料だけでこれらの肯定的な値を付けない。
- ただし、資料の記述が主張と明確に矛盾する、または格上げが明確に読み取れる場合は、全文がなくても `citation_support: overextended` / `contradicted`、`transfer_status: not_established` を付けてよい。
- 全文の一部だけを確認できない場合は、確認できない部分だけを `unverifiable` / `not_assessed` とする。他の軸や他の命題は確認できた範囲で通常どおり判定し、ケース全体を検証不能として扱わない。
- 肯定的な値を真実の保証、否定的な値を虚偽の断定として扱わない。
- 研究不正、倫理違反、差別意図、著者や援用者の動機を推定しない。
- 追加探索で根拠が見つからなくても、根拠が存在しないと断定しない。「今回の探索範囲では確認できない」と書く。
- 学術的・倫理的・法的な最終判断と公開可否は、人間の専門家へ委ねる。
- 規範名を権威づけに使わない。対象研究に適用でき、実際に判断へ使った規範だけを挙げる。

## Step 1. 入力を確定する

次の入力を解決する。

- 援用したい主張
- 参照元の原論文、記事、URL、DOI、またはローカルファイル
- 任意情報: 想定読者、利用目的、対象領域

主張または参照元を特定できない場合だけ質問する。想定読者などの任意情報がなければ、一般公開を想定して検査し、その前提を出力する。

「すべて」「常に」「誰でも」などの全称表現や、例外を示さない一律の制度提言は、暗黙に「該当職種だけ」などの狭い対象へ読み替えない。文言どおりの広い射程で検査し、その解釈を出力する。複数の解釈で判定が変わる場合だけ対象範囲を質問する。

義務化、禁止、除外を含む提言では、誰が誰に何を課すか、対象法域、例外、強制手段を入力から抽出する。未指定の要素を発明せず、対象全体へ一律に課す一般的な拘束規則として検査し、その解釈と法的妥当性を評価していないことを出力する。強制主体などの違いで援用判定が変わる場合だけ質問する。

記事やレビュー論文が実証研究を引用している場合は、その引用元の原論文までたどる。題名、著者、掲載誌、年、DOI などを照合し、同名資料やプレプリントと査読版を取り違えない。

## Step 2. 資料を検証する

ローカルファイルは `Read`、URL は `WebFetch`、DOI や書誌情報の探索は `WebSearch` を使う。参照した資料それぞれについて、`references/decision-rubric.md` の基準で `source_access` を判定する。

1. 全文と、判定に必要な表・図・補足資料を読める。
2. 資料を一意に特定できる。公開物では著者、題名、年、掲載元、DOI または安定したURLを照合する。未公開資料では著者または作成組織、題名、日付、版を確認する。
3. 公開物では出版社や著者の訂正、懸念表明、撤回通知、査読版の更新を確認できる。

1〜3をすべて満たせば `full_verified`、全文は読めるが2または3を確認できなければ `full_unverified` とする。全文を読めず、抄録・構造化抄録のみ読めれば `abstract_only`、レビューや記事などの二次資料の記述からしか確認できなければ `secondary_only`、資料そのものにアクセスできなければ `unavailable` とする。

ユーザーが「全文」と呼んでいても、Methods、Results、Limitations などを抜き出した要約、構造化抄録、一部の貼り付けは全文とみなさない。公開物の書誌情報がない場合や、未公開資料の来歴を確認できない場合は `full_verified` にしない。引用箇所は、ページ、節、表、図のいずれかで再特定できる範囲を「原研究との対応」に明記する。特定できない箇所はその旨を書く。

`source_access` が `full_verified` に満たない場合でも、判定を一律に止めない。Step 7 の非対称ゲートに従い、確認できた範囲で `citation_support` と `transfer_status` を判定し、確認できない部分だけを `unverifiable` / `not_assessed` とする。二次資料を使う場合は、原論文の結論と限界を正確に伝えているかを、その二次資料自身の記述の範囲で確認する。原研究本体と橋渡し資料など複数の資料を使う命題では、`source_access` を軸ごとに判定する。橋渡し資料が弱くても、原研究本体が `full_verified` であれば `citation_support` の判定は制限しない。

資料に一切アクセスできない場合（`source_access: unavailable`）は、その資料に依存する軸の `integrity_concern` を `判定保留` とする。暫定所見に明白な本質化や排除の危険がある場合は、その表現と予見できる害を示す。ただし、原研究を歪めているとの判定はしない。

## Step 3. 主張と原研究を同じ粒度にする

援用主張を、個別に真偽条件を持つ原子的な命題へ分解する。特に次を分離する。

- 経験的主張と価値判断
- 集団平均と個人についての主張
- 記述、予測、因果説明、規範的提言
- 複数の対象集団、制度、時代、文化についての主張

原論文から次の研究プロファイルを作る。本文にない情報を推測で補わない。

| 項目 | 抽出内容 |
|---|---|
| 研究課題 | 著者が実際に検証した問い |
| デザイン | 実験、観察、事例、質的研究、レビューなど |
| 対象 | 種、集団、標本、選定条件、除外条件 |
| 文脈 | 文化、地域、時代、制度、実施環境 |
| 操作 | 介入または曝露、比較対象、測定方法 |
| 結果 | 評価項目、効果量、区間推定、主要な不確実性 |
| 限界 | 著者が述べた限界と、方法から直接確認できる制約 |
| 結論 | 著者の結論を確実性の表現を保って要約したもの |

## Step 4. 推論を検査する

`references/decision-rubric.md` を読み、各命題について次を検査する。

1. 結論、対象、方法、限界、確実性を正しく引用しているか（`citation_support` の基礎）。
2. 種、集団、個人、文化、時代、制度、概念をまたいでいるか（`transfer_status` の基礎）。
3. 相関を因果、示唆を証明、事例を一般則、事実を規範へ格上げしていないか（`citation_support` を下げる要因であり、`reasoning_type` に記録する）。
4. 移送を支える比較研究、再現研究、理論、測定同等性、外的妥当性の根拠、価値前提があるか（`transfer_status` の基礎）。
5. 属性の本質化、個人への機械的適用、偏見、排除、不利益な制度判断を正当化していないか（`integrity_concern` と社会的リスクの基礎）。

本文の著者主張と、この検査で導く方法上の評価を区別する。著者が限界を書いていないこと自体を、限界がない証拠として扱わない。

## Step 5. 橋渡し根拠を探索する

命題の `transfer_status` が `no_transfer` でない場合だけ、移送先と移送元を直接比較する一次研究、再現研究、体系的レビュー、妥当な理論を対象を絞って探す。主張を支持する資料だけでなく、反証または境界条件を示す資料も探す。

判定に影響させる橋渡し資料ごとに、Step 2 と同じ基準で `source_access` を判定する。`full_verified` の資料だけを `transfer_status: justified` の根拠にする。確認を完了できない資料は「未確認」として探索結果から区別し、`justified` への格上げには使わない。反証や境界条件を示す資料は、`full_verified` でなくても `not_established` の根拠に使ってよい。

探索日、使用した検索語、確認した情報源の種類を記録する。この探索は体系的レビューではない。網羅性が必要な依頼では、このスキルの判定と分けて体系的レビューを提案する。

## Step 6. 規範を選ぶ

`references/standards-map.md` を読み、研究デザインと利用目的に合う規範だけを選ぶ。公式ページで現行版と適用範囲を確認する。

- ALLEA と日本学術会議の規範は、正確な伝達と社会的責任を検討する共通基盤として使う。
- AERA は経験的社会科学にだけ使う。
- ARRIVE は生体を用いた動物研究の報告充足性を確認する場合だけ使う。
- 医療、心理、教育などに分野固有の指針がある場合は、公式の発行主体から確認して追加する。

規範が援用の可否を直接定めていない場合は、その規範から結論を導かない。どの条項を何の判断に使ったかを明記する。

## Step 7. 判定する

各原子的命題へ次の2軸を独立に付ける。

- `citation_support`: `direct` / `qualified` / `overextended` / `contradicted` / `unverifiable`
- `transfer_status`: `no_transfer` / `justified` / `plausible_but_uncertain` / `not_established` / `not_assessed`

`references/decision-rubric.md` の非対称ゲートに従う。`citation_support` は原研究本体の `source_access`、`transfer_status` の `justified` は橋渡し資料の `source_access` を基準に、軸ごとに判定する。基準とする資料の `source_access` が `full_verified` に満たない場合（`full_unverified`・`abstract_only`・`secondary_only`・`unavailable`）、その軸に `citation_support` の `direct` / `qualified`、または `transfer_status` の `justified` を付けない。ただし、資料の記述が主張と明確に矛盾する、または格上げが明確に読み取れる場合は、全文がなくても `citation_support: overextended` / `contradicted`、`transfer_status: not_established` を付けてよい。

全文の一部だけを確認できない場合は、確認できない部分だけを `unverifiable` / `not_assessed` とし、確認できた軸・他の命題は通常どおり判定する。ケース全体を検証不能として扱わない。

各命題にはさらに次を付ける。

- `source_access`: この命題の判定に使った資料の取得状況
- `confidence`: 高 / 中 / 低
- `missing_evidence`: 判定を確定するために不足している資料や、確認できなかった部分。なければ「該当なし」
- `reasoning_type`: 検出した推論の格上げまたは射程移送の分類。なければ「該当なし」
- `corrected_claim`: 原研究の確実性と射程を保った修正文。修正しても支えられない命題は削除を提案する

`integrity_concern` は両軸と独立した警告として `true` または `false` を付ける。重大な誤導や社会的害の現実的な経路があり、かつ選択的引用、重大な限界の脱落、属性の本質化などの具体的な問題を特定できる場合だけ `true` にする。単なる根拠不足、論争的な題材、政治的な敏感さだけでは `true` にしない。資料に一切アクセスできない場合は `判定保留` とする。

複数命題の結果は件数と最も重大な問題を要約する。最悪値だけを全体判定として表示しない。

## Step 8. 出力する

```markdown
## Research Transfer Check

### 対象
- 援用したい主張:
- 参照元:
- 想定読者・利用目的:

### 資料の取得状況
- <資料名>: full_verified / full_unverified / abstract_only / secondary_only / unavailable

### 判定サマリー
- citation_support: direct N件 / qualified N件 / overextended N件 / contradicted N件 / unverifiable N件
- transfer_status: no_transfer N件 / justified N件 / plausible_but_uncertain N件 / not_established N件 / not_assessed N件
- integrity_concern: true / false / 判定保留
- 最も重大な問題:

### 命題別の検査

#### C1. <原子的な命題>
- citation_support: direct / qualified / overextended / contradicted / unverifiable
- transfer_status: no_transfer / justified / plausible_but_uncertain / not_established / not_assessed
- source_access（citation_support の根拠資料）: full_verified / full_unverified / abstract_only / secondary_only / unavailable
- source_access（transfer_status の根拠資料）: full_verified / full_unverified / abstract_only / secondary_only / unavailable / no_transfer のため該当なし
- confidence: 高 / 中 / 低
- integrity_concern: true / false / 判定保留
- 問題のある推論箇所: <該当なし、または具体的な文言>
- reasoning_type: <該当なし、または分類>
- 原研究との対応: <本文のページ・節・表・図を示す。全文未確認の場合は確認できた範囲を示す>
- missing_evidence: <該当なし、または不足している根拠・未確認の部分>
- 社会的リスク: <具体的な害の経路。該当しなければ「特記なし」>
- corrected_claim: <確実性と射程を保った修正文。修正しても支えられない場合は削除を提案>

### 追加探索
- 探索日:
- 検索範囲:
- 確認できた支持・反証・境界条件:
- 限界: 対象を絞った探索であり、根拠の不存在を証明するものではない

### 参照した規範・報告基準
- <名称・版・適用した節>: <この検査で使った理由>

### レビュー上の留保
この結果は研究不正や倫理違反を認定するものではない。学術的・倫理的・法的な最終判断と公開可否は、対象分野の専門家が原資料を確認して決定する。
```

特定の軸や命題の一部だけを確認できない場合も、上記の様式でそのまま出力し、確認できない軸だけを `unverifiable` / `not_assessed` とする。2つの `source_access` が異なる場合も両方をそのまま出力し、弱い方の資料に依存しない軸の値を巻き込んで制限しない。資料に一切アクセスできず、すべての命題ですべての軸が判定不能になる場合だけ、命題別の検査を省略し、確認できた書誌情報、不足資料、検証再開に必要な情報、主張自体から予見できる暫定的な社会的リスクを出力する。
