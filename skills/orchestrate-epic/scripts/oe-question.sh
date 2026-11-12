#!/usr/bin/env bash
# oe question
#
# Writes an Owner's question on its Issue as a question record, or records the person's answer to it as an answer record.
# oe ready then waits on the Issue until the person answers, through this command or with an unmarked comment.
#
# Usage
#
#   oe question <owner/repo> <issue-number> < question
#   oe question <owner/repo> <issue-number> --answer <reply>
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
# Answering
#
# - Only the orchestrate-epic session runs --answer, with the reply the person gave in its conversation.
#   An Owner or a Verifier never runs it, because the answer counts as the person's even when the agents' bot writes it.
# - It answers the Issue's latest question record, as oe-records.jq reads records, from the latest claim on, as oe ready reads it.
# - A reply that is one option's letter, in either case, records that option with its label. Any other reply is recorded as written.
#
#   <!-- oe:answer -->
#   ### Answer to the question, recorded by the orchestrate-epic session
#
#   <question URL>
#
#   <the chosen option, or the reply>
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The question or the answer was written, and its kind and URL printed, separated by a tab | The record |
# | 1 | A GitHub read or write failed, or the reader's language could not be resolved | Nothing |
# | 2 | The arguments are invalid, the question breaks the template, or the reply is empty or a letter no option has | Nothing |
# | 3 | The Issue has no question to answer since its latest claim | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe question <owner/repo> <issue-number> < question" >&2
  echo "       oe question <owner/repo> <issue-number> --answer <reply>" >&2
  exit 2
}

fail() {
  echo "oe question: $1" >&2
  exit 1
}

[[ $# -eq 2 || ($# -eq 4 && "$3" == --answer) ]] || usage "Expected <owner/repo> <issue-number> [--answer <reply>]"
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

if [[ $# -eq 4 ]]; then
  reply="$4"
  [[ "${reply}" =~ [^[:space:]] ]] || usage "The reply is empty"
  trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
  bot="$(bot_def)" || usage "Invalid git config skills.bot"
  issue_records="$(records_read "${repo}" "${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
  claimed_at="$(jq -r '[.[] | select(.kind == "claim") | .at] | last // ""' <<<"${issue_records}")" ||
    fail "records of Issue #${n} unreadable"
  comments="$(gh api "repos/${repo}/issues/${n}/comments?per_page=100" --paginate --jq '.[]' 2>"${err}")" ||
    fail "reading the comments of Issue #${n} failed: $(head -n1 "${err}")"
  # REST names a bot login with a [bot] suffix and its type in user.type, where oe-records.jq reads GraphQL's shape.
  question="$(jq -cs --arg claimed_at "${claimed_at}" "${bot}"$'\n'"${trust}"$'\n'"${rules}"$'\n''
    map({authorAssociation: .author_association, body, url: .html_url, createdAt: .created_at,
      author: {login: ((.user.login // "") | sub("\\[bot\\]$"; "")), __typename: (.user.type // "User")}})
    | map(select(record("question") and .createdAt >= $claimed_at)) | last
    | if . == null then null else {url, options: (.body | options)} end' <<<"${comments}" 2>"${err}")" ||
    fail "the comments of Issue #${n} are unreadable: $(head -n1 "${err}")"
  if [[ "${question}" == null ]]; then
    echo "oe question: Issue #${n} has no question to answer since its latest claim" >&2
    exit 3
  fi
  trimmed="${reply#"${reply%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  answer="${reply}"
  if [[ "${trimmed}" =~ ^[A-Da-d]$ ]]; then
    letter="$(tr '[:lower:]' '[:upper:]' <<<"${trimmed}")"
    answer="$(jq -r --arg letter "${letter}" '.options[] | select(.letter == $letter) | "\(.letter). \(.label)"' <<<"${question}")"
    [[ -n "${answer}" ]] || usage "The question has no option ${letter}"
  fi
  url="$(jq -r .url <<<"${question}")"
  if [[ "${lang}" == ja ]]; then
    heading="### orchestrate-epicのセッションが記録した質問への回答"
    closing="この回答はセッションの会話で人が出したものです。次のエージェントが読んで作業を再開します。"
  else
    heading="### Answer to the question, recorded by the orchestrate-epic session"
    closing="The person gave this answer in the session's conversation. The next agent reads it and resumes the work."
  fi
  post "$(record_marker answer)
${heading}

${url}

${answer}

---
${closing}" answer
  exit 0
fi

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
