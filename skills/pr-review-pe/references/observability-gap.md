# Observability Gap

## Purpose

PR の変更が本番で壊れたとき、既存の logs / metrics / traces / alerts が root cause に到達できる粒度・カバレッジを備えているかを判定する。
欠如している telemetry は重要度を付して指摘する。

## Checklist

1. **ログ**
   - 失敗パスに構造化ログ (level=error / 相関 ID / 入力サマリ) が存在する。
   - PII・シークレット・トークンがログに含まれない。
   - ログレベルの濫用がない (info で大量出力、debug でしか必要情報を出さない、になっていない)。

2. **メトリクス**
   - リクエスト数 / エラー率 / レイテンシ (RED) または Utilization / Saturation / Errors (USE) を新コードがカバーする。
   - 新規エンドポイント・キューコンシューマ・バッチジョブにメトリクス定義がある。
   - SLO 違反を検知できる粒度で記録されている。

3. **トレース**
   - 外部 API / DB / RPC / メッセージブローカー呼び出しに分散トレースのスパンが張られている。
   - リトライ・タイムアウトがスパン属性 (`retry.attempt`, `timeout.ms` 等) で識別可能。

4. **アラート**
   - 新しい失敗モード (新 enum 値・新外部依存・新 critical パス) に対する閾値アラートが定義されている。
   - 既存アラートの誤発火・過剰静音化を引き起こさない。

5. **デバッグ可能性**
   - エラーメッセージから関連リクエスト・テナント・コンポーネントを特定できる。
   - 入力データを再現するための属性 (request_id, tenant, locale, version 等) がログ・トレースで再構成できる。

## Anti-patterns

- 例外ハンドラで `log.Error("failed")` だけ書きコンテキストを失う。
- メトリクス追加なしで新規エンドポイントを追加する。
- リトライ実装に retry attempt 数の属性がない。
- 監視チームに事前通知なく failure mode を増やす。
- ログレベルだけで PII 除去を判定する (debug なら出力可とする)。
- 既存ダッシュボードに新指標が表示されない (定義漏れ)。

## Sources

- arXiv:2603.26942 — Observability Gap as first-class review concern。
- Google SRE Book — Monitoring Distributed Systems (RED / USE / Golden Signals)。
- Cindy Sridharan — Distributed Systems Observability (O'Reilly, 2018)。
- Charity Majors — Observability Engineering (O'Reilly, 2022)。
