# Cognitive Load Checklist

## Purpose

設計ドキュメントが読者のワーキングメモリを過負荷にしていないかを検査する。
BLUF / ピラミッド原則 / Sweller の認知負荷理論 / split-attention 効果を適用し、
読解コストの高い構造を指摘する。

## Checklist

**BLUF / ピラミッド原則** (Minto)

- 結論先行 (BLUF: Bottom Line Up Front) になっているか — 最重要情報が冒頭にあるか。
- 各セクションが「主張 → 根拠 → 詳細」の順になっているか。
- 前提説明が長すぎて結論が文書の後半に隠れていないか。

**ワーキングメモリ 7±2 ルール** (Sweller, 1988; Miller, 1956)

- 1 セクション内の箇条書きが 9 件を超えていないか。
  超える場合はグルーピング (サブセクション化) を提案する。
- 1 文内で参照する概念が 5 個を超えていないか。

**Split-attention 回避**

- 図と説明文が遠くに置かれていないか (図の直後に説明を置く原則)。
- 表のヘッダと内容が意味的に対応しているか。
- 脚注 / 参照リンクへの依存度が高く、本文だけでは内容が理解できない構造になっていないか。

## Anti-patterns

- 文書を先頭から最後まで読まないと結論が分からない (ピラミッド原則違反)。
- 1 つの箇条書きリストに 15 件以上の項目が並んでいる (グルーピングなし)。
- 図だけがあり説明文が別ページ・別セクションに分離している (split-attention)。
- 専門用語が定義なしで使われ、読者が別ドキュメントを参照しないと理解できない。

## Sources

- John Sweller — Cognitive Load Theory (1988)
  https://link.springer.com/article/10.1007/BF01326608
- Barbara Minto — The Pyramid Principle (Pearson, 1996)
  https://www.barbaraminto.com/
- George A. Miller — The Magical Number Seven (Psychological Review, 1956)
  https://psychclassics.yorku.ca/Miller/
