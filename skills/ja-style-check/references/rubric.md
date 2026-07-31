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

A parenthetical supplement is a violation, not a risk signal. Severity is `high`. Rewrite the content into the sentence, or delete it.

The single exception is a first-use definition: a bracket whose entire content gives the meaning, full name, or Japanese rendering of the term immediately before it. `OMS（受注管理システム）` qualifies. The exception covers first use only. The same term bracketed again later is a violation.

Nothing else survives. Units, numbers, attributes, timing, actions, state, conditions, reasons, internal IDs, and cross-references all belong in the sentence.

Markdown syntax is not prose. Link and image targets, code spans, code blocks, and URLs are out of scope. So are half-width parentheses inside an English sentence, which are English punctuation — judge by which script carries the sentence, as in Check #8.

This rule applies to all document types — design docs, implementation plans, and README files are not exempt. The reduced-severity exception in Check #8 applies only to SKILL.md and references/ files.

Bad:
- `注文を確定します（自動処理）。`
- `認証エラーを修正します（PR #123）。`
- `月予算（単位：円）を設定します。`
- `再試行します（最大 3 回）。`

Good:
- `システムが注文を自動で確定します。`
- `認証エラーを修正する PR #123 で対応します。`
- `月予算を円単位で設定します。`
- `最大 3 回まで再試行します。`

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

Flag long paragraphs, mixed topics in one paragraph, concepts introduced before their prerequisites, repeated short dramatic fragments, repeated long sentences, and monotonous list items. Do not split mechanically — many sentence endings with no blank line is a candidate for judgment, not an automatic violation. When a paragraph lists conditions, steps, criteria, scope, or consequences, use bullets.

Bad:
- One paragraph explains background, problem, decision, implementation, and risk together.

Good:
- Separate background, problem, decision, implementation, and risk into distinct paragraphs.
- Use bullets when conditions, steps, criteria, scope, or consequences are easier to scan as a list.

### 7. First-Use Definitions

Flag unexplained abbreviations, domain terms, project names, person names, organization names, PR numbers, issue numbers, ticket IDs, commit hashes, and internal references when the intended reader may not know them. Do not flag common technical terms such as API, GitHub, JSON, OAuth, or Webhook when explanation would be noisier than the term. A raw reference is acceptable only when nearby prose tells the reader what it is without opening the linked item.

Bad:
- `OMS が注文を確定します。`
- `PR #123 で対応します。`
- `AUTH-456 を確認してください。`

Good:
- `OMS（受注管理システム）が注文を確定します。`
- `認証エラーを修正する PR #123 で対応します。`
- `ログイン失敗時の再試行を扱う AUTH-456 を確認してください。`

### 8. Reader-Facing Japanese

Latin script inside a Japanese sentence is a violation by default. Severity is `high` when the reader cannot act without decoding it, `medium` otherwise. Rewrite it into the Japanese term the document already uses, or into plain Japanese naming what it does.

The target is Latin inside a Japanese sentence, not the reverse. Japanese quoted inside an English sentence — as this rubric's own examples do — is not a violation. Ask which script carries the sentence, not how much English it holds; judging by quantity lets a sentence escape the rule precisely by carrying more untranslated English.

No scanner rule covers this check. Apply it by reading. A deterministic version was attempted and withdrawn because it kept missing real violations, so a clean finding list says nothing about Latin script.

Allowed without rewriting:

- Code identifiers, flags, mode names, commands, and file paths **inside backticks or a code block**. The bare, unquoted form is a violation.
- URLs.
- Proper nouns and product names with no established Japanese form, such as GitHub, Slack, Markdown, Spanner, macOS, npm, and gRPC. There is no fixed list; judge whether a Japanese rendering exists and is in use.
- All-caps acronyms of two to six letters, such as API, JSON, and HTTP. These belong to Check #7, which asks whether the reader was given a definition.

Capitalisation does not earn an exemption on its own. `Deprecated`, `Pending`, and `Active` are ordinary English words in Japanese prose and are violations exactly as `invalid` is.
- Numbers, units, and symbols.
- An abbreviation at the point where its Check #7 first-use definition introduces it.
- PR numbers, issue numbers, ticket IDs, and commit hashes, still subject to Check #7.

