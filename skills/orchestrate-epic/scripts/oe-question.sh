#!/usr/bin/env bash
# oe question
#
# Writes an Owner's question on its Issue as a question record.
# oe ready then waits on the Issue until an engineer answers with an unmarked comment.
#
# Usage
#
#   oe question <owner/repo> <issue-number> < question
#
# Asking
#
# - The question is read from stdin, and must follow skills/shared/question.md in the reader's language,
#   with a letter on each option, as oe-question.jq checks. Anything else is refused and writes nothing.
# - The reader's language is the one create-pr's lang.sh resolves.
# - The question is written into the format below, after the marker, with the heading and the closing line in the reader's language.
#   The heading says an agent asks, because the comment is posted under the user's account.
#
#   <!-- oe:question -->
#   ### Question from the orchestrate-epic agent working on this Issue
#
#   <question>
#
#   ---
#   Answer in the orchestrate-epic session's conversation, or with a comment on this Issue, ...
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The question was written, and its kind and URL printed, separated by a tab | The question record |
# | 1 | The GitHub write failed, or the reader's language could not be resolved | Nothing |
# | 2 | The arguments are invalid, or the question is empty or breaks the template | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe question <owner/repo> <issue-number> < question" >&2
  exit 2
}

fail() {
  echo "oe question: $1" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <issue-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"

lang="$(bash "${dir}/../../create-pr/scripts/lang.sh")"
case $? in
0) lang="${lang%% *}" ;;
2) usage "Invalid reader's language" ;;
*) fail "cannot resolve the reader's language" ;;
esac
rules="$(<"${dir}/oe-question.jq")" || fail "cannot read oe-question.jq"
rules="def lang: \"${lang}\";"$'\n'"${rules}"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

# Writes the comment body $1 on the Issue and prints the record kind $2 and the comment's URL, separated by a tab.
post() {
  local url
  url="$(gh api -X POST "repos/${repo}/issues/${n}/comments" -f body="$1" --jq '.html_url' 2>"${err}")" ||
    fail "writing the $2 on Issue #${n} failed: $(head -n1 "${err}")"
  printf '%s\t%s\n' "$2" "${url}"
}

question="$(cat)" || usage "Cannot read the question from stdin"
[[ "${question}" =~ [^[:space:]] ]] || usage "The question on stdin is empty"
problems="$(jq -Rsr "${rules}"$'\n''problems' <<<"${question}" 2>"${err}")" ||
  fail "checking the question failed: $(head -n1 "${err}")"
if [[ -n "${problems}" ]]; then
  {
    echo "oe question: the question does not follow skills/shared/question.md, so nothing was written:"
    while IFS= read -r problem; do
      echo "- ${problem}"
    done <<<"${problems}"
  } >&2
  exit 2
fi

if [[ "${lang}" == ja ]]; then
  heading="### このIssueを担当するorchestrate-epicのエージェントからの質問"
  closing="orchestrate-epicのセッションの会話か、このIssueへのコメントで回答してください。選択肢の記号でも自由な文章でも構いません。次のエージェントが回答を読んで作業を再開します。"
else
  heading="### Question from the orchestrate-epic agent working on this Issue"
  closing="Answer in the orchestrate-epic session's conversation, or with a comment on this Issue, by an option's letter or in your own words. The next agent reads it and resumes the work."
fi
post "$(record_marker question)
${heading}

${question}

---
${closing}" question
