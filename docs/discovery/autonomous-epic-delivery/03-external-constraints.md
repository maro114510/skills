# 外部仕様が設計に課す制約

この文書の内容は事実である。2026-10-14 に GitHub の公式文書、OpenCode 1.19.0 の公式文書とソース、手元のコマンドの説明出力で確認した。各項目の末尾に、その事実が効いてくる論点を示す。論点の番号は、論点ごとの合意状況をまとめた文書と同じである。

## GitHub

### イベントと起動

- 既定のワークフロー用トークンで起こしたイベントは、新しいワークフローを起動しない。手動起動と外部からの起動イベントだけが例外である。そのトークンで PR を作ると、そのワークフローは承認待ちの状態で起動する。エージェント用の身元を別に持つ理由の一つになる。論点 7。
- チェックスイートとチェックランの完了イベントは、GitHub Actions が作ったチェックスイートでは発火しない。Actions の CI 結果に反応するには、ワークフロー実行の完了イベントを使う。論点 8。
- 定期実行の間隔は最短 5 分で、混雑時には遅れたり取りこぼしたりする。公開リポジトリでは、60 日間活動がないと定期実行が無効になる。論点 8。
- Webhook は 10 秒以内に応答しないと失敗扱いになる。失敗した配信は自動では再送されず、手動の再送は過去 3 日分に限られる。論点 8。
- REST API の条件付きリクエストは、変更がなく 304 が返った場合、主要なレート制限を消費しない。定期的に状態を読む方式の費用を下げられる。論点 8。

### 承認とマージ

- PR の作成者は、自分の PR を承認できない。エージェントが利用者の名義で PR を作ると、利用者は承認できない。論点 7。
- GitHub App による承認レビューが、ブランチ保護の「承認の必須」に数えられるかは、公式文書に記載がない。人の承認かどうかは、自分の判定で確かめる必要がある。論点 5。
- PR の総合的なレビュー判定は、保護規則でレビューが必須でないリポジトリでは値を持たないことがある。レビュアーごとの最新レビューを読めば、書き込み権限を持つ人に絞って判定できる。論点 5。
- ブランチ保護には、新しいコミットで古い承認を無効にする設定と、最新の送信を送信者以外が承認することを求める設定がある。管理者は既定で保護を迂回できる。論点 5。
- 自動マージはリポジトリ単位の設定で有効になる。有効になっていても、誰かが要求しない限り PR は自動ではマージされない。論点 5。

### 信頼の境界

- フォークからの PR では、既定のトークン以外の秘密情報がワークフローに渡らない。フォークのコードを、秘密情報を持つワークフローで実行すると危険である。論点 7。
- 公開リポジトリでは、誰でも Issue と PR にコメントできる。エージェントへの入力にそのまま混ぜると、指示を注入される。論点 7。

## OpenCode

### ヘッドレス実行

- `opencode run` は、権限の確認が必要になった操作を自動で拒否し、止まらない。拒否と許可を明示した設定と組み合わせれば、無人で動かせる。論点 8。
- `--agent` にサブエージェントを指定すると、エラーにならず既定のエージェントに切り替わる。役割ごとのエージェントは、主エージェントとして定義する必要がある。論点 8。
- JSON 形式の出力には、手順ごとのトークン数と費用が含まれる。費用は後から集計できる。論点 6。
- 実行時間の上限と金額の上限を設定する機能はない。手順数の上限はあるが、上限に達すると要約を返して終わる柔らかい停止である。固まった実行を止めるには、呼び出す側で時間を区切る必要がある。論点 6。
- ヘッドレス実行でも、利用者の設定ディレクトリとリポジトリのスキルを読み込む。論点 8。
- セッションは手元のデータベースに保存され、別のマシンへは持ち運べない。永続する状態の置き場所には使えない。論点 2。

### サーバーと公式の GitHub 連携

- `opencode serve` と公式の SDK を使えば、常駐するサーバーにセッションを作り、指示を送り、中断できる。論点 8。
- 公式の GitHub 連携アクションは、ワークフロー実行の完了イベントに対応していない。CI 失敗の修正には使えない。権限確認の要求に応答する処理がソースに見当たらず、確認待ちのまま止まる可能性がある。後者はソースを読んだうえでの推論で、実機では確かめていない。論点 8。

## Claude Code との比較

比較のために確認した。Claude Code のヘッドレス実行は、金額の上限、手順数の上限による異常終了、確認が必要な操作の一律拒否を、起動時の指定で持てる。上限の強さでは Claude Code が勝る。役割ごとにモデルを選べることと、常駐サーバーを操作できることでは OpenCode が勝る。

## 確かめられなかったこと

- GitHub App の承認が、ブランチ保護の必須承認に数えられるか。
- 公式の GitHub 連携アクションが、権限確認の要求で実際に止まるか。
- Webhook の配信順序が保証されるか。

## 出典

- GitHub: ワークフローを起動するイベント <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>
- GitHub: ワークフロー用トークン <https://docs.github.com/en/actions/concepts/security/github_token>
- GitHub: REST API の推奨される使い方 <https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api>
- GitHub: Webhook の推奨される使い方 <https://docs.github.com/en/webhooks/using-webhooks/best-practices-for-using-webhooks>
- GitHub: 失敗した Webhook 配信の扱い <https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries>
- GitHub: 必須レビューのある PR の承認 <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews>
- GitHub: 保護ブランチ <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches>
- GitHub: PR の GraphQL リファレンス <https://docs.github.com/en/graphql/reference/pulls>
- GitHub: 自動マージ <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request>
- GitHub: `pull_request_target` の安全な使い方 <https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target>
- OpenCode: CLI <https://opencode.ai/docs/cli/>
- OpenCode: 権限 <https://opencode.ai/docs/permissions/>
- OpenCode: エージェント <https://opencode.ai/docs/agents/>
- OpenCode: サーバー <https://opencode.ai/docs/server/>
- OpenCode: SDK <https://opencode.ai/docs/sdk/>
- OpenCode: 1.19.0 の `run` コマンドのソース <https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/cli/cmd/run.ts>
- Claude Code: CLI リファレンス <https://code.claude.com/docs/en/cli-reference>
