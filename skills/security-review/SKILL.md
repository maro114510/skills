---
name: security-review
description: >
  PR のセキュリティレビューを行うスキル。PR 番号を引数に受け取り、差分のみを対象に
  OWASP Top 10・CWE・CVSS に基づく脆弱性を検出して重大度付きで報告する。
  LLM・AI エージェント・MCP・サブエージェント・RAG・モデル供給網の変更では、
  騙された結果として実行可能な最悪アクションまで精査する。
  「セキュリティレビューして」「脆弱性を調べて」「この PR は安全か」「認証ロジックを確認して」
  「シークレットが漏れていないか」「インジェクションのリスクを見て」「バグバウンティ視点で」
  「ペネトレーションテスト観点で」といった依頼で積極的に使うこと。
  引数に PR 番号・ファイルパス・`deps`（依存関係監査）を渡せる。
context: fork
allowed-tools: Read, Glob, Bash(gh:*, git:*, rg:*, grep:*, npm:*, pip-audit:*, govulncheck:*)
argument-hint: "<pr-number | file-path> [deps]"
---

# security-review

PR の差分を対象に、ホワイトハッカー・バグバウンティの視点でセキュリティ上の問題を発見し、
OWASP・CWE・CVSS に基づく重大度付きで報告する。

## Step 1. スコープ確定と対象コードの取得

`$ARGUMENTS` を解析する:

- 数字（PR 番号）→ `gh pr diff <number>` で差分取得、`gh pr view <number> --json title,files` で文脈把握
- ファイルパス → Read で対象ファイルを読み込む
- 引数なし → `git diff origin/main...HEAD` で現ブランチの変更を取得
- `deps` が含まれる → Step 4（依存関係監査）を実施する

**スコープの鉄則**: 差分（追加・変更行）のみが対象。変更されていない既存コードはスキャン対象外。
ただしシークレット系は PR 内で追加されたファイル全体も対象とする。

**AI/Agent 例外**: LLM・AI エージェント・MCP・ツール実行・RAG・memory・sub-agent・
model/tokenizer/dataset/checkpoint・AGENTS.md/CLAUDE.md などの agent instruction の変更を検出した場合は、
差分だけで判断しない。
攻撃成立に必要な最小限の信頼境界ファイル（system/developer prompt、tool registry、
permission manifest、MCP server/client 設定、memory/vector store 設定、secret 注入経路、
sub-agent delegation policy、approval/audit 設定）を追加で読む。
この例外は「全コードスキャン」ではなく、外部入力が実行権限へ到達する経路を確認するための
限定的な周辺コンテキスト確認である。

中断条件:
- PR が存在しない、または差分が空 → ユーザーに報告して停止

## Step 2. 変更の分類と参照ファイルの選択的ロード

差分を読んで変更カテゴリを特定し、**必要な参照のみ**を読み込む。

**カテゴリと対応参照（該当するもののみ読む）:**

| 差分に含まれるもの | 読む参照 |
|---|---|
| 認証・セッション・JWT・OAuth | `references/owasp-top10.md`（A06・A07 のみ参照） |
| SQL・クエリ・コマンド実行・テンプレート | `references/owasp-top10.md`（A03・A05 のみ参照） |
| 暗号化・ハッシュ・証明書・シークレット | `references/owasp-top10.md`（A04・A10 のみ参照） |
| アクセス制御・API・CORS | `references/owasp-top10.md`（A01・A02 のみ参照） |
| ファイルアップロード・デシリアライズ | `references/vulnerability-patterns.md` |
| LLM・prompt・RAG・embedding・model output | `references/llm-agent-security.md` |
| tool/function calling・MCP・agent 権限 | `references/llm-agent-security.md` |
| sub-agent・multi-agent・memory・delegation | `references/llm-agent-security.md` |
| model・tokenizer・dataset・checkpoint | `references/llm-agent-security.md` と依存関係監査 |
| 上記のどれかで詳細パターン照合が必要 | `references/vulnerability-patterns.md` |

