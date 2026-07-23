# Evidence Workflow

## 目次

1. 執筆設計
2. 成果物ごとの完成条件
3. Evidence Map
4. 情報源の扱い
5. 射程移送の検出
6. 独立検査
7. 判定と公開ゲート
8. 停止条件
9. 最終検証

## 執筆設計

Evidence Mapを作る前に、次の骨格を仮置きする。
これは根拠の確認前に結論を固定する手順ではなく、何を検証すべきかを決めるための設計である。

| モード | 主な成果物 | 必須の品質軸 |
|---|---|---|
| 調査レビュー | 文献レビュー、制度調査、証拠整理 | 探索範囲、採用・除外、証拠強度、反証、限界 |
| 分析・モデル文書 | 機構モデル、比較分析、Argument Map | 既存Claimとの整合、成立条件、代替説明、反証可能性 |
| 公開記事 | 解説記事、連載記事 | 想定読者、問いと答え、説明順序、図表、読みやすさ |

### 執筆前の承認

Evidence Mapの初期版を作った後、次の4要素を一つのレビュー単位として提示する。

```markdown
## 共通の執筆設計
- 成果物種別:
- 想定読者:
- 読者が解決できる問い:
- 現時点での答え:
- 作業仮説または中心命題:
- 主要主張:
- 最も強い反論:
- 対象外:
- 構成案:
- Issue受け入れ条件との対応:

## 成果物固有の判断
- <下記のモード別項目>:

## 根拠の状態
- 既存資料で支持できる主張:
- 追加調査が必要な主張:
- 反証・境界条件:
- 射程移送の候補と検査状態:
- 未解決の問題:

## 確認が必要なClaim
| claim_id | claim | role | citation support | source | citation access | transfer access | scope | 予定処置 |
|---|---|---|---|---|---|---|---|---|
```

「成果物固有の判断」には次を含める。

| モード | 承認する判断 |
|---|---|
| 調査レビュー | 探索範囲、採用・除外基準、網羅性を主張する範囲 |
| 分析・モデル文書 | 分析単位、成立・遮断条件、代替説明、反証条件 |
| 公開記事 | 説明順序、図表計画、専門語と読みやすさの方針。図表なしの場合は読者理解と受け入れ条件に照らした理由 |

Evidence Map全文は貼らない。次のClaimだけを「確認が必要なClaim」へ抜粋する。

- 中心命題
- `citation_support`が`pending`、`overextended`、`contradicted`、`unverifiable`の主要主張
- 文言、状態、適用範囲を変更するClaim

抜粋した各Claimには、追加調査、限定、未検証仮説として保持、削除のどれを予定するかを書く。
確立済みの事実として扱わない。

## 成果物ごとの完成条件

### 調査レビュー

- 調査質問、対象範囲、情報基準日を特定できる。
- 検索語、探索先、採用・除外理由を追跡できる。
- 支持証拠だけでなく、反証、境界条件、研究上の限界を含む。
- 系統的レビューでない場合は網羅性を主張しない。
- 結論の確実性が、確認できた資料の強さを超えていない。

### 分析・モデル文書

- 既存の概念、Claim、分析単位を勝手に再定義していない。
- 因果を示す矢印ごとに、成立条件、遮断条件、代替説明を示す。
- 観測済みの事実、既存研究からの推論、未検証仮説を区別する。
- 中心命題を弱める反例と、モデルを改訂する条件を含む。
- 後続文書が再利用できる入力、出力、境界を明示する。

### 公開記事

- 想定読者が記事を読む前に持つ問いを特定できる。
- 冒頭で問いと記事が答える範囲を示す。
- 主要主張ごとに、読者が確認できる出典または上位文書への導線がある。
- 研究上の限定を落とさず、専門文書の構造をそのまま転記しない。
- 強い反論、適用範囲、記事が答えない問いを示す。
- 連載では前後の記事との重複と先取りを確認する。

## Evidence Map

既存のClaim Ledgerがある場合は、その語彙とIDを優先する。存在しない場合は次の項目を作業用の表として管理する。

| 項目 | 内容 |
|---|---|
| `claim_id` | 既存IDを優先する。なければ作業中に一意な安定IDを付ける |
| `claim` | 個別に真偽条件を持つ命題 |
| `claim_type` | `empirical` / `inference` / `normative` / `hypothesis` |
| `role` | `core` / `supporting` / `counterclaim` / `context` |
| `citation_source` | 原資料、上位文書、データと、確認したページ、節、表、図 |
| `transfer_source` | 橋渡し資料と確認箇所。移送なしは`not_applicable` |
| `citation_support` | `pending` / `direct` / `qualified` / `overextended` / `contradicted` / `unverifiable` |
| `citation_source_access` | `pending` / `full_verified` / `full_unverified` / `abstract_only` / `secondary_only` / `unavailable` |
| `transfer_scope` | `none`、または移送元から移送先 |
| `transfer_status` | `pending` / `no_transfer` / `justified` / `plausible_but_uncertain` / `not_established` / `not_assessed` |
| `transfer_source_access` | `pending` / `full_verified` / `full_unverified` / `abstract_only` / `secondary_only` / `unavailable` / `not_applicable` |
| `confidence` | 高 / 中 / 低 |
| `scope` | 対象、地域、制度、時代、条件 |
| `counterevidence` | 反証、境界条件、代替説明 |
| `freshness` | 資料の日付、確認日、更新が必要になる条件 |
| `integrity_concern` | `pending` / `true` / `false` / `判定保留` |
| `document_location` | 草稿中の節、段落、図表 |

