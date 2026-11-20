#!/usr/bin/env bash
# oe hold
#
# Records that an Issue waits on the person, with the reason oe ready gave, as one Issue comment.
# oe ready then gives the Issue wait-answer until the session records the person's answer with oe question --answer.
#
# Usage
#
#   oe hold <owner/repo> <issue-number> <reason>
#
# - oe ready prints this command, filled in, as the fourth field of each hold line.
# - Only the orchestrate-epic session runs it. The session also shows the reason in its conversation, because the comment is the record of the wait, never its only notice.
# - The comment is written in the language create-pr's lang.sh resolves:
#
#   <!-- oe:hold -->
#   ### The orchestrate-epic session holds this Issue for the person
#
#   <reason>
#
#   ---
#   Answer in the orchestrate-epic session's conversation. ...
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The hold was written, and hold and the comment's URL printed, separated by a tab | One Issue comment |
# | 1 | A GitHub write failed, or the reader's language could not be resolved | Nothing |
# | 2 | The arguments are invalid, or the reason is empty | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-bot.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe hold <owner/repo> <issue-number> <reason>" >&2
  exit 2
}

fail() {
  echo "oe hold: $1" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage "Expected <owner/repo> <issue-number> <reason>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
[[ "$3" =~ [^[:space:]] ]] || usage "The reason is empty"
repo="$1"
n="$2"
reason="$3"
bot_env "${repo}" || fail "cannot act as the Bot on ${repo}"

lang="$(bash "${dir}/../../create-pr/scripts/lang.sh")"
case $? in
0) lang="${lang%% *}" ;;
2) usage "Invalid reader's language" ;;
*) fail "cannot resolve the reader's language" ;;
esac
if [[ "${lang}" == ja ]]; then
  heading="### orchestrate-epicのセッションがこのIssueを人の判断待ちにしました"
  closing="orchestrate-epicのセッションの会話で回答してください。セッションが回答を記録すると、次のエージェントが読んで作業を再開します。"
else
  heading="### The orchestrate-epic session holds this Issue for the person"
  closing="Answer in the orchestrate-epic session's conversation. The session records the answer, and the next agent reads it and resumes the work."
fi

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT
url="$(gh api -X POST "repos/${repo}/issues/${n}/comments" -f body="$(record_marker hold)
${heading}

${reason}

---
${closing}" --jq '.html_url' 2>"${err}")" || fail "writing the hold on Issue #${n} failed: $(head -n1 "${err}")"
printf 'hold\t%s\n' "${url}"
