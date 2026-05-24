# LLM / Agent Security Review Reference

LLM apps、AI coding agents、MCP、tool/function calling、RAG、memory、
multi-agent/sub-agent、model supply chain の変更をレビューするときだけ読む。

出典:
- OWASP Top 10 for LLM Applications 2025: https://genai.owasp.org/llm-top-10/
- OWASP Top 10 for Agentic Applications 2026: https://genai.owasp.org/2025/12/09/owasp-genai-security-project-releases-top-10-risks-and-mitigations-for-agentic-ai-security/
- OWASP Top 10 for Model Context Protocol 2025: https://owasp.org/www-project-mcp-top-10/
- OWASP MCP Tool Poisoning: https://owasp.org/www-community/attacks/MCP_Tool_Poisoning
- ARGUS: Defending LLM Agents Against Context-Aware Prompt Injection: https://arxiv.org/abs/2605.03378
- Authenticated Workflows: A Systems Approach to Protecting Agentic AI: https://arxiv.org/abs/2602.10465
- OpenMythos reference pattern: https://github.com/kyegomez/OpenMythos

---

## レビュー原則

- Prompt はセキュリティ境界ではない。
- Untrusted text は命令ではなくデータとして隔離する。
- Tool call 境界で deterministic policy check を行う。
- 権限は agent、task、tool、invocation ごとに最小化する。
- サブエージェントに親の権限を暗黙継承させない。
- 重大度は「騙された入力」ではなく「騙された結果として実行可能な最悪アクション」で決める。
- 外部コンテンツ、tool output、RAG 結果、Issue/PR コメント、メール、Web ページ、
  README、ログ、モデル出力、checkpoint metadata は攻撃者制御の可能性がある。

---

## 対象変更の例

| 差分に含まれるもの | 追加で確認する信頼境界 |
|---|---|
| system/developer prompt | 外部入力との混在、prompt template、secret 注入箇所 |
| RAG / embedding / vector DB | ingest 元、metadata、tenant 分離、検索結果の命令扱い |
| tool/function calling | tool allowlist、schema validation、危険引数、承認フロー |
| MCP client/server | tool description、capability claim、auth、scope、runtime response |
| coding agent / shell tool | sandbox、filesystem/network 範囲、secret 参照、command policy |
| AGENTS.md / CLAUDE.md / repo instructions | 外部入力扱い、権限要求、tool 実行指示、上位命令への昇格 |
| sub-agent / multi-agent | delegation policy、権限継承、再帰上限、agent 間通信 |
| memory / scratchpad | 永続化範囲、tenant 分離、poisoned instruction の再注入 |
| model/tokenizer/dataset/checkpoint | pinning、provenance、trust_remote_code、pickle/torch.load |

---

## OWASP LLM Top 10 対応チェック

### LLM01 Prompt Injection

- ユーザー入力、RAG 結果、tool output、Web/メール/Issue/PR コメントが上位命令として扱われないか
- 「ignore previous instructions」系だけでなく、要約・翻訳・コードレビュー対象内の隠れ命令も評価する
- HTML comments、Markdown links、base64、OCR 結果、ログ、ファイル名、metadata から命令が混入しないか

### LLM02 Sensitive Information Disclosure

- model prompt、tool output、logs、memory、vector store に secrets/PII/private repo 情報が混入しないか
- エージェントが機密ファイルを読める場合、外部送信 tool との組み合わせを評価する

### LLM03 Supply Chain / LLM04 Data and Model Poisoning

- model、tokenizer、dataset、adapter、checkpoint、prompt package、MCP server を pin しているか
- `trust_remote_code=True`、pickle checkpoint、`torch.load(..., weights_only=False)` を未検証入力に使っていないか
- dataset/RAG ingest に poisoning 対策、source provenance、削除・無効化手段があるか

### LLM05 Improper Output Handling

- LLM 出力を shell、SQL、Python/JS eval、template、HTML、HTTP request、GitHub write API に直接渡していないか
- structured output の schema validation と deny-by-default policy があるか

### LLM06 Excessive Agency

- agent に不要な write、delete、deploy、send、purchase、cloud、DB、filesystem、network 権限がないか
- high-impact tool は実行前に具体的な引数を人間へ表示し、承認後も policy check を行うか

### LLM08 Vector and Embedding Weaknesses

- tenant 間で vector store が混在しないか
- retrieved content を「参考データ」として扱い、instruction として実行しないか
- malicious document の永続化、再ランキング、metadata spoofing による検索汚染を評価する

### LLM10 Unbounded Consumption

- context length、max output、loop/retry、tool call 数、sub-agent 数、recursion depth、cost、timeout に上限があるか
- 攻撃者入力で高額推論、長時間 shell、無限再帰、大量 API 呼び出しが起きないか

