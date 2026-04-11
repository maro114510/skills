---
name: dependabot-review
description: >
  Dependabot の PR を後方互換性の観点でレビューするスキル。
  「dependabotのPRをレビューして」「依存関係の更新を確認して」「dependabotを見て」
  といった依頼で使うこと。引数に PR 番号または URL を渡す。
disable-model-invocation: true
allowed-tools: WebFetch, Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr checks:*), Bash(gh pr review:*)
argument-hint: "<pr-number or url>"
---

# Context

Dependabot の PR に後方互換性を破壊する変更が含まれているかどうかを確認する。

## Your task

- `gh` コマンドを使って PR の内容を確認する
- 後方互換性の問題があれば、その内容を詳しく説明する

## Target

$ARGUMENTS

## MUST

- 回答は日本語のみ
- `gh` コマンドを使って PR を確認する
