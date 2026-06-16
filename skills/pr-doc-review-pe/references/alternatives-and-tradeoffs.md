# Alternatives and Trade-offs Checklist

## Purpose

採択された設計より根本的に優れた選択肢がないかを、設計レベルで検査する。
主軸は「そもそもこれをやるべきか」「根本的に優れたアプローチはないか」であり、API 名・テーブル名・カラム名レベルの代替提示はしない。
より良い設計が見えたときは名指しで提示し 4 軸で比較したうえで、採否は `[ask]` で著者に委ねる。

## Checklist

**設計レベルの代替評価**

1. **やるべきか (do-nothing / 既存活用)**: そもそもこの設計を作る必要があるか。既存の仕組み・既製ライブラリ・マネージドサービスで代替できないか。問題そのものを回避する設計はないか。
2. **根本的代替**: 採択案と質的に異なるアプローチ (例: 同期 vs 非同期、ポーリング vs イベント駆動、集中 vs 分散、強整合 vs 結果整合) が検討されているか。
3. **逆生成代替案**: 文書から「書かれていない代替案」を 1〜2 件逆生成し、採択案がそれより優れている根拠が文書内にあるか確認する。根拠がなければ `[ask]` で正当化を求める。

**4 軸比較** (より良い代替が見えた場合のみ実施)

採択案と代替案を以下の 4 軸で比較し、各軸で優劣を明示する。

- **scalability** — 規模が増えたときの伸び。
- **ops-complexity** — 運用・監視・障害対応の手間。
- **reversibility** — 後から変更・撤回できるか (一方通行か)。
- **debuggability** — 壊れたとき原因に到達しやすいか。

**ベストプラクティス / ライブラリ制約**

- 採用技術・ライブラリの既知の制約・誤用・非準拠がないか。確証がなければ一次情報を確認する。
- 業界の確立したパターンから逸脱している場合、その逸脱に正当な理由が文書内にあるか。

## Anti-patterns

- 代替案を一切検討せず採択案だけを記述する。
- 「他に選択肢がない」と書くが、実際には一般的な代替が存在する。
- 4 軸の一部 (例: scalability) だけ論じ、reversibility や ops-complexity を無視する。
- 不可逆な選択 (データモデル・公開 API・外部契約) を、撤回コストに触れず採択する。
- API 名・実装詳細レベルの代替を「より良い設計」として提示してしまう。

## Sources

- Nygard — Documenting Architecture Decisions (cognitect.com, 2011)
  https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
- Martin Fowler — Is Design Dead? / Sacrificial Architecture (bliki)
  https://martinfowler.com/bliki/SacrificialArchitecture.html
- Annie Duke — Thinking in Bets: reversibility of decisions (Portfolio, 2018)
  https://www.annieduke.com/books/
