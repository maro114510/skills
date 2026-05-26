# AI-Specific Code Review Risks

## Purpose

AI (LLM) が生成したコードに頻発する 5 つの失敗モードを検査する。
対象は、ハルシネーション依存パッケージ・テスト確認バイアス・並行安全性欠如・ハッピーパス偏重・非推奨/CVE 対象 API の使用。

## Checklist

1. **ハルシネーション依存パッケージ (package hallucination)**
   - diff で追加された依存 (package.json / go.mod / requirements.txt / pyproject.toml / Cargo.toml) を抽出する。
   - 各パッケージの存在確認手順:
     - npm: `npm view <name> version` → 404 ならレジストリ非存在。
     - PyPI: `pip show <name>` はローカル未インストールを意味するだけで非存在の証明にはならない。必ず `WebFetch` で pypi.org も確認する。
     - Go: `go list -m <module>@latest` → 失敗時は `WebFetch` で pkg.go.dev を確認する。
   - 存在しないパッケージは `[must]` (名前スクワッティング攻撃のリスク)。

2. **テスト確認バイアス (confirmation bias)**
   - 実装とテストを同一 AI が生成した可能性がある場合、テストが実装と同じ誤前提を共有していないかを確認する。
   - テストが境界値・null・空入力・エラーパスをカバーしているか、それとも正常系のみかを確認する。
   - テストがテスト対象を実際に呼んでいるかを確認する (ハンドラ未呼び出し・assert なし・モックのみのテストでないか)。
   - 重要度の目安:
     - テストがテスト対象を一切呼んでいない (ハンドラ未呼び出し等) → `[must]` (テストなしと等価)。
     - 新規機能に相当するテストが存在しない → `[imo]`。
     - エッジケース・エラーパスの欠落・ハッピーパス偏重 → `[imo]`。

3. **並行安全性欠如 (concurrency blind spot)**
   - check-then-act パターン (キャッシュ読み取り→書き戻しがアトミックでない)。
   - スレッドセーフでないコレクションへの並行アクセス。
   - グローバル状態・シングルトンへの並行書き込み。
   - ミューテックスのデッドロック可能性。
   - ゴルーチンリーク (受信側のいないチャネル送信・未完了 WaitGroup)。

4. **ハッピーパス偏重 (happy-path overfit)**
   - 異常系・タイムアウト・部分失敗のテスト・分岐がほぼ正常系に集中していないかを確認する。
   - エラーパスでのリソース解放 (defer / finally / using) があるかを確認する。
   - 部分的に防御されているケース (状態更新は防御してリトライは止まらない、など) は完全防御扱いしない。

5. **非推奨 / CVE 対象 API**
   - 使用 API が AI の学習データカットオフ以降に廃止・脆弱性指定されていないかを確認する。
   - 主要ライブラリのメジャーバージョン変更に注意する。

## Anti-patterns

- 存在しないパッケージへの import に「未確認だが推測で OK」とする。
- AI が書いたテストが通っているだけで品質保証されたとみなす。
- 単一スレッドでの動作確認だけで並行安全とみなす。
- 「正常系で動くから OK」と異常系の防御欠如を見逃す。
- 部分防御を完全防御と混同する。

## Sources

- arXiv:2406.10279 — Package hallucinations in LLM code generation。
- arXiv:2510.25297 — AI-code blind spots and confirmation bias。
- arXiv:2501.15134 — BitsAI-CR (ByteDance production AI code review)。
- Anthropic — Code Review Harness Guidance (https://docs.anthropic.com/)。