参照を読む際は該当セクションのみを参照すること。ファイル全体を読む必要はない。
変更が設定変更・ドキュメント・テストのみの場合は参照を読まずに直接 Step 3 へ進む。
ただし AI/Agent 例外に該当する設定・manifest・Markdown instruction・prompt・RAG ingest 対象ドキュメントは
`references/llm-agent-security.md` を読む。
設定変更の例: `.github/workflows/`・`k8s/`・`docker-compose.yml`・`Dockerfile`・`nginx.conf`・`*.yaml`（新規ファイル追加・既存ファイル変更ともに含む。アプリコード変更を伴わないもの）

## Step 3. セキュリティ分析

差分の追加行（`+` で始まる行）を中心に以下を確認する。

### 3.0 設定変更 PR の重大度補正ルール（Step 2 で設定変更と判断した場合に適用）

設定変更 PR では以下の原則に従って重大度を補正する:

- **将来的仮定リスクは Info**: 「現在の設定は安全だが、将来 X に変更した場合に危険になる」→ **Info**（注意喚起のみ）
- **追加前提条件の明示と評価**: 「攻撃者が Y の権限を持っている場合に悪用可能」という形の場合、Y が現実的に達成可能かを評価してから重大度を決定する。現実的でない前提条件は重大度を 1 段下げる
- **設定値の直接悪用可否を起点に評価**: 設定変更単体で攻撃が完結するか確認する。コード変更・別の設定変更・攻撃者の追加アクションが必要なら Medium 以上には分類しない

### 3.1 インジェクション系（差分内のみ）

ユーザー入力がそのまま以下に渡されていないか:
- SQL / NoSQL クエリの文字列結合
- シェルコマンド実行（`exec`・`subprocess`・`system` に変数を直接渡す）
- テンプレートエンジンへの直接埋め込み
- HTML 出力への未エスケープ出力（XSS）

### 3.2 認証・認可（新規エンドポイント・関数に注目）

- 新規エンドポイントに認証ミドルウェアが適用されているか
- オブジェクト取得時にオーナー確認があるか（IDOR）
- JWT を `decode` のみで検証していないか（`verify` と混同）
- パスワードを平文比較・MD5 でハッシュしていないか

### 3.3 シークレット・認証情報（差分の追加行）

```bash
# PR差分の追加行のみ対象（全ファイルスキャンは行わない）
gh pr diff <number> | grep "^+" | grep -iE \
  "(password|secret|api_key|apikey|token|credential|private_key)\s*[:=]\s*['\"][^'\"]{6,}"

# クラウドキー固有パターン
gh pr diff <number> | grep "^+" | grep -E "(AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|sk-[a-zA-Z0-9]{48}|ghp_[a-zA-Z0-9]{36})"
```

### 3.4 その他の確認ポイント

- ファイルパスにユーザー入力が含まれ `../` で脱出できないか（パストラバーサル）
- `debug=True`・`NODE_ENV=development` が本番設定に混入していないか
- セキュリティヘッダー（CSP・HSTS・X-Frame-Options）の削除・弱体化

### 3.5 LLM / Agent / MCP セキュリティ

Step 2 で AI/Agent 系変更と判断した場合のみ確認する。

**基本原則**: prompt はセキュリティ境界ではない。外部コンテンツ、tool output、RAG 結果、
GitHub issue/PR コメント、Web ページ、メール、ログ、README、リポジトリ内ファイルは
すべて攻撃者制御の可能性があるデータとして扱う。

- 外部入力が system/developer instruction と混ざり、上位命令として扱われていないか
- tool output / RAG result / GitHub issue / Web content を信頼済み命令として扱っていないか
- LLM 出力を shell / SQL / code eval / HTTP request / GitHub write operation / cloud CLI に直接渡していないか
- tool call に allowlist、schema validation、危険引数の可視化、人間承認、実行前 policy check があるか
- agent / sub-agent に task 単位の最小権限が適用されているか
- 親 agent から子 agent へ secret、token、write 権限、network 権限が暗黙継承されないか
- 子 agent がさらに子 agent を起動できる場合、再帰深度、総 tool call 数、時間、コスト、出力サイズに上限があるか
- 子 agent の出力を親 agent が無検証で実行・承認・外部送信していないか
- memory / vector DB / scratchpad に untrusted instruction が永続化され、後続タスクへ再注入されないか
- MCP server の tool description、schema、capability claim、runtime response を無検証で信頼していないか
- model/tokenizer/dataset/checkpoint を unpinned または未検証の外部ソースから取得していないか
- `trust_remote_code=True`、`torch.load(..., weights_only=False)`、pickle checkpoint などが untrusted path に使われていないか
- prompt injection 成功時に実行可能な最悪アクション（secret 読み取り、repo/CI/cloud/DB 書き換え、外部送信、RCE）を評価しているか
- tool invocation、context source、approval/denial、agent delegation、権限境界が監査可能か

