---
name: manage-design-documents
description: >
  Decide whether a change needs a Design Doc, an ADR, both, or neither, then create, revise, delete, or review them.
  Use for "write a design doc", "add an ADR", "update the design doc", "設計ドキュメントを書いて", "ADR を書いて", "Design Doc を更新して".
allowed-tools: Read, Glob, Grep, Edit, Write, AskUserQuestion, Bash(git grep:*, git rm:*, gh issue list:*, gh pr list:*)
argument-hint: "[change or decision to document | document path to review]"
---

# manage-design-documents

Work in the repository the user names, otherwise the current one. Never commit, push, or open a pull request.

- A Design Doc states what a system or domain is meant to be, implemented or not. It never states how it is built (algorithms, classes, full API or schema, deployment), how it was decided, how far it is implemented, every edge case, coding conventions, or slogans.
- An ADR records one consequential decision and why, not the investigation behind it.
- Never add status, authors, dates, a changelog, an owner, or an approval state to either.

## 1. Decide

Read the repository instructions, the related Design Docs and ADRs, and the code the request concerns. Then:

- If the request changes the concepts, responsibilities, boundaries, behavior, state, or guarantees of a system or domain, update the Design Doc that covers them. Create one only when none does, never one per feature or Issue.
- If it makes a choice that has real alternatives and is costly to reverse, write an ADR. If it replaces or retracts an existing ADR, delete that ADR as section 3 says, and list it as an alternative in any new one.
- Otherwise, as for a routine feature or an implementation edit, write nothing, and say why.

Never change the design to match code or an Issue. Where they differ in what the request concerns, ask which is wrong; report other differences. Code that does not implement the design yet is not a difference.

Ask, all at once and most important first, only when the sources cannot settle the design or a wrong guess could corrupt data, expose a security hole, break a contract, or be irreversible. Leave out any other rule nobody stated, without asking; never invent one.

## 2. Write

Put documents where the repository keeps them; otherwise use `docs/design/<subject>.md` and `docs/adr/<decision-slug>.md`, unnumbered. Write a new document in the language `bash <skills-root>/create-pr/scripts/lang.sh` prints, where `<skills-root>` is this skill's parent directory, and stop if it exits non-zero. Write an edit in the language of the document it edits.

Follow `references/design-doc.md` or `references/adr.md` in this skill's directory. Change only what the request changes, and leave existing content outside the format, such as a Status field, as it is. Before finishing, cut anything you wrote that repeats or serves no purpose.

## 3. Delete an ADR

Delete without asking only when the request replaces or retracts the ADR; ask when it only seems obsolete. Move any part that still applies into the replacing ADR, or cut the ADR down to that part instead of deleting it. Fix every reference `git grep` finds by its file name, and delete with `git rm`. If `git rm` refuses, Git does not hold the current content, so ask.

## 4. Find Stale Copies

When section 2 or 3 changed or removed a decision, search for the terms that name it or its values, and the changed documents' file names: the repository with `git grep`, and open Issues and pull requests with `gh issue list` and `gh pr list` using `--state open --search "<term>" --limit 100 --json number,title,url,body`. Report each hit outside those documents that the change makes false, edit none, and say which search could not run.

## 5. Review

When asked to review a document, read the matching reference, then list each violation of this skill as `<file:line>: <rule> -> <fix>`, and edit nothing.

## Output

Reply in the user's language with the decision and its reason, the files changed, and the differences or existing format deviations left unresolved, and each stale copy as `<file:line or URL>: <what it states> -> <what the decision is now>`.
