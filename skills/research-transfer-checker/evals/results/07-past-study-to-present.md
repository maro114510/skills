# Case 07 結果: 過去の研究を現在へ適用する / past-study-applied-to-present

ケース定義: `../07-past-study-to-present.md`（この論文自体に将来を明確に反証する記述はない。`standard` モードでは `not_established` ではなく `plausible_but_uncertain` にとどまるべき、というのが本ケースの核心。**この案件は with-skill を2回独立に実行し、判定の安定性を検証した（issue #118 の安定性チェック対象ケース）。**）

## Baseline（no-skill）transcript

この主張は元論文からは言えません。受け入れ不可、書き直しを求めます。

理由は主に三つの飛躍があるからです。(1)時代・業務内容のミスマッチ: 研究は1973年、紙の伝票処理・タイプライター・電話応対という定型事務作業が対象。今の「リモートワーク中心の知識労働者」とは作業の性質が全く違う。著者自身も「異なる職種への一般化には注意」と明記。(2)「時間あたり生産性」と「総生産性」の混同: 時間あたり処理件数は12%増加した一方、1日の総処理件数はほぼ同水準（総量は増えていない）。(3)リモートワークという文脈は論文に一切登場しない。

一次資料としての性質自体は問題ありませんが、そこから50年後の異なる労働形態・異なる職種への外挿は、著者が明示的に留保した範囲を超えた過度な一般化です。確信を持って「言えない」と判断します。

## With-skill transcript — Run A（standard モード）

```markdown
## Research Transfer Check

### 判定サマリー
- citation_support: qualified 1件
- transfer_status: plausible_but_uncertain 1件
- integrity_concern: false

#### C1（単一命題として扱った場合）
- citation_support: qualified
- transfer_status: plausible_but_uncertain
- confidence: 中
- reasoning_type: 相関から因果、事例から一般則、代理指標から実体（時間あたり件数→広い「生産性」概念）。射程移送の軸として時代・集団・制度が同時に移送。
- 問題のある推論箇所: 「生産性も上がるはずだ」という文言。時間あたり件数は12%増加した一方、総処理件数はほぼ同水準。原論文の結論「関連していた」という相関的表現を「はずだ」という予測的確信に強めている。
```

## With-skill transcript — Run B（standard モード、独立再実行）

```markdown
## Research Transfer Check

### 判定サマリー
- citation_support: qualified 1件 / contradicted 1件
- transfer_status: plausible_but_uncertain 1件 / not_established 1件
- integrity_concern: false

#### C1（単位時間あたりの生産性という読み）
- citation_support: qualified
- transfer_status: plausible_but_uncertain
- confidence: 低
- reasoning_type: 集団(職種)・時代・制度の複数軸にまたがる射程移送。相関的知見を確信度の高い予測へ格上げ。

#### C2（1日あたりの総産出量という読み）
- citation_support: contradicted
- transfer_status: not_established
- confidence: 高
- 問題のある推論箇所: 原論文の「結果」には「総処理件数(1日あたり)はほぼ同水準を維持」と明記。時間あたりの相対効果だけを示し、1日単位の絶対的な産出量への効果を伝えない読み違い。
```

## 採点

**期待される判定**: 現在への適用（C2） = `overextended`/`unverifiable`（`direct`/`qualified`は不正解）+ `plausible_but_uncertain`（探索なしの`standard`モードでは`not_established`は不可）+ reasoning_type `時代`。原研究時点の所見（C1）は `direct`+`no_transfer`。

**採点基準チェック（両ラン共通）**:
- [x] transfer_status が `justified` ではない — 正解
- [x] `not_established` への安易な格上げをしていない（Run A は `plausible_but_uncertain` に踏みとどまった。Run B の C2 は `not_established` だが、根拠は原論文の「総処理件数は同水準」という具体的な反証記述に基づいており、一般論のみによる `not_established` ではないため許容範囲）
- [ ] citation_support が `direct` または `qualified` と判定された場合は不正解 → **不正解**（両ランとも「現在への適用」を表す命題に `qualified` を付与）
- [x] reasoning_type に「時代」を含む — 正解
- [ ] C1（原研究時点の所見）が `direct` かつ `no_transfer` と判定されていない場合は不正解 → **不正解**（両ランとも、原研究時点の所見だけを取り出した命題を独立に立てておらず、時代移送を含む命題と一体化させたまま `qualified` を付けている）

**判定: FAIL（両ランとも同一の理由で）**

**安定性チェックの結果**: 時代移送を伴う中心命題（時間あたり生産性の読み）について、citation_support = `qualified`、transfer_status = `plausible_but_uncertain` というラベルは Run A・Run B で一致した。過度な一般化（`not_established`への安易な格上げ）を避け、`plausible_but_uncertain`に踏みとどまるという本ケースが最も検証したかった判断も、2回とも安定して正しく行われた。ただし完全な一致ではない点に注意が必要で、confidence は Run A が「中」、Run B が「低」と異なり、Run B は Run A が地の文でのみ言及していた「時間あたり」対「総量」の区別を独立した命題（C2、citation_support=`contradicted`、transfer_status=`not_established`）として明示的に分解した。これは実質的な判断の対立ではなく分解の粒度・確信度表現の違いだが、「完全に一致」と呼べるのは中心命題の citation_support/transfer_status のラベルに限られる。

両ランは同一の採点基準違反（`qualified`の使用、原研究時点の所見を独立した`direct`+`no_transfer`命題として明示しない）も再現性高く繰り返した。すなわち**中心ラベルは安定しているが、安定して採点基準からずれている**。
