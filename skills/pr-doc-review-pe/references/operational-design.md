# Operational Design Checklist

## Purpose

Uber RFC テンプレートに基づき、設計ドキュメントの運用設計セクションを検査する。
Rollout / Rollback / Metrics / Multi-DC / サポート対応の欠落を指摘する。

## Checklist

**Uber RFC 必須フィールド**

1. **Rollout 計画**
   - デプロイ順序・フィーチャーフラグ・段階的展開 (カナリア / blue-green) が記述されているか。
   - 展開の中断条件 (rollout abort criteria) が定義されているか。

2. **Rollback 計画**
   - 失敗時に元の状態に戻す具体的な手順・条件が明示されているか。
   - 「手動で対応」のみは不可。データマイグレーションがある場合はダウン方向のマイグレーションも必要。

3. **Multi-DC / Multi-Region**
   - 地理的冗長性が設計に含まれる場合は、各リージョン間のデータ整合性
     (eventual consistency vs strong consistency) が考慮されているか。
   - リージョン障害時のフォールオーバー手順が記述されているか。

4. **Metrics / Alerting**
   - 成功・失敗を判定する具体的なメトリクスと閾値が定義されているか。
   - 新指標の定義がなく「既存ダッシュボードを参照」のみは `[must]`。
   - SLO 達成を確認できる指標が含まれているか。

5. **カスタマーサポート対応**
   - ユーザー影響が発生した場合のサポート手順・エスカレーションパスが記述されているか。
   - よくある問題と回避策 (FAQ / runbook) へのリンクがあるか。

## Anti-patterns

- Rollback 欄なし、または「必要に応じて対応」のみ。
- 「段階的展開」と書くが具体的な閾値・中断条件がない。
- メトリクス欄に「既存ダッシュボードを参照」のみ (新指標の定義がない)。
- Multi-DC を考慮せずに strong consistency を暗黙に仮定する。
- カスタマーサポートへの影響を設計フェーズで考慮していない。

## Sources

- Uber Engineering Blog — RFC Process (Pragmatic Engineer Newsletter)
  https://newsletter.pragmaticengineer.com/p/the-rfc-process
- Google SRE Book — Release Engineering, Handling Incidents
  https://sre.google/sre-book/release-engineering/
- Martin Kleppmann — Designing Data-Intensive Applications (O'Reilly, 2017)
  https://dataintensive.net/
