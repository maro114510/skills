#!/usr/bin/env bash
# oe question
#
# Writes an Owner's question on its Issue as a question record, or records the person's answer to it as an answer record,
# or the person's request to judge the same head again as a re-run request record.
# oe ready then waits on the Issue until the person answers, through this command or with an unmarked comment.
#
# Usage
#
#   oe question <owner/repo> <issue-number> < question
#   oe question <owner/repo> <issue-number> --answer <reply>
#   oe question <owner/repo> <issue-number> --rerun [<decision>]
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
# - It answers the Issue's latest hold or question record, as oe-records.jq reads records.
#   A hold has no options and no Decision line, so its decision is named by the hold's URL.
# - A reply that is one option's letter, in either case, records that option with its label. Any other reply is recorded as written.
#
#   <!-- oe:answer -->
#   ### Answer to the question, recorded by the orchestrate-epic session
#
#   <question URL>
#
#   <the chosen option, or the reply>
#
# - Before the answer record, it appends the decision to the decisions section of the Issue body, the only part of the Issue the Verifier reads.
#   The section is headed `## Decisions`, or `## 決定事項` in ja, and is added at the body's end with a note saying that
#   each decision takes precedence over the criteria it contradicts, and a later one over an earlier one.
#   Every other line of the body stays as it was, and a decision already in the section is not appended again.
#   An answer given as a comment on the Issue never reaches the section.
#
#   - <the question's Decision line>
#     - <the chosen option, or the reply>
#     - <question URL>
#
# Requesting a re-run
#
# - Only the orchestrate-epic session runs --rerun, when the person asks in its conversation for the PR's head to be judged again.
#   The request is no answer, so oe ready starts a Verifier on the same head instead of an Owner.
# - It is accepted only while the Issue waits on the person, with a hold or a question newer than the latest answer and the latest re-run request,
#   and the head of the Issue branch's open PR has a failure verdict.
#   The verdict is the head's latest verify status other than pending that is newer than the latest re-run request, both on GitHub's clock.
# - The optional decision goes into the decisions section as an answer's reply does, under the question's Decision line, or the hold's URL,
#   and a request without one leaves the Issue body unchanged.
#
#   <!-- oe:rerun -->
#   ### Re-run request, recorded by the orchestrate-epic session
#
#   <hold or question URL>
#
#   <the decision, when given>
#
# Exit codes
#
# | Code | Meaning | Changed on GitHub |
# |---|---|---|
# | 0 | The question, the answer, or the re-run request was written, and its kind and URL printed, separated by a tab | The record, and for an answer or a re-run request its decision in the Issue body |
# | 1 | A GitHub read or write failed, or the reader's language could not be resolved | Nothing, or only the decision when the record failed after it; a rerun then writes the record alone |
# | 2 | The arguments are invalid, the question breaks the template, or the reply or the decision is empty or a letter no option has | Nothing |
# | 3 | The Issue has no hold or question to answer, or for --rerun, none newer than the latest answer and re-run request | Nothing |
# | 4 | For --rerun, the Issue branch has no open PR, or its head has no failure verdict | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-bot.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe question <owner/repo> <issue-number> < question" >&2
  echo "       oe question <owner/repo> <issue-number> --answer <reply>" >&2
  echo "       oe question <owner/repo> <issue-number> --rerun [<decision>]" >&2
  exit 2
}

fail() {
  echo "oe question: $1" >&2
  exit 1
}

