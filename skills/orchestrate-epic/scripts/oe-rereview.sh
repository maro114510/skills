#!/usr/bin/env bash
# oe rereview
#
# Asks the bots whose rounds the latest attempt used to review the pull request again.
# An Owner runs it after the push that repaired their findings, so no engineer relays the request.
#
# Usage
#
#   oe rereview <owner/repo> <issue-number>
#
# Asking
#
# - The bots are the ones named by the latest attempt record on this host, so the Owner asks those and no other.
#   A round is used once an attempt record names its bot, as oe-bots.jq describes.
# - Each bot gets one pull request comment of its own marker line and its mention, such as `@coderabbitai review`.
#   The marker keeps the comment from counting as engineer input, and a bot reads the mention to start a review.
# - Every mention is read before any comment is written, so an unlisted bot writes nothing.
# - An attempt that used no bot round writes nothing, so an Owner runs this after any push.
#
# Output
#
# - On success, one line holding rereview and the number of comments written, separated by a tab.
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The requests were written, or the latest attempt used no bot round | one comment per bot, or nothing |
# | 1 | A read or write failed, or a recorded bot is not listed | nothing, or the comments written before the failure |
# | 2 | The arguments are invalid | nothing |
# | 4 | The Issue branch has no open pull request | nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe rereview <owner/repo> <issue-number>" >&2
  exit 2
}

fail() {
  echo "oe rereview: $1" >&2
  exit 1
}

refuse() {
  echo "oe rereview: $1, so nothing was written" >&2
  exit 4
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <issue-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"
branch="${branch_prefix}${n}"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

records="$(records_read "${repo}" "${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
bots="$(jq -c '(map(.kind == "attempt") | rindex(true)) as $latest
  | (if $latest == null then [] else (.[$latest].bots // []) end) | unique' <<<"${records}")" ||
  fail "cannot read the bot rounds of Issue #${n}"
jq -e 'type == "array" and all(.[]; type == "string")' <<<"${bots}" >/dev/null 2>&1 ||
  fail "the bot rounds of Issue #${n} are unreadable"
if [[ "$(jq 'length' <<<"${bots}")" -eq 0 ]]; then
  printf 'rereview\t0\n'
  exit 0
fi

found="$(open_pr_head "${repo}" "${branch}" 2>"${err}")" || fail "$(head -n1 "${err}")"
pr="${found%%$'\t'*}"
[[ -n "${pr}" ]] || refuse "${branch} has no open pull request on ${repo}"

bot_rules="$(<"${dir}/oe-bots.jq")" || fail "cannot read oe-bots.jq"
mentions=()
while read -r bot; do
  [[ -n "${bot}" ]] || continue
  mention="$(jq -nr --arg login "${bot}" "${bot_rules}"$'\n''bot_mention($login) // empty')" ||
    fail "cannot read what asks ${bot} to review again"
  [[ -n "${mention}" ]] || fail "${bot} is not a listed review bot"
  mentions+=("${bot}"$'\t'"${mention}")
done < <(jq -r '.[]' <<<"${bots}")

written=0
while IFS=$'\t' read -r bot mention; do
  [[ -n "${bot}" ]] || continue
  body="$(record_marker rereview)"$'\n'"${mention}"
  gh api -X POST "repos/${repo}/issues/${pr}/comments" -f body="${body}" --jq '.html_url' >/dev/null 2>"${err}" ||
    fail "asking ${bot} to review PR #${pr} again failed: $(head -n1 "${err}")"
  written=$((written + 1))
done < <(printf '%s\n' "${mentions[@]}")
printf 'rereview\t%s\n' "${written}"
