# Scale and Failure Modes Checklist

## Purpose

設計ドキュメントが「正常系・小規模」だけを前提にしていないかを検査する。
ユーザー数・データ量・トラフィックが増えたときの破綻と、異常系・並行性・失敗時の未定義挙動を、具体的障害シナリオに接地して顕在化させる。
発見は「この設計は [X] を前提とする。[X] が偽なら [障害 Y] が起きる」形式に落とす。

## Checklist

**スケール限界**

1. 設計が前提とする規模 (想定ユーザー数・QPS・データ量・成長率) が明記されているか。
   明記がなければ「現状の規模を暗黙に前提している」と疑う。
2. データ量が 10x / 100x になったとき破綻する箇所 (全件スキャン・無制限の in-memory 蓄積・N+1・ページングなしの一覧) がないか。
3. ホットスポット (単一行・単一パーティション・単一キューへの集中) が生じないか。
4. 外部依存のレート制限・コネクション上限・スループット上限に到達しないか。

**想定外挙動 / 異常系**

1. 失敗時の振る舞いが定義されているか (リトライ・タイムアウト・部分失敗・補償処理)。
   「正常系しか書いていない」を疑う。
2. 冪等性が必要な箇所 (リトライ・重複配信・二重サブミット) で保証されているか。
3. 並行性 (競合更新・ロック・順序保証・read-after-write) が考慮されているか。
4. エッジケース (空・最大値・境界・null・未初期化・期限切れ) の扱いが定義されているか。

## Anti-patterns

- 想定規模を書かず「十分にスケールする」と述べる。
- リトライを前提にしながら冪等性に触れていない。
- 失敗時の振る舞いが「エラーを返す」のみで、呼び出し側の回復手順がない。
- 並行アクセスを「基本的に起きない」と暗黙に仮定する。
- バッチ・一覧取得にページング/上限がなく、データ増加で OOM・タイムアウトを招く。

## Sources

- Martin Kleppmann — Designing Data-Intensive Applications (O'Reilly, 2017)
  https://dataintensive.net/
- Google SRE Book — Addressing Cascading Failures, Handling Overload
  https://sre.google/sre-book/addressing-cascading-failures/
- Michael Nygard — Release It! Stability Patterns (Pragmatic Bookshelf, 2018)
  https://pragprog.com/titles/mnee2/release-it-second-edition/