[[ $# -eq 2 || ($# -eq 4 && "$3" == --answer) || (($# -eq 3 || $# -eq 4) && "$3" == --rerun) ]] ||
  usage "Expected <owner/repo> <issue-number> [--answer <reply> | --rerun [<decision>]]"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"
bot_env "${repo}" || fail "cannot act as the Bot on ${repo}"

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

# Prints the Issue's comments as one JSON array in the shape oe-records.jq reads.
# REST names a bot login with a [bot] suffix and its type in user.type, where oe-records.jq reads GraphQL's shape.
issue_comments() {
  local comments
  comments="$(gh api "repos/${repo}/issues/${n}/comments?per_page=100" --paginate --jq '.[]' 2>"${err}")" ||
    fail "reading the comments of Issue #${n} failed: $(head -n1 "${err}")"
  jq -cs 'map({authorAssociation: .author_association, body, url: .html_url, createdAt: .created_at,
      author: {login: ((.user.login // "") | sub("\\[bot\\]$"; "")), __typename: (.user.type // "User")}})' \
    <<<"${comments}" 2>"${err}" || fail "the comments of Issue #${n} are unreadable: $(head -n1 "${err}")"
}

# Appends the decision entry the JSON object on stdin gives, with decision, answer, and url, to the decisions section of the Issue body.
# An entry already in the section is not appended again, so a rerun after the record write failed changes nothing.
add_to_decisions() {
  local entry body updated section note
  entry="$(cat)"
  if [[ "${lang}" == ja ]]; then
    section="決定事項"
    note="このIssueの質問にエンジニアが出した決定です。各決定は矛盾する基準より優先し、後の決定は先の決定より優先します。"
  else
    section="Decisions"
    note="Decisions the engineer made on this Issue's questions. Each takes precedence over the criteria it contradicts, and a later one over an earlier one."
  fi
  body="$(gh api "repos/${repo}/issues/${n}" --jq '.body // ""' 2>"${err}")" ||
    fail "reading the body of Issue #${n} failed: $(head -n1 "${err}")"
  updated="$(jq -r --arg body "${body}" --arg heading "${section}" --arg note "${note}" \
    "${rules}"$'\n''decision_entry(.decision; .answer; .url) as $entry
    | if ($body | gsub("\r"; "") + "\n" | contains($entry + "\n")) then empty else $body | add_decision($heading; $note; $entry) end' \
    <<<"${entry}" 2>"${err}")" || fail "composing the decision for Issue #${n} failed: $(head -n1 "${err}")"
  if [[ -n "${updated}" ]]; then
    gh api -X PATCH "repos/${repo}/issues/${n}" -f body="${updated}" >/dev/null 2>"${err}" ||
      fail "writing the decision in the body of Issue #${n} failed: $(head -n1 "${err}")"
  fi
}

# Writes the comment body $1 on the Issue and prints the record kind $2 and the comment's URL, separated by a tab.
post() {
  local url
  url="$(gh api -X POST "repos/${repo}/issues/${n}/comments" -f body="$1" --jq '.html_url' 2>"${err}")" ||
    fail "writing the $2 on Issue #${n} failed: $(head -n1 "${err}")"
  printf '%s\t%s\n' "$2" "${url}"
}

if [[ "${3-}" == --rerun ]]; then
  decision="${4-}"
  [[ $# -eq 3 || "${decision}" =~ [^[:space:]] ]] || usage "The decision is empty"
  trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
  bot="$(bot_def)" || usage "Invalid git config skills.bot"
  comments="$(issue_comments)" || exit 1
  # The wait is open when a hold or a question is newer than every answer and every re-run request, as oe ready's row 2 reads it.
  open="$(jq -c "${bot}"$'\n'"${trust}"$'\n'"${rules}"$'\n''
    . as $c
    | [range(0; length) | select($c[.] | record("question") or record("hold"))] as $waits
    | [range(0; length) | select(. as $i | $c[$i] | record("answer") or ($waits[0] != null and $i > $waits[0] and engineer_input))] as $answers
    | [range(0; length) | select($c[.] | record("rerun"))] as $reruns
    | ($waits | last) as $wait
    | ($wait != null and $wait > ([$answers[-1], $reruns[-1]] | map(. // -1) | max)) as $waiting
    | {wait: (if $waiting then $c[$wait].url else null end), decision: (if $waiting then $c[$wait].body | decision_line else null end),
        rerun_at: (if ($reruns | length) > 0 then $c[$reruns[-1]].createdAt else null end)}' <<<"${comments}" 2>"${err}")" ||
    fail "the comments of Issue #${n} are unreadable: $(head -n1 "${err}")"
  url="$(jq -r '.wait // empty' <<<"${open}")"
  if [[ -z "${url}" ]]; then
    echo "oe question: Issue #${n} does not wait on the person, so no re-run request was written" >&2
    exit 3
  fi
  found="$(open_pr_head "${repo}" "${branch_prefix}${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
  sha="${found#*$'\t'}"
  verdict=none
  if [[ -n "${found}" ]]; then
    # Statuses come newest first, so the first one other than pending that is newer than the latest re-run request is the verdict.
    verdict="$(gh api "repos/${repo}/commits/${sha}/statuses?per_page=100" --paginate \
      --jq '.[] | select(.context == "'"${verify_context}"'" and .state != "pending") | "\(.created_at)\t\(.state)"' 2>"${err}" |
      jq -rR --argjson open "${open}" 'def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
        [., inputs | split("\t") | select($open.rerun_at == null or (.[0] | epoch) > ($open.rerun_at | epoch)) | .[1]]
        | first // "none"' 2>>"${err}")" || fail "status read for ${sha} failed: $(head -n1 "${err}")"
  fi
  if [[ "${verdict}" != failure && "${verdict}" != error ]]; then
    echo "oe question: the PR head of Issue #${n} has no failure verdict, so no re-run request was written" >&2
    exit 4
  fi
  if [[ "${lang}" == ja ]]; then
    heading="### orchestrate-epicのセッションが記録した再判定の依頼"
    closing="この依頼はセッションの会話で人が出したものです。次の検証エージェントが同じheadを判定し直します。"
  else
    heading="### Re-run request, recorded by the orchestrate-epic session"
    closing="The person asked for this in the session's conversation. The next Verifier judges the same head again."
  fi
  record="$(record_marker rerun)
${heading}

${url}
"
  if [[ $# -eq 4 ]]; then
    # The decision goes into the body before the record, so the Verifier the request starts reads it.
    jq -c --arg answer "${decision}" '{decision, answer: $answer, url: .wait}' <<<"${open}" | add_to_decisions || exit 1
    record+="
${decision}
"
  fi
  post "${record}
---
${closing}" rerun
  exit 0
fi

if [[ $# -eq 4 ]]; then
  reply="$4"
  [[ "${reply}" =~ [^[:space:]] ]] || usage "The reply is empty"
  trust="$(<"${dir}/oe-records.jq")" || fail "cannot read oe-records.jq"
  bot="$(bot_def)" || usage "Invalid git config skills.bot"
  comments="$(issue_comments)" || exit 1
  question="$(jq -c "${bot}"$'\n'"${trust}"$'\n'"${rules}"$'\n''
    map(select(record("question") or record("hold"))) | last
    | if . == null then null else {url, options: (.body | options), decision: (.body | decision_line)} end' <<<"${comments}" 2>"${err}")" ||
    fail "the comments of Issue #${n} are unreadable: $(head -n1 "${err}")"
  if [[ "${question}" == null ]]; then
    echo "oe question: Issue #${n} has no hold or question to answer" >&2
    exit 3
  fi
  trimmed="${reply#"${reply%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  answer="${reply}"
  decided="${trimmed}"
  if [[ "${trimmed}" =~ ^[A-Da-d]$ ]]; then
    letter="$(tr '[:lower:]' '[:upper:]' <<<"${trimmed}")"
    answer="$(jq -r --arg letter "${letter}" '.options[] | select(.letter == $letter) | "\(.letter). \(.label)"' <<<"${question}")"
    [[ -n "${answer}" ]] || usage "The question has no option ${letter}"
    decided="${answer}"
  fi
  url="$(jq -r .url <<<"${question}")"
  if [[ "${lang}" == ja ]]; then
    heading="### orchestrate-epicのセッションが記録した質問への回答"
    closing="この回答はセッションの会話で人が出したものです。次のエージェントが読んで作業を再開します。"
  else
    heading="### Answer to the question, recorded by the orchestrate-epic session"
    closing="The person gave this answer in the session's conversation. The next agent reads it and resumes the work."
  fi
  # The decision goes into the body before the answer record, so the Verifier sees it whenever the next Owner starts.
  # A rerun after the answer write failed finds its decision already there and appends nothing.
  jq -c --arg answer "${decided}" '{decision, answer: $answer, url}' <<<"${question}" | add_to_decisions || exit 1
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