1つの出典が複数の命題を支える場合も、命題を統合しない。主張の一部だけが未確認なら、確認できない部分を別命題に分ける。

### 正規化規則

1. 未評価の軸と資料アクセスは`pending`にする。`pending`は作業中だけ使用し、公開判断を必ずブロックする。
2. `transfer_scope: none`では`transfer_status: no_transfer`、
   `transfer_source_access: not_applicable`とする。移送があれば、独立検査が終わるまで両方を`pending`にする。
3. 原資料を確認した後、Checkerと同じ定義で`citation_support`と`citation_source_access`を更新する。
   資料確認とリスク検査が終わるまで`integrity_concern`は`pending`とし、完了後はCheckerと同じ定義で更新する。
4. Checkerを実行した場合は、`citation_support`、`transfer_status`、`integrity_concern`をそのまま転記する。
   2つの`source_access`はそれぞれ`citation_source_access`と`transfer_source_access`へ転記する。
   「no_transferのため該当なし」は`not_applicable`に正規化する。
5. 公開ゲートは上記の正規フィールドだけを使用する。別の状態値から公開可能な値を推測しない。

ファイルを変更する作業で永続的なClaim Ledgerがなければ、ユーザーの承認後から本文の初回保存前までに
対象文書と同じディレクトリへ`<document-stem>.evidence.md`を作り、Evidence Mapを保存する。
読み取り専用の設計・監査では作らない。追加探索を行った場合だけSearch Log、Checkerを実行した場合だけChecker Summaryを設ける。

## 情報源の扱い

### 優先順位

リポジトリ固有の調査規約があれば、それを優先する。規約がない場合は次の順を基本とする。

1. 原研究、法令、統計、契約書、仕様などの一次資料
2. 公的機関、学会、標準化団体の公式資料
3. 査読済みレビュー、体系的レビュー
4. 出典と方法が明示された業界調査
5. 信頼できる二次解説

検索スニペット、出典のない要約、生成文、転載元を確認できない図表は根拠にしない。

### 資料の確認

- 著者、題名、年、版、掲載元、DOIまたは安定URLを照合する。
- プレプリントと査読版、旧版と改訂版を区別する。
- 訂正、懸念表明、撤回、更新の有無を確認する。
- 全文を読めない資料では、確認できた範囲を明示する。
- 引用文は原文と照合し、ページ、節、表、図のいずれかで再特定できるようにする。
- 時点依存情報には情報基準日と再確認条件を付ける。

### 追加探索

追加探索は`citation_support: pending`または`unverifiable`を解消するために行う。
`overextended`を支える新しい根拠が必要な場合も追加探索の対象とする。
テーマ全体を最初から調べ直さない。探索では次を記録する。

- 探索日
- 検索語
- データベース、公式サイト、リポジトリ
- 採用した資料と理由
- 除外した資料と理由
- 確認できなかった範囲

既存のsearch logがない場合は、補助Evidenceファイルへ次の列で保存する。

| 項目 | 内容 |
|---|---|
| `searched_at` | 探索日 |
| `claim_id` | 解消しようとした証拠ギャップ |
| `query` | 実際に使用した検索語 |
| `venue` | データベース、公式サイト、リポジトリ |
| `candidate` | 確認した資料 |
| `decision` | `adopted` / `excluded` / `pending` |
| `reason` | 採用・除外・保留の理由 |
| `verified_location` | 確認したページ、節、表、図 |
| `citation_source_access` | Evidence Mapと同じ取得状況の列挙値 |
| `transfer_source_access` | Evidence Mapと同じ取得状況の列挙値。移送なしは`not_applicable` |

## 射程移送の検出

次のいずれかが変わる場合は、`transfer_scope`へ移送元と移送先を記録する。
この場合、`transfer_status`と`transfer_source_access`を`pending`にする。

| 軸 | 例 |
|---|---|
| 集団 | 特定職種の標本から全エンジニア |
| 個人 | 集団平均から個人の能力や処遇 |
| 地域・文化 | 米国の企業から日本企業 |
| 時代 | 過去の技術環境から現在のAI利用 |
| 制度 | 実験課題から雇用、契約、政策 |
| 概念 | Pull Request数から生産性 |
| 推論 | 相関から因果、事例から一般則、記述から規範 |

単に差があるだけで命題を棄却しない。差が結論へ影響する経路と、橋渡し根拠の有無を`research-transfer-checker`に検査させる。

## 独立検査

### Checkerへの入力

命題の原文、原資料の一意な識別情報、移送元と移送先、承認済みの読者、利用目的が
すべてそろった場合だけ、次のパケットを作る。欠けた値を作業説明から推定したり、
プレースホルダーで補ったりしない。不足項目を示し、入力がそろうまで検査と執筆を止める。

