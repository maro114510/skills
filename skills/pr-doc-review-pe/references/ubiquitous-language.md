# Ubiquitous Language Checklist

## Purpose

設計ドキュメントで使われるドメイン概念語が既存コードベース・境界づけられたコンテキスト
(Bounded Context) と一致しているかを検査する。
概念語の乖離はコードとドキュメントの意味的なドリフト (ubiquitous drift) を招く。

## Checklist

**git grep レシピ**

1. 変更ドキュメント内のキーノウン (名詞・ドメイン概念語) を 5〜10 件抽出する。
2. 各キーノウンをコードベースで検索する:

   ```bash
   git grep -n "<noun>" -- '*.go' '*.ts' '*.py' '*.java' '*.kt' '*.rb'
   ```

3. 判定:
   - **ゼロヒット**: コードに存在しない語 → ユビキタスドリフト候補。ドキュメントの造語か確認する。
   - **ヒットあり**: 定義 (型名・関数名・コメント) とドキュメント記述の表記・意味が一致するか照合する。
   - 表記が異なる場合 (例: コードは `isNewCustomer`、ドキュメントは「新規ユーザー」) は指摘する。

**Bounded Context 境界チェック**

- 変更ドキュメントが複数の Bounded Context にまたがる用語を混在させていないか。
- 同概念が複数の名前で使われていないか (例: order / purchase / transaction を混用)。
- Bounded Context 境界を超えた場合は、コンテキストマップ (Context Map) があるか確認する。

**ADR・CLAUDE.md 整合**

- 既存 ADR / CLAUDE.md に反する設計選択が採択されていないか。
- 採択前に既存 ADR との衝突を確認済みか (衝突があれば Supersedes 関係を明示する)。

## Anti-patterns

- git grep を実行せずに「コードと整合している」と判断する。
- ゼロヒット語に「将来的に追加される」と仮定して指摘を省略する。
- 同一概念が複数の名前で使われているが「慣習なので問題なし」と見逃す。
- Bounded Context の境界を意識せず、複数のドメインの語彙を1文書に混在させる。

## Sources

- Eric Evans — Domain-Driven Design: Ubiquitous Language (O'Reilly, 2003)
  https://www.domainlanguage.com/ddd/
- Martin Fowler — Ubiquitous Language (bliki)
  https://martinfowler.com/bliki/UbiquitousLanguage.html
- Vaughn Vernon — Implementing Domain-Driven Design (Addison-Wesley, 2013)
  https://vaughnvernon.com/
