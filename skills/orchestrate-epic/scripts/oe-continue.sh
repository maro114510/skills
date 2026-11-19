#!/usr/bin/env bash
# oe continue
#
# Returns an Issue that oe ready parked at its attempt cap, or after starts that pushed nothing, to the loop on the same branch.
# It writes a continue record, so the attempts, the starts in a row that pushed nothing, and the bot rounds before it no longer count,
# and the next oe ready gives the Issue a start-owner again while a repair signal remains.
#
# Usage
#
#   oe continue <owner/repo> <issue-number> [<instruction>]
#
# - Only the orchestrate-epic session runs it, and only after the person said in its conversation to continue the Issue.
#   An Owner or a Verifier never runs it, because a continue lifts the cap that parks an Issue for the person.
# - Without an instruction it writes the continue record on this host and nothing to GitHub.
# - With an instruction it also writes one comment on the Issue, in the format below, and the record holds the instruction and the comment's URL.
#   The comment is an answer record as oe-records.jq reads it, so the next Owner reads it as it reads an answer.
#   The session writes it from the person's own words, never from its own inference.
#
#   <!-- oe:answer -->
#   ### Instruction to continue, recorded by the orchestrate-epic session
#
#   <instruction>
#
#   ---
#   The person gave this instruction in the session's conversation. The next agent reads it and resumes the work.
#
# Admitting
#
# - It counts attempts as oe attempt does, from the records and the head of the Issue branch now.
# - It refuses an Issue that has used fewer than max_attempts attempts and whose latest starts did not all push nothing,
#   because oe ready has not parked it, and a second continue is refused until the Owner it admitted has spent its attempts again.
# - It refuses an Issue whose branch does not exist, because a start with no branch is a claim.
#
# Output
#
# - On success, continue, the attempts and the starts that pushed nothing before the record, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | The continue record was written | The record, and with an instruction a comment on the Issue |
# | 1 | A GitHub read or write failed, the record store failed, or the reader's language could not be resolved | Nothing, or only the comment when the record failed after it |
# | 2 | The arguments are invalid, the instruction is blank, or git config skills.bot is invalid | Nothing |
# | 4 | The Issue is not parked at its cap, or its branch does not exist | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-bot.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe continue <owner/repo> <issue-number> [<instruction>]" >&2
  exit 2
}

fail() {
  echo "oe continue: $1" >&2
  exit 1
}

[[ $# -eq 2 || $# -eq 3 ]] || usage "Expected <owner/repo> <issue-number> [<instruction>]"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
repo="$1"
n="$2"
instruction="${3:-}"
if [[ $# -eq 3 ]]; then
  [[ "${instruction}" =~ [^[:space:]] ]] || usage "The instruction is blank"
fi
bot_def >/dev/null || usage "Invalid git config skills.bot"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

at="$(record_now 2>"${err}")" || usage "$(head -n1 "${err}")"
records="$(records_read "${repo}" "${n}" 2>"${err}")" || fail "$(head -n1 "${err}")"
starts="$(<"${dir}/oe-starts.jq")" || fail "cannot read oe-starts.jq"
issue_query="$(<"${dir}/oe-ready-issue.graphql")" || fail "cannot read oe-ready-issue.graphql"

# The head of the Issue branch now, or null: the one read oe attempt makes of it.
branch_head="$(gh api graphql -f query="${issue_query}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F num="${n}" \
  -f branch="${branch_prefix}${n}" -f ref="refs/heads/${branch_prefix}${n}" \
  --jq '.data.repository.ref.target.oid // null' 2>"${err}")" || fail "Issue #${n} read failed: $(head -n1 "${err}")"
[[ "${branch_head}" == null || "${branch_head}" =~ ^[0-9a-zA-Z]+$ ]] || fail "the branch head of Issue #${n} is unreadable"
if [[ "${branch_head}" == null ]]; then
  echo "oe continue: ${branch_prefix}${n} does not exist, so there is no branch to continue" >&2
  exit 4
fi

used="$(jq -r --arg current "${branch_head}" "${starts}"$'\n''attempts_used($current)' <<<"${records}")" ||
  fail "cannot count the attempts of Issue #${n}"
idle="$(jq -r --arg current "${branch_head}" "${starts}"$'\n''starts_without_push($current)' <<<"${records}")" ||
  fail "cannot count the starts of Issue #${n} that pushed nothing"
if ((used < max_attempts && idle < max_attempts)); then
  echo "oe continue: Issue #${n} used ${used} of ${max_attempts} attempts and is not parked at its cap, so nothing was written" >&2
  exit 4
fi

record="$(jq -cn --arg at "${at}" '{kind: "continue", at: $at}')" || fail "cannot build the record of Issue #${n}"

if [[ -n "${instruction}" ]]; then
  bot_env "${repo}" || fail "cannot act as the Bot on ${repo}"
  lang="$(bash "${dir}/../../create-pr/scripts/lang.sh")"
  case $? in
  0) lang="${lang%% *}" ;;
  2) usage "Invalid reader's language" ;;
  *) fail "cannot resolve the reader's language" ;;
  esac
  if [[ "${lang}" == ja ]]; then
    heading="### orchestrate-epicのセッションが記録した続行の指示"
    closing="この指示はセッションの会話で人が出したものです。次のエージェントが読んで作業を再開します。"
  else
    heading="### Instruction to continue, recorded by the orchestrate-epic session"
    closing="The person gave this instruction in the session's conversation. The next agent reads it and resumes the work."
  fi
  url="$(gh api -X POST "repos/${repo}/issues/${n}/comments" -f body="$(record_marker answer)
${heading}

${instruction}

---
${closing}" --jq '.html_url' 2>"${err}")" || fail "writing the instruction on Issue #${n} failed: $(head -n1 "${err}")"
  record="$(jq -c --arg instruction "${instruction}" --arg url "${url}" '. + {instruction: $instruction, url: $url}' <<<"${record}")" ||
    fail "cannot build the record of Issue #${n}"
fi

records_add "${repo}" "${n}" "${record}" 2>"${err}" ||
  fail "recording the continue of Issue #${n} failed: $(head -n1 "${err}")"
printf 'continue\t%s\t%s\n' "${used}" "${idle}"