---

## Agentic AI 追加チェック

### ASI01 Agent Goal Hijack

- 外部入力が agent の goal、plan、task decomposition、priority を上書きできないか
- agent が「ユーザーの本来の目的」と「外部コンテンツ内の命令」を区別しているか

### ASI02 Tool Misuse and Exploitation

- tool call は構文的に正しくても、目的外・破壊的・外部送信・大量取得にならないか
- read tool と write/send/deploy tool の連鎖で exfiltration や改ざんが成立しないか

### ASI03 Identity and Privilege Abuse

- agent token がユーザー token、service token、admin token として過剰権限を持たないか
- sub-agent や MCP server に token がそのまま渡らないか

### ASI04 Agentic Supply Chain Vulnerabilities

- skills、plugins、MCP servers、agent manifests、repository-level config が実行層として扱われているか
- untrusted repo を開くだけで hook、tool、skill、prompt、script が実行されないか

### ASI05 Unexpected Code Execution

- natural language、Markdown、config、tool response、model output が shell/code execution に到達しないか
- generated code を実行する前に sandbox、review、test、network/secret 制限があるか

### ASI06 Memory and Context Poisoning

- memory に保存する前に source、trust level、expiry、tenant、task scope を付けているか
- 過去の untrusted instruction が将来の高権限タスクへ再注入されないか

### ASI07 Insecure Inter-Agent Communication

- agent 間メッセージに送信者認証、権限境界、schema、provenance があるか
- 子 agent の提案を親 agent が trusted command として実行しないか

### ASI08 Cascading Failures

- 1 つの誤った判断が sub-agent、CI、deployment、ticket、email、cloud 操作へ連鎖しないか
- fail closed、rollback、rate limit、blast radius control があるか

### ASI09 Human-Agent Trust Exploitation

- agent が危険操作を安全そうに要約して承認を誘導しないか
- 承認 UI は実際の tool、対象、権限、外部送信先、差分、コストを表示するか

### ASI10 Rogue Agents

- agent が監査、policy、approval、sandbox を迂回できないか
- 長時間実行 agent に kill switch、session expiry、credential rotation があるか

---

## MCP 固有チェック

- MCP token は短命・scope 限定・server ごとに分離されているか
- tool description と runtime response の両方を untrusted として扱うか
- tool schema、hidden parameters、default values、side effects を確認しているか
- shadow MCP server や未承認 server へ接続できないか
- context over-sharing により別 user/task/agent の情報が混入しないか
- tool invocation、context changes、approval/denial、server identity を audit log に残すか

---

## サブエージェント再帰の必須チェック

サブエージェントを再帰的に使う設計では、以下を 1 つでも欠く場合は重大リスクとして扱う。

- 親 agent の権限が子 agent に暗黙継承されない
- 子 agent がさらに子 agent を作る場合、再帰深度と総数に上限がある
- agent ごとに filesystem、network、secret、tool、write 権限が分離されている
- 子 agent の出力は「提案」として扱い、親が policy check と検証を行う
- 子 agent 間で memory、scratchpad、secrets、credentials を共有しない
- どの agent が、どの context を根拠に、どの action を提案・実行したか追跡できる
- read-only agent、analysis agent、executor agent の権限分離がある
- 外部から取得したテキストを子 agent が上位命令として親 agent に返せない

危険な連鎖:

```text
親 agent: repo write token + shell + secrets access
  -> 子 agent: 同じ権限を継承
    -> Issue/README/Web content を読む
      -> indirect prompt injection を受ける
        -> executor agent を起動
          -> secret 読み取り / git push / CI 改ざん / 外部送信
```

この連鎖が成立する場合、prompt injection は単独の Medium ではなく High〜Critical と評価する。

---

## 重大度補正

| 条件 | 補正 |
|---|---|
| 読み取り専用チャットで外部副作用なし | Low〜Medium |
| private data / PII / internal logs / secrets 周辺情報へ到達可能 | High |
| write/delete/deploy/send/cloud/DB 操作が可能 | High〜Critical |
| shell/RCE/secret exfiltration が可能 | Critical |
| sub-agent 再帰で権限や影響範囲が拡大 | 1 段階以上引き上げ |
| memory/vector store へ永続化され後続タスクに再発火 | Medium 以上、権限付き agent なら High |
| audit 不足で追跡不能 | 影響範囲に応じて Low〜High |

---

## 問題なし判定の根拠

LLM/Agent 系で問題なしと判断する場合も、少なくとも以下を明記する。

- どの外部入力源を確認したか
- どの tool / MCP / sub-agent / memory 経路を確認したか
- dangerous action に到達する経路がなぜないか
- 最小権限、承認、監査、上限、永続化制御のどれで防いでいるか
