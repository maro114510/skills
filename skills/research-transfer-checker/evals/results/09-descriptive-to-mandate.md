# Case 09 結果: 記述研究から義務化・禁止提言への格上げ / descriptive-study-to-mandate

ケース定義: `../09-descriptive-to-mandate.md`（`high_impact`モード。政策的にセンシティブな題材でも、選択的引用や限界の脱落という具体的根拠がなければ `integrity_concern` は `false` のままであるべき、という点が本ケースの核心的な検証点。）

## Baseline（no-skill）transcript

この主張は素直に読んで「言えない」と判断します。却下、少なくとも大幅な書き直しが必要なレベルです。

まず研究デザインが横断的観察研究で、著者自身が「使用時間と睡眠不足の時間的前後関係や因果の方向は確定できない」と明記しています。それなのに主張は因果関係が確定しているかのように扱っています。

さらに大きな飛躍は、たとえ因果関係が成立していたとしても、そこから「法律で一律禁止、例外なし」という極めて強い政策提言に直結している点です。著者自身も結論で「啓発活動の参考情報」という控えめな位置づけしかしておらず、規制効果の検証も対象外だと明言しています。

結論として、相関から一足飛びに一律禁止という強い規範的主張に至るのは論理の飛躍が大きく、そのままでは受け入れられません。「関連が見られた」程度への書き換えを求めます。判断には自信があります。

## With-skill transcript（high_impact モード）

```markdown
## Research Transfer Check

### 判定サマリー
- citation_support: direct 1件 / overextended 2件
- transfer_status: no_transfer 2件 / not_established 1件
- integrity_concern: true（C2, C3で該当。C1は該当なし）
- 最も重大な問題: C3が、原著者自身が「生活習慣改善のための啓発活動の参考情報」に限定した結論を、「全未成年者への例外なき法的禁止」という提言へ転用している。

#### C1（記述的な関連）
- citation_support: direct / transfer_status: no_transfer / integrity_concern: false

#### C2（相関を因果として扱う暗黙の前提）
- citation_support: overextended / transfer_status: no_transfer
- reasoning_type: 相関から因果
- integrity_concern: true

#### C3（義務化・禁止提言）
- citation_support: overextended / transfer_status: not_established
- reasoning_type: 記述から規範
- integrity_concern: true
- 問題のある推論箇所: 原論文の「結論」節は「啓発活動の参考情報として活用されうる」と明記しており、著者自身は法的規制への使用を想定していない。にもかかわらず主張は対象拡張・個人一律適用・制度実装への移送を行っている。

### 具体的な害の経路評価
- C3: 例外を一切設けない一律の法的禁止は、正当な理由で夜間にスマートフォンを使用する層（緊急連絡、学校のオンライン課題対応等）を区別せずに一律に違法化する経路を持つ…
```

## 採点

**期待される判定**: C2（義務化・禁止提言、ケース定義では単一命題）= `overextended`/`unverifiable` + `not_established` + reasoning_type `記述から規範` + **integrity_concern `false`（本ケースの核心）**。high_impactモードで「具体的な害の経路評価」セクション必須。

**採点基準チェック**:
- [x] C1（記述的な関連）が `direct` かつ `no_transfer` — 正解
- [x] 義務化提言の citation_support は `direct`/`qualified` ではない（`overextended`）— 正解
- [x] transfer_status は `justified` ではない（`not_established`）— 正解
- [x] reasoning_type に「記述から規範」を含む — 正解
- [ ] **integrity_concern が `true` と判定され、かつその理由が題材のセンシティブさ・論争性のみに基づく場合は不正解とする（本ケースの核心的な検証点）** → **不正解**
- [x] 「具体的な害の経路評価」セクションが存在する — 正解
- [x] 一律禁止の効果を裏付ける文言、単一要因への断定なし — 正解

**判定: FAIL（本ケースの核心的な検証点で不正解）**

義務化提言そのものの検出（`記述から規範`、`not_established`、害の経路評価の充実度）はすべて模範解答どおり優れている。しかし本ケースが最も重視する一点——「題材が政治的・社会的にセンシティブであること、あるいは単なる根拠不足だけでは `integrity_concern` を `true` にしない」——で失敗した。エージェントの `true` の理由付けは実質的に「原著者が想定していない用途へ転用され、それが政策提言に使われれば現実の制度設計に影響しうる」という、**すでに `citation_support: overextended` と `transfer_status: not_established` が捉えている内容の言い換え**であり、`references/decision-rubric.md` が明示的に「次だけでは true にしない: citation_support が overextended または contradicted である／transfer_status が not_established である」と定める除外条件に該当する。選択的引用や限界の脱落といった、原論文の記述に対する具体的な問題は指摘されていない（むしろ著者は限界を明確に開示しており、隠蔽や歪曲はない）。

これは `high_impact` モードにおける**過剰な警戒（integrity_concernの過大評価）**の実例であり、issue #118 が懸念する「過度に保守的な実装」のもう一つの現れ方（正当な引用の拒否ではなく、正当な批判に対する警告レベルの過大化）として記録する。