**Quote runtime literals; do not translate them.** `report` and `fix` are strings the user types. Rendering them as 報告 or 修正 breaks the interface, so wrap them in backticks instead.

Bad:
- `report モードではファイルを変更しません。` — bare runtime literal
- `この値が invalid のとき停止します。` — bare English word

Good:
- `` `report` モードではファイルを変更しません。``
- `この値が不正なとき停止します。`

Separately, flag passive voice, hidden actors, and inanimate subjects when they obscure who acts. For PR numbers, issue numbers, ticket IDs, commit hashes, and file paths, check whether the prose explains what the reference means before relying on it.

Ask "who does this?", "can the reader understand this without opening another file?", and "does this sound like natural Japanese when read aloud?"

Two layers apply. Clearing the allowlist above does not exempt a backticked identifier from the assignment-notation rule below.

**Assignment-notation is high severity.** Flag implementation identifiers (variable names, flag names, table names, function names) that appear as prose actors, conditions, or value assignments — the reader cannot understand the referent without opening source code. Patterns include `identifier = value`, `` `identifier` が value ``, and any bare identifier acting as a prose subject.

Do not treat first-use definitions as assignment-notation (see Check #7). Compare:
- Acceptable: `` `report` モードはファイルを変更しません。`` — one introduction with visible meaning
- Violation: `` `report` が実行された場合に〜 `` — same identifier used as prose actor after definition

Exception: internal agent specification files (SKILL.md, references/) that define a schema or parameter term once for agent consumption are medium, not high, when the context makes the term's meaning clear.

Bad (high / assignment-notation):
- `isPaid = true のとき、order_status を active に設定します。`
- `` `isPaid` が true の場合、`order_status` を更新します。``
- `hogehoge = active のとき処理を行います。`

Bad (medium / general):
- `処理が実行されます。` — hidden actor, passive voice

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
- Meta-analysis and later reviews: structure instruction improves reading comprehension. https://ila.onlinelibrary.wiley.com/doi/full/10.1002/rrq.311
- Headings improve comprehension and its calibration. https://onlinelibrary.wiley.com/doi/full/10.1002/acp.4076
- Structure affects comprehension, and reader ability decides which structure helps. https://link.springer.com/article/10.1007/s11145-026-10791-8
- Japanese technical-writing norms: paragraph-level roles, concrete headings, no empty section labels. https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d

### 11. Argument Rigor

Flag claims that overstate, collapse distinctions, or leave causal gaps. Do not mechanically turn uncertainty into certainty. Keep uncertainty when it represents incomplete evidence, reader doubt, inference from logs, or a counterfactual. When the text claims cause and effect, require the mechanism. When an example supports only part of a claim, narrow the claim.

Bad:
- `この設計にすると問題は解決します。`
- `契約の不在とログ不足は同じ問題です。`

Good:
- `この設計では、入力形式が固定されている範囲に限り、検証漏れを減らせます。`
- `契約の不在は合意の問題であり、ログ不足は調査可能性の問題です。`

### 12. Reader Load

Flag details that force the reader to remember names, numbers, files, tools, examples, or actors that the later argument never uses. Keep concrete details that support the current question; remove decorative precision. When introducing a new example, state how it differs from the previous one. Do not rely on PR numbers, issue numbers, ticket IDs, commit hashes, or file paths as the only explanation of a claim.

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

Flag decorative notation that carries structure instead of prose: dashes in Japanese sentences, bold used as decoration, and headings that pack two ideas with separators. Use punctuation and sentence order instead. Use bold only for first-use definitions or logical points that prevent misreading.

Bad:
- `原因——ログ不足——を確認します。`
- `補足──再試行の注意点`

Good:
- `原因はログ不足です。これを確認します。`
- `再試行で注意する条件`

## Drafting Rule

When writing new Japanese prose, apply this rubric before returning the answer. Prefer short direct sentences, explicit actors, concrete conditions, reader-facing behavior, stable terminology, and headings that reveal the argument. Avoid announcing what the text will do.