```text
Use $research-transfer-checker and return its defined report.

Claims:
- <claim id>: <verbatim claim>

Original sources:
- <claim id>: <URL, DOI, bibliographic identity, or local path>

Transfer:
- <claim id>: <source population/context> -> <target population/context>

Audience and use:
- <audience>
- <intended use>
```

### 実行条件

1. 親の会話履歴を継承しない新しいコンテキストを起動する。
2. 上記の生データとCheckerの使用指示だけを渡す。
3. Checker自身に原資料を確認させる。
4. Evidence Map、執筆設計、親の推論、期待判定、過去のChecker結果、無関係な草稿は渡さない。
5. 結果をEvidence Mapへ反映し、そのコンテキストは再利用しない。

Checkerによって承認済みの中心命題、読者、対象範囲、構成の変更が必要になった場合だけ、執筆設計を更新して再承認を得る。

## 判定と公開ゲート

Checkerの判定には次を反映する。

| 判定 | 必須対応 |
|---|---|
| `contradicted` | 命題を削除するか、原資料と整合する命題へ変更する |
| `overextended` | `corrected_claim`で救済できる場合だけ修正する。別の根拠が必要なら停止する |
| `qualified` | 対象、条件、効果、不確実性を本文へ残す |
| `plausible_but_uncertain` | 不確実な移送であることと不足する橋渡し根拠を明記する |
| `not_established` / `not_assessed` / `unverifiable` | 確立済みの事実として書かない |
| `integrity_concern: true` | 公開判断を止め、問題表現と予見できる害を示す |

分析・モデル文書では、未確立の命題を未検証仮説として明示できる。
中心命題として残す場合はユーザーの明示承認を得る。

各命題に`citation_support`、`transfer_status`、`citation_source_access`、`transfer_source_access`、`integrity_concern`を記録する。
公開判断では`pending`を残さない。

次の表を上から順に評価し、最初に該当する扱いを採用する。

| 優先 | 扱い | 条件 |
|---:|---|---|
| 1 | ブロック | いずれかの正規フィールドが`pending`、`citation_support: contradicted`、未修正の`overextended`、`integrity_concern: true`、または中心的な事実主張の`integrity_concern: 判定保留` |
| 2 | 公開文の事実主張 | `citation_support`が`direct`または`qualified`、`citation_source_access: full_verified`、`integrity_concern: false`であり、移送の組が`no_transfer`と`not_applicable`、または`justified`と`full_verified`である |
| 3 | 不確実性つきの事実主張 | 上記の引用支持と引用資料アクセスがあり、`transfer_status: plausible_but_uncertain`、`transfer_source_access`が`full_verified` / `full_unverified` / `abstract_only` / `secondary_only`のいずれか、`integrity_concern: false`で、未確定性と不足根拠を本文に残す |
| 4 | 仮説としてのみ保持 | 優先1に該当せず、`integrity_concern: false`で、`transfer_status`が`not_established`か`not_assessed`、または`citation_support: unverifiable`。事実や他の結論の根拠には使わない |
| 5 | 未解決としてブロック | 上記のどれにも該当しない |

「検査済み」は公開可能を意味しない。

## 停止条件

次の場合は本文の新規作成または公開判断を止める。

- 中心命題の`citation_support`が`pending`、`unverifiable`、`overextended`、`contradicted`のいずれかで、仮説への変更が承認されていない。
- 前提となる依存成果物が未完成である。
- Issueの要求と既存の調査規約、用語、証拠が両立しない。
- `integrity_concern: true`が未解決である。
- 想定読者、目的、対象範囲の違いによって結論または構成が変わるが、選択されていない。
- 調査が当初の問いを超えて体系的レビュー相当へ膨張している。

停止時は、問題のある命題、現在の根拠、選択肢、各選択肢が文書へ与える影響を示す。

## 最終検証

### 根拠

- [ ] 全主要主張がEvidence Mapに存在する
- [ ] 出典から主張へ、主張から出典へ遡れる
- [ ] 反証、境界条件、代替説明が落ちていない
- [ ] 経験的主張、推論、価値判断を区別できる
- [ ] 確信度と限定表現が整合している
- [ ] 時点依存情報に確認日または情報基準日がある
- [ ] 全主要主張に`citation_support`、`transfer_status`、`citation_source_access`、`transfer_source_access`、`integrity_concern`が記録され、`pending`が残っていない
- [ ] 公開文の事実主張が「判定と公開ゲート」を満たしている
- [ ] 仮説として残す命題が事実主張や他の結論の根拠として使われていない

### 成果物

- [ ] 成果物モードの完成条件を満たしている
- [ ] Issueの各受け入れ条件に対応箇所がある
- [ ] 用語と分析単位が上位文書と整合している
- [ ] 図表、リンク、引用、Markdown構文を検証した
- [ ] リポジトリ固有の検査を実行した
- [ ] 文体検査と人間の差分レビューを完了した

チェックを埋めるために本文へ不要な節を追加しない。満たせない項目は制約として報告し、中心的な完成条件なら作業を止める。
