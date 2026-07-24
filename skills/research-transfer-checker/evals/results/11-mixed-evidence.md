# Case 11 結果: 支持・反証が混在する根拠 / mixed supporting-and-refuting evidence

ケース定義: `../11-mixed-evidence.md`

## Baseline（no-skill）transcript

この主張は素直には受け入れられません。まず一文目「サプリメントPは関節痛を改善する」という一般化した言い切りが、この論文の結論と真逆です。論文の主要評価項目（事前登録された全体症状スコア）では有意差がなく、著者自身も「関節痛全般への効果は支持されなかった」とはっきり書いています。

二文目の「膝関節痛サブグループで有意改善」自体は数値としては合っていますが、これが事後的・非事前登録・多重比較未補正の探索的解析であることが完全に抜け落ちています。著者が「偶然の陽性結果の可能性を否定できない」「仮説生成的な位置づけにとどまる」とわざわざ念を押している注意書きを削って、あたかも確証的な追加証拠であるかのように提示するのは、典型的なサブグループのつまみ食い（チェリーピッキング）です。

判定としては拒否、少なくとも大幅な修正を要求します。この判断についてはかなり確信があります。ソース内の記述が非常に明示的で、解釈の余地がほぼないためです。

## With-skill transcript（standard モード）

```markdown
## Research Transfer Check

### 判定サマリー
- citation_support: qualified 1件 / overextended 1件 / contradicted 1件
- transfer_status: no_transfer 3件
- integrity_concern: true
- 最も重大な問題: 主要評価項目(全体集団)では有意差がなかった(p=0.22)にもかかわらず、事前登録のない事後の探索的サブグループ解析を根拠に、無条件の一般的効果を主張している。

#### C1（「サプリメントPは関節痛を改善する」という無限定の一般的効果）
- citation_support: contradicted / transfer_status: no_transfer / integrity_concern: true
- 問題のある推論箇所: 主要評価項目は有意差なし(p=0.22)。著者は「サプリメントPは慢性関節痛全般に対する症状改善効果を示さなかった」と明記。

#### C2（膝関節痛サブグループの数値記述そのもの）
- citation_support: qualified / transfer_status: no_transfer
- 問題のある推論箇所: 数値自体は一致するが、「事前登録のない事後解析」「多重比較補正なし」という限定を伴わずに提示。

#### C3（二文を合わせた含意＝サブグループ改善がサプリメントPの効果を示す根拠であるという含意）
- citation_support: overextended / transfer_status: no_transfer
- reasoning_type: 示唆から証明
- integrity_concern: true
- 問題のある推論箇所: 著者は「仮説生成的な位置づけにとどまり、独立した検証研究による再現が必要」と明記している。
```

## 採点

**期待される判定**: citation_support `overextended` / transfer_status `no_transfer` / reasoning_type `示唆から証明` / integrity_concern `true`。主要評価項目の否定的結果への言及が必須。

**採点基準チェック**:
- [x] citation_support は `direct`/`qualified` ではない（3命題中いずれも該当なし。核心的な含意はC3=`overextended`）— 正解
- [x] transfer_status は `no_transfer` — 正解
- [x] source_access は `full_verified` — 正解
- [x] 主要評価項目（全体集団）の有意差なしに言及している — 正解
- [x] reasoning_type に「示唆から証明」を含む — 正解
- [x] 「主要評価項目の否定的結果を選択的に無視している」という趣旨の指摘を含む — 正解
- [x] 研究不正・意図的欺瞞の断定なし — 正解

**判定: PASS**

模範解答は単一命題（C1）として扱っているのに対し、このランは「無限定の一般化」「サブグループ数値の記述」「両者を組み合わせた含意」の3命題に分解した。分解の粒度は異なるが、採点基準が要求する要素（主要評価項目の無視への言及、`示唆から証明`の検出、研究不正の非断定）はすべて満たしており、実質的な判断の中身は模範解答と一致する。
