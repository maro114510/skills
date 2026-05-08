#!/usr/bin/env bash
# fetch-pr-reviews.sh - GitHub PR レビューデータを収集して /tmp/pr-lessons/ に保存する
#
# Usage: bash fetch-pr-reviews.sh <owner/repo> <since-YYYY-MM-DD>
#
# Exit codes:
#   0 - 成功（レビューあり PR が1件以上）
#   1 - PR 0件（期間内に自分の PR が存在しない）
#   2 - 全件スキップ（PR は存在するがレビューなし）
#   3 - 引数不足 / gh 認証エラー
set -euo pipefail

REPO="${1:-}"
SINCE="${2:-}"

if [ -z "${REPO}" ] || [ -z "${SINCE}" ]; then
  echo "Usage: ${0} <owner/repo> <since-YYYY-MM-DD>" >&2
  exit 3
fi

# gh 認証チェック
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI が認証されていません。'gh auth login' を実行してください。" >&2
  gh auth status >&2 || true
  exit 3
fi

# ワークスペース準備
mkdir -p /tmp/pr-lessons/raw
find /tmp/pr-lessons -maxdepth 1 -name "batch-*.md" -delete

# --- Step 3: PR 一覧取得 ---
echo "[1/3] PR 一覧を取得中 (${REPO}, since ${SINCE})..."
gh pr list \
  --author @me \
  --repo "${REPO}" \
  --state all \
  --json number,title,url,createdAt,mergedAt,state \
  --limit 200 \
  > /tmp/pr-lessons/pr-list.json

jq --arg since "${SINCE}T00:00:00Z" \
  '[.[] | select(.createdAt >= $since)]' \
  /tmp/pr-lessons/pr-list.json \
  > /tmp/pr-lessons/pr-list-filtered.json

COUNT=$(jq length /tmp/pr-lessons/pr-list-filtered.json)
echo "       ${COUNT} 件の PR を検出"

if [ "${COUNT}" -eq 0 ]; then
  echo "ERROR: ${SINCE} 以降の PR が見つかりません。'since' の日付を早めてください。" >&2
  exit 1
fi

# --- Step 4: 各 PR のレビューデータ取得 ---
echo "[2/3] 各 PR のレビューを取得中..."
SKIPPED_NUMS=()
SKIPPED_TITLES=()
TOTAL=0

while IFS= read -r pr_json; do
  NUMBER=$(echo "${pr_json}" | jq -r '.number')
  TITLE=$(echo "${pr_json}"  | jq -r '.title')

  # (a) PR 基本情報 + ディスカッションコメント
  if ! gh pr view "${NUMBER}" --repo "${REPO}" \
      --json number,title,body,comments \
      > /tmp/pr-lessons/raw/pr-${NUMBER}-base.json 2>/dev/null; then
    echo "  SKIP #${NUMBER}: データ取得失敗"
    SKIPPED_NUMS+=("${NUMBER}")
    SKIPPED_TITLES+=("${TITLE}")
    continue
  fi

  # (b) レビュー本体（APPROVED / CHANGES_REQUESTED / COMMENTED）
  if ! gh api "repos/${REPO}/pulls/${NUMBER}/reviews" \
      > /tmp/pr-lessons/raw/pr-${NUMBER}-reviews.json 2>/dev/null; then
    echo "  SKIP #${NUMBER}: レビュー取得失敗"
    SKIPPED_NUMS+=("${NUMBER}")
    SKIPPED_TITLES+=("${TITLE}")
    rm -f /tmp/pr-lessons/raw/pr-${NUMBER}-base.json
    continue
  fi

  # (c) インラインレビューコメント
  if ! gh api "repos/${REPO}/pulls/${NUMBER}/comments" \
      > /tmp/pr-lessons/raw/pr-${NUMBER}-inline.json 2>/dev/null; then
    echo "  SKIP #${NUMBER}: インラインコメント取得失敗"
    SKIPPED_NUMS+=("${NUMBER}")
    SKIPPED_TITLES+=("${TITLE}")
    rm -f /tmp/pr-lessons/raw/pr-${NUMBER}-base.json \
          /tmp/pr-lessons/raw/pr-${NUMBER}-reviews.json
    continue
  fi

  # 3ファイルを結合
  jq -s '{
    number:     .[0].number,
    title:      .[0].title,
    body:       .[0].body,
    discussion: .[0].comments,
    reviews:    .[1],
    inline:     .[2]
  }' \
    /tmp/pr-lessons/raw/pr-${NUMBER}-base.json \
    /tmp/pr-lessons/raw/pr-${NUMBER}-reviews.json \
    /tmp/pr-lessons/raw/pr-${NUMBER}-inline.json \
    > /tmp/pr-lessons/raw/pr-${NUMBER}.json

  rm -f /tmp/pr-lessons/raw/pr-${NUMBER}-base.json \
        /tmp/pr-lessons/raw/pr-${NUMBER}-reviews.json \
        /tmp/pr-lessons/raw/pr-${NUMBER}-inline.json

  # レビューあり/なし判定（discussion = gh の comments フィールドを jq で discussion キーにマッピング）
  HAS_CONTENT=$(jq '
    (.reviews    | if type == "array" then length else 0 end) +
    (.inline     | if type == "array" then length else 0 end) +
    (.discussion | if type == "array" then length else 0 end)
  ' /tmp/pr-lessons/raw/pr-${NUMBER}.json)

  if [ "${HAS_CONTENT}" -eq 0 ]; then
    echo "  SKIP #${NUMBER}: レビューなし"
    SKIPPED_NUMS+=("${NUMBER}")
    SKIPPED_TITLES+=("${TITLE}")
    rm -f /tmp/pr-lessons/raw/pr-${NUMBER}.json
    continue
  fi

  echo "  OK   #${NUMBER}: ${TITLE}"
  TOTAL=$((TOTAL + 1))

done < <(jq -c '.[]' /tmp/pr-lessons/pr-list-filtered.json)

# --- 結果サマリをファイルに出力（SKILL.md が参照する）---
echo "[3/3] 結果サマリを出力中..."

jq -n \
  --arg repo   "${REPO}" \
  --arg since  "${SINCE}" \
  --argjson total   "${TOTAL}" \
  --argjson skipped "${#SKIPPED_NUMS[@]}" \
  '{repo: $repo, since: $since, total_with_reviews: $total, total_skipped: $skipped}' \
  > /tmp/pr-lessons/summary.json

# スキップ一覧を JSON で保存
printf '%s\n' "${!SKIPPED_NUMS[@]}" | \
  jq -Rn '[inputs | {"index": .}]' > /dev/null  # 整数インデックス不要なのでシンプルに:
python3 -c "
import json, sys
nums   = sys.argv[1].split('|') if sys.argv[1] else []
titles = sys.argv[2].split('|') if sys.argv[2] else []
print(json.dumps([{'number': int(n), 'title': t} for n, t in zip(nums, titles)]))
" "$(IFS='|'; echo "${SKIPPED_NUMS[*]:-}")" \
  "$(IFS='|'; echo "${SKIPPED_TITLES[*]:-}")" \
  > /tmp/pr-lessons/skipped.json

echo "       レビューあり: ${TOTAL} 件 / スキップ: ${#SKIPPED_NUMS[@]} 件"
echo "       Raw files: $(ls /tmp/pr-lessons/raw/pr-*.json 2>/dev/null | wc -l | tr -d ' ') 件"

if [ "${TOTAL}" -eq 0 ]; then
  echo "ERROR: 全 PR にレビューがありませんでした。" >&2
  exit 2
fi

echo "Done."