## Step 4. 依存関係監査

`deps` が指定された場合、または Step 2 で `package.json`・`requirements.txt`・`go.mod`・
model/tokenizer/dataset/checkpoint・MCP server・agent plugin/skill/manifest の供給網変更を検出した場合のみ実行する:

```bash
npm audit --json 2>/dev/null | head -50   # Node.js
pip-audit 2>/dev/null | head -30          # Python
govulncheck ./... 2>/dev/null | head -30  # Go
```

コマンドが存在しない場合は、変更された `package.json`・`requirements.txt`・`go.mod`・
model/tokenizer/dataset/checkpoint/MCP server/agent plugin の主要パッケージ、pinning、provenance、
`trust_remote_code`、pickle/`torch.load` 使用箇所を確認するにとどめる。

## Step 5. 報告書の出力

### 重大度（CVSS ベース）

| 重大度 | CVSS | 基準 |
|--------|------|------|
| Critical | 9.0+ | 認証不要・リモートから即座に悪用・RCE・全データ漏洩 |
| High | 7.0–8.9 | 認証済みユーザーが特権昇格・機密データ漏洩 |
| Medium | 4.0–6.9 | 条件付き悪用・部分的な情報漏洩 |
| Low | 0.1–3.9 | 実環境での悪用が困難 |
| Info | — | 改善推奨（脆弱性ではない） |

### LLM/Agent 系の重大度補正

LLM/Agent/MCP 系では、prompt injection や tool poisoning の「入力改ざん」だけで重大度を決めない。
**騙された結果として実行可能な最悪アクション**、権限範囲、持続性、再帰的な影響拡大を評価する。

- 読み取り専用チャットで、機密情報・外部副作用・永続化がない → Low〜Medium
- 機密情報、private repo、個人情報、内部ログ、secret 周辺情報を読める → High
- repo / CI / cloud / DB / ticket / email / deployment への write 権限がある → High〜Critical
- shell 実行、任意コード実行、secret exfiltration、認証情報の外部送信が可能 → Critical
- sub-agent 経由で権限、スコープ、実行回数、影響範囲が拡大する → 1 段階以上引き上げ
- memory/vector store/context cache への poisoning により後続タスクへ持続する → Medium 以上、権限付き agent なら High
- audit 不足により実行主体・根拠・承認者・tool call が追跡不能 → 影響範囲に応じて Low〜High

### 出力フォーマット

```
## セキュリティレビュー: PR #<番号> / <対象>

### サマリー
Critical: N件 / High: N件 / Medium: N件 / Low: N件

### 発見事項

#### [CRITICAL] <タイトル>
- **場所**: `path/to/file.ts:行番号`
- **カテゴリ**: OWASP A0X:2021 / CWE-XXX
- **前提条件**: 攻撃が成立するために必要な条件（認証状態・権限・ネットワーク到達性など）
- **攻撃シナリオ**: 前提条件を満たした攻撃者がどう悪用するか（1〜2文）
- **最悪アクション**: 特に LLM/Agent 系では、騙された結果として実行可能な操作（読み取り・書き込み・外部送信・コード実行・sub-agent 起動）を明示
- **修正**: 具体的な修正方法またはコード例
- **参考**: https://cheatsheetseries.owasp.org/...

### 判定
- 問題なし → マージ可
- Medium 以下のみ → 今スプリント内に対応したうえでマージ可
- High 以上あり → Critical・High を解消してから再レビューを依頼
```

問題が見つからない場合も確認したカテゴリと根拠を明示すること（証拠なき「クリーン」宣言は不可）。
