#!/usr/bin/env bash
# pr-doc-review-textlint.sh
# Detects ambiguity vocabulary and weak phrases in Markdown files.
#
# Used by the pr-doc-review-pe skill in Step 2.
# Authoritative word list:
#   skills/pr-doc-review-pe/references/layer3-ai-instruction.md
#   § Ambiguity Vocabulary Detection
#
# Usage: pr-doc-review-textlint.sh <file1.md> [file2.md ...]
# Always exits 0. Findings to stdout.
#
# Fallback chain (Markdown-aware → less precise):
#   1. textlint  (local install with rules)
#   2. textlint  (via npx, cached — no network needed)
#   3. textlint  (via mise)
#   4. rg        (always available; code blocks NOT excluded)

set -uo pipefail

if [[ $# -eq 0 ]]; then
  printf 'Usage: pr-doc-review-textlint.sh <file1.md> [file2.md ...]\n' >&2
  exit 1
fi

FILES=("$@")

# Word list: keep in sync with layer3-ai-instruction.md § Ambiguity Vocabulary Detection
AMBIGUITY_RG_PATTERN="適切に|適切な|必要に応じて|十分に|いい感じに|だいたい|可能なら|考慮する|担保する|基本的に"

# ---- helpers ----

_make_prh_yml() {
  cat << 'EOF'
version: 1
rules:
  - expected: "[要具体化: 条件・範囲・閾値を明記]"
    patterns:
      - {pattern: 適切に}
      - {pattern: 適切な}
      - {pattern: 必要に応じて}
      - {pattern: 十分に}
      - {pattern: いい感じに}
      - {pattern: だいたい}
      - {pattern: 可能なら}
      - {pattern: 考慮する}
      - {pattern: 担保する}
      - {pattern: 基本的に}
EOF
}

# Run textlint with the ambiguity rule config.
# $@: textlint binary (may be multiple words, e.g. npx textlint)
# On config/runtime error (ec>=2), falls back to rg automatically.
_run_textlint() {
  local prh rc ec=0
  prh=$(mktemp /tmp/prh.XXXXXX.yml)
  rc=$(mktemp /tmp/textlintrc.XXXXXX.json)
  _make_prh_yml > "${prh}"
  printf '{"rules":{"textlint-rule-ja-no-weak-phrase":true,"textlint-rule-prh":{"rulePaths":["%s"]}}}\n' \
    "${prh}" > "${rc}"
  "$@" --config "${rc}" --format pretty-error "${FILES[@]}" 2>&1 || ec=$?
  rm -f "${prh}" "${rc}"
  if [[ ${ec} -ge 2 ]]; then
    printf '(textlint ルールエラー — rg にフォールバック)\n'
    _rg_fallback
  fi
}

_rg_fallback() {
  printf '## 曖昧語チェック (rg フォールバック — コードブロック未除外)\n'
  rg -n "${AMBIGUITY_RG_PATTERN}" "${FILES[@]}" 2>/dev/null || true
  printf '\n💡 Markdown-aware な精密検査には textlint を推奨:\n'
  printf '   npm install -D textlint textlint-rule-ja-no-weak-phrase textlint-rule-prh\n'
}

# ---- fallback chain ----

if command -v textlint >/dev/null 2>&1; then
  printf '## 曖昧語チェック (textlint)\n'
  _run_textlint textlint

elif command -v npx >/dev/null 2>&1 \
     && npx --no-install textlint --version >/dev/null 2>&1; then
  printf '## 曖昧語チェック (textlint via npx cached)\n'
  _run_textlint npx textlint

elif command -v mise >/dev/null 2>&1 \
     && mise exec -- textlint --version >/dev/null 2>&1; then
  printf '## 曖昧語チェック (textlint via mise)\n'
  _run_textlint mise exec -- textlint

else
  _rg_fallback
fi

exit 0
