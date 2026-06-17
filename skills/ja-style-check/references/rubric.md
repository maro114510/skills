# Japanese Style Rubric

Use this rubric when drafting, reviewing, or revising Japanese prose. Prioritize reader comprehension over preserving the writer's original rhythm.

## Severity

- `high`: the reader cannot reliably understand who does what, what the sentence means, or why the claim matters.
- `medium`: the text is understandable but causes rereading, avoidable ambiguity, or implementation-oriented wording.
- `low`: the issue is local and mostly affects rhythm or polish.

Do not understate severity when the whole text is dominated by code identifiers, unexplained symbols, hidden actors, bracketed supplements, implementation traces, or headings that hide the argument.

## Checks

### 1. Line Breaks

Japanese sentences should normally end with `。` before a line break. Flag meaningless line breaks inside a sentence. Ignore Markdown headings, lists, tables, code blocks, long URLs, and commands.

Bad:
- `この処理はユーザーの入力を受け取り`
- `次の画面へ進みます。`

Good:
- `この処理はユーザーの入力を受け取り次の画面へ進みます。`

### 2. Brackets

Flag frequent parenthetical supplements. Keep only first-use definitions such as `OMS（受注管理システム）`. Treat units, timing notes, attributes, internal IDs, and action notes inside brackets as rewrite candidates.

Bad:
- `注文を確定します（自動処理）。`

Good:
- `システムが注文を自動で確定します。`

### 3. Meta Prose

Flag prose that announces itself instead of saying the content: `まず説明します`, `以下に示します`, `本節では`, `以上を踏まえると`, `つまり`, `これにより`. Delete or rewrite only when no information is lost.

Bad:
- `まず認証の流れについて説明します。ユーザーはメールアドレスでログインします。`

Good:
- `ユーザーはメールアドレスでログインします。`

### 4. Vague Claims

Flag vague words and weak claims: `適切に`, `必要に応じて`, `十分に`, `基本的に`, `可能なら`, `考慮する`, `担保する`, `ある程度`, `なるべく`. Ask for conditions, scope, thresholds, examples, or impact.

Flag unsupported importance claims: `重要です`, `影響は大きい`, `リスクは高い`, `価値がある`, `求められます`. Replace declarations with concrete effects or remove them.

Flag empty contrast: `A ではなく B`, `重要なのは A ではなく B`. Prefer the direct assertion unless the negated assumption is genuinely likely.

Bad:
- `必要に応じて適切にリトライします。`

Good:
- `通信が 5 秒以内に完了しない場合、最大 3 回までリトライします。`

### 5. Mechanical 80-Character Wraps

Flag consecutive lines around 78 to 82 characters when the break does not follow meaning or punctuation.

Bad:
- Meaningless line breaks appear only because the line reached a fixed character count.

Good:
- Break lines at headings, list items, tables, code blocks, or sentence boundaries.

### 6. Paragraphs and Rhythm

Flag paragraphs over 10 sentences, mixed topics in one paragraph, concepts introduced before their prerequisites, repeated short dramatic fragments, repeated long sentences, and monotonous list items.

Bad:
- One paragraph explains background, problem, decision, implementation, and risk together.

Good:
- Separate background, problem, decision, implementation, and risk into distinct paragraphs.

### 7. First-Use Definitions

Flag unexplained abbreviations, domain terms, project names, person names, and organization names when the intended reader may not know them. Do not flag common technical terms such as API, GitHub, JSON, OAuth, or Webhook when explanation would be noisier than the term.

Bad:
- `OMS が注文を確定します。`

Good:
- `OMS（受注管理システム）が注文を確定します。`

### 8. Reader-Facing Japanese

Flag English jargon, code identifiers, file paths, internal IDs, section references, raw boolean expressions, passive voice, hidden actors, and inanimate subjects when they obscure the reader-facing meaning.

Ask "who does this?", "can the reader understand this without opening another file?", and "does this sound like natural Japanese when read aloud?"

Bad:
- `isPaid が true の場合、order_status を更新します。`

Good:
- `支払いが完了した注文を確定済みにします。`

### 9. Implementation Transcription

