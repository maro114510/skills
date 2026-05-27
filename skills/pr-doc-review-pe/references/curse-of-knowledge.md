# Curse of Knowledge Checklist

## Purpose

「知識の呪い」—— 作成者が「誰でも分かる」と思っているが背景を持たない読者には
分からない表現 —— を検出する。
Pinker / Heath の観点と、実験的に裏付けられた Tapper-side チェックを適用する。

## Checklist

**ジャーゴン定義チェック** (Pinker / Heath)

- 技術用語・社内略語が初出時に定義されているか。
  - 定義なしで使われている用語リストを抽出し、初見読者が理解できるかを判定する。
  - 略語 (例: SLO / CQRS / DDD) の初出定義がなければ `[imo]` 指摘。
- 定義が「注釈」や「用語集」にのみあり、本文でも理解できない構造は `[imo]`。

**Tapper-side チェック**

- 作成者の頭の中のリズム (知識) が読者に伝わっていない箇所はないか。
  - 「詳細は X を参照」が、X を読まないと本文が理解できない依存になっていないか。
  - 「周知の事実」として扱っているが、新規参加メンバーには自明でない概念がないか。

**曖昧語検出**

以下の語が **判断基準なしで** 使われていないかを確認する:

| 語 | 問題点 |
|---|--------|
| 適切に / 適切な | 「適切」の基準が不明 |
| 必要に応じて | いつ「必要」かが不明 |
| 十分に | 「十分」の閾値が不明 |
| 考慮する | 何を・どう考慮するかが不明 |
| 基本的に | 例外条件が不明 |
| など / 等 | 列挙の網羅性が不明 |

## Anti-patterns

- 社内用語を定義なしで使い「チーム全員が知っている」と仮定する。
- 「詳細はリンク先を参照」だけで本文が完結しない構造。
- 曖昧語が 3 件以上あるが「読者が判断してくれる」と放置する。
- 「誰でも分かる表現にした」と言いながら、具体的な条件・数値を欠く。

## Sources

- Steven Pinker — The Sense of Style (Viking, 2014)
  https://stevenpinker.com/publications/sense-style-thinking-persons-guide-writing-21st-century
- Chip Heath & Dan Heath — Made to Stick (Random House, 2007)
  https://heathbrothers.com/books/made-to-stick/
- Elizabeth Newton — Tappers and Listeners experiment (Stanford, 1990)
  https://hbr.org/2006/12/the-curse-of-knowledge
