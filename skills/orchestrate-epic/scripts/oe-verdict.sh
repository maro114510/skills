#!/usr/bin/env bash
# oe verdict
#
# Writes a Verifier's verdict on the PR head SHA it checked, and its findings into one block in the PR body.
# The verdict is a commit status on that SHA, so a push leaves the new head without one and nothing else must reset it.
#
# Usage
#
#   oe verdict <owner/repo> <issue-number> <sha> success|failure < findings
#
# - The findings are read from stdin, one line per acceptance criterion, as pr-verify writes them.
#   A line holding `-> unconfirmed` names a criterion the Verifier could not observe.
# - The PR is the open PR from the Issue's branch in this repository.
#
# Writes, in order
#
# 1. The findings block in the PR body, replacing any earlier one, so one block holds the latest verdict.
#    - It is folded, sits between the findings and findings-end markers at the body's end, and names the state and the SHA.
#    - It quotes each failed criterion of a failure and each unconfirmed criterion, in a fenced code block, so no line
#      renders as a task item, and with a word joiner after each `#` and `@` and inside an oe marker, so no closing
#      keyword links, no mention notifies, and no quoted end marker ends the block.
#    - Lines past findings_cap characters are cut whole, and the block says how many.
#    - A success with no unconfirmed criterion removes the block. A body left unchanged is not written.
# 2. The verify_context status on the SHA.
#    oe ready reads it as the verdict.
#
# A success verdict whose findings hold no `-> [behavior]` or `-> [static]` line is still written as success,
# and its status description ends with "but nothing was verified". Refusing it would park the Issue.
#
# The findings go first, so a verdict never exists without its findings.
# Findings whose status write failed leave the SHA without a verdict, which oe ready treats as unverified.
# No PR comment is posted.
# Nothing is written on this host.
#
# Output
#
# - On success, one line holding verdict, the state, and the SHA, separated by tabs.
#
# Exit codes
#
# | Code | Meaning | Changed |
# |---|---|---|
# | 0 | The verdict was written | The PR body when its block changed, and the status |
# | 1 | A GitHub read or write failed | Nothing, or only the PR body when stderr says the status failed |
# | 2 | The arguments are invalid, or the findings are empty | Nothing |
# | 4 | The Issue's branch has no open PR, or its head is no longer the SHA | Nothing |
#
# A push between the head read and the status write leaves the status on the old SHA, which the new head never shows.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-config.sh"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-bot.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe verdict <owner/repo> <issue-number> <sha> success|failure < findings" >&2
  exit 2
}

fail() {
  echo "oe verdict: $1" >&2
  exit 1
}

[[ $# -eq 4 ]] || usage "Expected <owner/repo> <issue-number> <sha> success|failure"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"
[[ "$3" =~ ^[0-9a-f]{40}$ ]] || usage "Invalid SHA, expected 40 hex digits: $3"
[[ "$4" == success || "$4" == failure ]] || usage "Invalid verdict, expected success or failure: $4"
repo="$1"
n="$2"
sha="$3"
state="$4"
branch="${branch_prefix}${n}"
# Characters of quoted findings the block holds, well under the 65536 GitHub allows in a PR body, so the rest of the body still fits.
findings_cap=20000
bot_env "${repo}" || fail "cannot act as the Bot on ${repo}"

findings="$(cat)" || usage "Cannot read the findings from stdin"
[[ "${findings}" =~ [^[:space:]] ]] || usage "The findings on stdin are empty"

err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

found="$(open_pr_head "${repo}" "${branch}" 2>"${err}")" || fail "$(head -n1 "${err}")"
pr="${found%%$'\t'*}"
head="${found#*$'\t'}"

if [[ -z "${pr}" ]]; then
  echo "oe verdict: ${branch} has no open pull request on ${repo}, so nothing was written" >&2
  exit 4
fi
if [[ "${head}" != "${sha}" ]]; then
  echo "oe verdict: PR #${pr} head is ${head}, not ${sha}, so nothing was written" >&2
  exit 4
fi

body="$(gh api "repos/${repo}/pulls/${pr}" --jq '.body // ""' 2>"${err}")" ||
  fail "reading the body of PR #${pr} failed, so no verdict was written: $(head -n1 "${err}")"
updated="$(jq -rn --arg body "${body}" --arg findings "${findings}" --arg state "${state}" --arg sha "${sha}" \
  --arg start "$(record_marker findings)" --arg end "$(record_marker findings-end)" --argjson cap "${findings_cap}" '
  ($body | if test("\r\n") then "\r\n" else "\n" end) as $nl
  # The body without any earlier block; a start marker whose end marker is gone drops the rest of the body.
  | (reduce ($body | split($nl)[]) as $line ({out: [], in: false};
      if .in then (if $line == $end then .in = false else . end)
      elif $line == $start then .in = true
      else .out += [$line] end) | .out | join($nl) | sub("\\s+$"; "")) as $rest
  | [$findings | split("\n")[] | sub("\r$"; "")
      | select(test("->\\s*unconfirmed([^[:alnum:]_]|$)") or ($state == "failure" and test("->\\s*failed:")))
      # Defangs what would take effect: a reference after a closing keyword, a mention, and an oe marker.
      | gsub("#(?<d>[0-9])"; "#\u2060\(.d)") | gsub("@(?<w>[A-Za-z0-9])"; "@\u2060\(.w)")
      | gsub("<!-- oe:"; "<!-- oe\u2060:")] as $lines
  | if $state == "success" and ($lines | length) == 0 then
      (if ($body | split($nl) | index([$start])) == null then $body else $rest end)
    else
      (reduce $lines[] as $line ({kept: [], size: 0, cut: 0};
        if .cut == 0 and .size + ($line | length) + 1 <= $cap then .kept += [$line] | .size += ($line | length) + 1
        else .cut += 1 end)) as $fit
      # A fence longer than any backtick run inside keeps every line, a task item included, as code.
      | ([$fit.kept[] | scan("`+") | length] | max // 0 | [., 2] | max + 1) as $width
      | ("`" * $width) as $fence
      | ([$start, "<details>", "<summary>Verifier \($state) on \($sha)</summary>", "", $fence]
          + $fit.kept + [$fence]
          + (if $fit.cut > 0 then ["", "\($fit.cut) more lines were cut to fit the PR body."] else [] end)
          + ["", "</details>", $end]) as $block
      | (if $rest == "" then [] else [$rest, ""] end) + $block | join($nl)
    end')" || fail "building the findings for PR #${pr} failed, so no verdict was written"
if [[ "${updated}" != "${body}" ]]; then
  gh api -X PATCH "repos/${repo}/pulls/${pr}" -f body="${updated}" --jq '.number' >/dev/null 2>"${err}" ||
    fail "writing the findings in the body of PR #${pr} failed, so no verdict was written: $(head -n1 "${err}")"
fi

description="Verifier ${state} on PR #${pr}"
if [[ "${state}" == success ]] && ! grep -Eq -- '->[[:space:]]*\[(behavior|static)\]' <<<"${findings}"; then
  description="${description}, but nothing was verified"
fi

gh api -X POST "repos/${repo}/statuses/${sha}" -f state="${state}" -f context="${verify_context}" \
  -f description="${description}" --jq '.state' >/dev/null 2>"${err}" ||
  fail "recorded the findings, but writing the ${verify_context} status on ${sha} failed: $(head -n1 "${err}")"
printf 'verdict\t%s\t%s\n' "${state}" "${sha}"