Flag prose that copies control flow or implementation structure: `flag が true なら`, `A かつ B のとき`, `フラグを立てる`, `処理する`, or mixed identifiers and Japanese that cannot be read naturally. Rewrite toward the user-visible behavior.

Bad:
- `配列をループして条件に一致する要素を処理します。`

Good:
- `条件に一致する注文だけを通知対象にします。`

### 10. Structure and Headings

Flag prose whose section order or headings hide the logic. Headings should expose the relationship between ideas, not merely label a topic. Check whether the text moves from the reader's question to the answer, then to evidence or detail. Abstract-to-concrete order is useful for explanations and decisions, but narrative or problem-solution order may fit better when the reader needs context first.

Bad:
- `概要` -> `詳細` -> `補足` with no visible problem, decision, reason, or consequence.
- A section starts with implementation details before stating the problem or conclusion.

Good:
- `Problem` -> `Decision` -> `Reason` -> `Impact`
- `Conclusion` -> `Conditions` -> `Steps` -> `Examples`
- `Current Behavior` -> `Issue` -> `Proposed Behavior` -> `Risk`

Evidence:
- Text structure instruction has positive effects on reading comprehension in meta-analysis and later reviews: https://ila.onlinelibrary.wiley.com/doi/full/10.1002/rrq.311
- Headings can improve text comprehension and calibration of comprehension: https://onlinelibrary.wiley.com/doi/full/10.1002/acp.4076
- Recent work on changing informational text structure suggests structure affects comprehension, with reader ability influencing which structure helps: https://link.springer.com/article/10.1007/s11145-026-10791-8
- Japanese technical-writing norms also emphasize paragraph-level roles, concrete headings, and avoiding empty section labels: https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d

### 11. Argument Rigor

Flag claims that overstate, collapse distinctions, or leave causal gaps. Do not mechanically turn uncertainty into certainty. Keep uncertainty when it represents incomplete evidence, reader doubt, inference from logs, or a counterfactual. When the text claims cause and effect, require the mechanism. When an example supports only part of a claim, narrow the claim.

Bad:
- `この設計にすると問題は解決します。`
- `契約の不在とログ不足は同じ問題です。`

Good:
- `この設計では、入力形式が固定されている範囲に限り、検証漏れを減らせます。`
- `契約の不在は合意の問題であり、ログ不足は調査可能性の問題です。`

### 12. Reader Load

Flag details that force the reader to remember names, numbers, files, tools, examples, or actors that the later argument never uses. Keep concrete details that support the current question; remove decorative precision. When introducing a new example, state how it differs from the previous one.

Bad:
- `2026-06-17 14:03:22 に job-retry-v2 が 502 を返し、worker_billing_sync.go の 184 行目で失敗しました。`

Good:
- `請求同期のジョブが外部 API の失敗で止まりました。ここでは、失敗時に再実行できるかだけを扱います。`

### 13. Voice and Perspective

Flag needless fictional personas, direct second-person address in argument, generic actors such as `AI` or `ツール`, and passive result lists. Use role names and visible actions. Keep terminology stable after introducing it; do not retreat to broader words that blur the target.

Bad:
- `あなたは AI に任せればよいと感じるかもしれません。結果が特定され、原因が判明します。`

Good:
- `開発者は調査をエージェントに任せられます。エージェントはログを読み、失敗したジョブを特定します。`

### 14. Notation and Emphasis

Flag decorative notation that carries structure instead of prose: dashes in Japanese sentences, middle dots for ordinary parallel terms, bold used as decoration, and headings that pack two ideas with separators. Use punctuation and sentence order instead. Use bold only for first-use definitions or logical points that prevent misreading.

Bad:
- `原因——ログ不足——を確認します。`
- `設計・実装・運用を改善します。`
- `補足──再試行の注意点`

Good:
- `原因はログ不足です。これを確認します。`
- `設計、実装、運用を改善します。`
- `再試行で注意する条件`

## Drafting Rule

When writing new Japanese prose, apply this rubric before returning the answer. Prefer short direct sentences, explicit actors, concrete conditions, reader-facing behavior, stable terminology, and headings that reveal the argument. Avoid announcing what the text will do.
