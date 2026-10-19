#!/usr/bin/env bash
# Classifies the default-branch health after this loop's latest merge, so no further PR merges
# onto a default branch whose checks have not passed. The merge it judges is the one named by the
# loop's sticky post-merge record on the Epic, written before every merge request, so a restart
# between the merge and its checks still finds it. Read-only: it never posts or edits a comment.
# Usage: base-health.sh <owner/repo> <epic-number>          query GitHub
#        base-health.sh --snapshot <file|-> --me <login>     classify a saved
#          {comments: <REST comment array>, pull: <GraphQL response or null>, now: <ISO-8601>}
# Output, one per line: status=<CLEAR|PASS|PENDING|FAIL|UNCONFIRMED|HANDLED|UNREADABLE>, reason=,
#   record_id=, then pr= and issue= when a record exists, merge= when its PR merged, then
#   next=<proceed|wait|freeze|hold>.
#   CLEAR       no record, or the recorded PR did not merge          next=proceed
#   PASS        every check on the merge commit passed               next=proceed
#   PENDING     a check is pending, none reported yet, or all passed next=wait
#               but PASS_SETTLE seconds have not elapsed since merge
#   FAIL        a check on the merge commit did not pass             next=freeze
#   UNCONFIRMED a check was cancelled, none reported NO_CHECKS_GRACE  next=freeze
#               seconds after the merge, or one still pending
#               PENDING_LIMIT seconds after it
#   HANDLED     FAIL or UNCONFIRMED, already named by a freeze this  next=proceed
#               loop posted with the same `- merge:` and `- health:`,
#               so the freeze and its epic-release own it
#   UNREADABLE  a signal could not be read                           next=hold
# Exit: 0 classified, 1 a signal could not be read (status=UNREADABLE), 2 usage error.
# Merge only on next=proceed; every other result holds every merge.
set -uo pipefail

# Seconds since mergedAt. PASS_SETTLE lets a slower workflow create its checks before an early,
# all-passing set counts as healthy; PENDING_LIMIT turns a check that never finishes, such as a job
# waiting for environment approval, into a freeze instead of an endless, silent wait.
PASS_SETTLE=120
NO_CHECKS_GRACE=600
PENDING_LIMIT=3600

usage() {
  echo "$1" >&2
  echo "Usage: base-health.sh <owner/repo> <epic-number> | --snapshot <file|-> --me <login>" >&2
  exit 2
}

hold() {
  printf 'status=UNREADABLE\nreason=%s\nnext=hold\n' "$1"
  exit 1
}

RECORD_MARKER='<!-- orchestrate-epic:post-merge -->'

# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
QUERY='query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      number state mergedAt
      mergeCommit { oid statusCheckRollup { state
        contexts(first: 100) { totalCount nodes { __typename
          ... on CheckRun { name status conclusion startedAt checkSuite { databaseId } }
          ... on StatusContext { context state createdAt } } } } }
    }
  }
}'

# The latest comment by $me whose body starts with $m, as epic-freeze.sh reads its own markers, so a
# record planted by anyone else can neither pick the merge to judge nor hide one.
# shellcheck disable=SC2016 # jq program, not shell expansion.
COMMON='
  def mine($m): [.[] | select(.user.login == $me and ((.body // "") | startswith($m)))]
    | sort_by(.created_at, .id) | last;
  def field($name): (.body // "") | split("\n")
    | map(capture("^- " + $name + ":\\s*(?<v>.*?)\\s*$").v) | first;'

# check_class and latest_checks follow pr-readiness.sh, so a check counts the same before and after
# its merge, except that ACTION_REQUIRED, a human hold there, is a failure here: a merge that already
# landed cannot wait for one, and CANCELLED, usually a run superseded by a later push, leaves health
# unconfirmed rather than failed. Every check counts, required or not, and nothing but a pass ever
# confirms health: timed out, stale, or asking for human action is a failure.
# shellcheck disable=SC2016 # jq program, not shell expansion.
CLASSIFY="${COMMON}"'
  def check_name: .name // .context // "unnamed check";
  def check_class:
    if .__typename == "CheckRun" then
      if (.status | type) != "string" then "unreadable"
      elif .status != "COMPLETED" then "pending"
      elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "pass"
      elif .conclusion == "CANCELLED" then "cancelled"
      elif (.conclusion | type) == "string" then "failed"
      else "unreadable" end
    elif .__typename == "StatusContext" then
      if .state == "SUCCESS" then "pass"
      elif .state == "PENDING" or .state == "EXPECTED" then "pending"
      elif (.state | type) == "string" then "failed"
      else "unreadable" end
    else "unreadable" end;
  def check_key($i):
    if .__typename == "StatusContext" then ["status", check_name]
    elif (.checkSuite.databaseId | type) == "number" then ["suite", (.checkSuite.databaseId | tostring), check_name]
    else ["unkeyed", ($i | tostring)] end;
  def latest_checks: to_entries | map(. as $e | $e.value | {key: check_key($e.key), value: .})
    | group_by(.key)
    | map(map(.value) | sort_by((.startedAt // .createdAt) as $t | [$t == null, $t // ""]) | last);
  def unreadable($r): {status: "UNREADABLE", reason: $r};

  if type != "object" or (.comments | type) != "array" or any(.comments[]; type != "object")
  then unreadable("comments are not an array of objects")
  else
    .now as $now | .pull as $pull
    | .comments as $comments
    | ($comments | mine("'"${RECORD_MARKER}"'")) as $record
    | if ($record | not) then {status: "CLEAR", reason: "no loop merge recorded", record_id: "none"}
      else
        {record_id: $record.id, pr: ($record | field("pr")), issue: ($record | field("issue"))} as $base
        | if ($base.pr // "" | test("^[1-9][0-9]*$") | not) or ($base.issue // "" | test("^[1-9][0-9]*$") | not)
          then $base + unreadable("post-merge record \($record.id) has no readable pr or issue")
          elif ($pull | type) != "object" then $base + unreadable("no pull request read for PR #\($base.pr)")
          elif ($pull.errors // null) != null then $base + unreadable("GraphQL errors: \([$pull.errors[]?.message] | join(", "))")
          elif ($pull.data.repository.pullRequest | type) != "object" then $base + unreadable("PR #\($base.pr) not found in response")
          else $pull.data.repository.pullRequest
          | if (.number | tostring) != $base.pr then $base + unreadable("response is for PR #\(.number), not #\($base.pr)")
            elif .state == "OPEN" or .state == "CLOSED" then
              $base + {status: "CLEAR", reason: "PR #\($base.pr) not merged (\(.state)); nothing landed"}
            elif .state != "MERGED" then $base + unreadable("PR state \(.state // "missing")")
            elif (.mergeCommit.oid | type) != "string" then $base + unreadable("merged PR #\($base.pr) has no merge commit")
            else
              .mergeCommit.oid as $merge
              | ($base + {merge: $merge}) as $base
              | .mergeCommit.statusCheckRollup as $rollup
              | if $rollup != null and (($rollup.contexts.nodes | type) != "array" or ($rollup.contexts.totalCount | type) != "number")
                then $base + unreadable("checks missing on \($merge)")
                elif $rollup != null and $rollup.contexts.totalCount > ($rollup.contexts.nodes | length)
                then $base + unreadable("checks truncated on \($merge) (\($rollup.contexts.totalCount) > \($rollup.contexts.nodes | length))")
                else
                  ($rollup.contexts.nodes // [] | latest_checks | map({name: check_name, class: check_class})) as $checks
                  | ($checks | map(select(.class == "unreadable") | "check state missing: \(.name)")) as $bad
                  | ($checks | map(select(.class == "failed") | "check failed: \(.name)")) as $failed
                  | ($checks | map(select(.class == "pending") | "check pending: \(.name)")) as $pending
                  | ($checks | map(select(.class == "cancelled")
                      | "check cancelled, possibly superseded by a later push: \(.name)")) as $cancelled
                  | (try (($now | fromdateiso8601) - (.mergedAt | fromdateiso8601)) catch null) as $age
                  | if ($bad | length) > 0 then $base + unreadable($bad | join("; "))
                    elif ($failed | length) > 0 then $base + {status: "FAIL", reason: ($failed | join("; "))}
                    elif $age == null then $base + unreadable("merge time or current time unreadable")
                    elif ($pending | length) > 0 and $age >= '"${PENDING_LIMIT}"' then $base + {status: "UNCONFIRMED",
                      reason: "still pending \($age)s after merge, such as a job awaiting approval: \($pending | join("; "))"}
                    elif ($pending | length) > 0 then $base + {status: "PENDING", reason: ($pending | join("; "))}
                    elif ($cancelled | length) > 0 then $base + {status: "UNCONFIRMED", reason: ($cancelled | join("; "))}
                    elif ($checks | length) > 0 and $age < '"${PASS_SETTLE}"' then $base + {status: "PENDING",
                      reason: "checks on \($merge) passed so far; settling until every workflow has reported (\($age)s since merge)"}
                    elif ($checks | length) > 0 then $base + {status: "PASS", reason: "every check on \($merge) passed"}
                    elif $age < '"${NO_CHECKS_GRACE}"' then
                      $base + {status: "PENDING", reason: "no checks reported on \($merge) yet (\($age)s since merge)"}
                    else $base + {status: "UNCONFIRMED",
                      reason: "no checks reported on \($merge) \($age)s after merge; health cannot be confirmed"}
                    end
                  | if .status == "FAIL" or .status == "UNCONFIRMED" then
                      .status as $status
                      | ([$comments[] | select(.user.login == $me
                          and ((.body // "") | startswith("<!-- orchestrate-epic:freeze -->"))
                          and field("merge") == $merge and field("health") == $status)]
                        | sort_by(.created_at, .id) | first) as $frozen
                      | if $frozen then . + {status: "HANDLED",
                          reason: "\(.status) on \($merge) already frozen by freeze \($frozen.id): \(.reason)"}
                        else . end
                    else . end
                end
            end
          end
      end
  end
  | (if .status == "CLEAR" or .status == "PASS" or .status == "HANDLED" then "proceed"
     elif .status == "PENDING" then "wait"
     elif .status == "FAIL" or .status == "UNCONFIRMED" then "freeze"
     else "hold" end) as $next
  | "status=\(.status)", "reason=\(.reason)",
    (if .record_id != null then "record_id=\(.record_id)" else empty end),
    (if .pr != null then "pr=\(.pr)" else empty end),
    (if .issue != null then "issue=\(.issue)" else empty end),
    (if .merge != null then "merge=\(.merge)" else empty end),
    "next=\($next)"'

classify() {
  local snapshot="$1" me="$2" result
  [[ -n "${snapshot}" ]] || hold "empty response"
  result="$(jq -r --arg me "${me}" "${CLASSIFY}" <<<"${snapshot}" 2>/dev/null)" ||
    hold "response is not JSON of the expected shape"
  printf '%s\n' "${result}"
  grep -qxF 'status=UNREADABLE' <<<"${result}" && exit 1
  exit 0
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

if [[ "${1:-}" == --snapshot ]]; then
  [[ $# -eq 4 && "$3" == --me && -n "$4" ]] || usage "--snapshot needs a file or - and --me <login>"
  if [[ "$2" == - ]]; then
    classify "$(cat)" "$4"
  else
    [[ -r "$2" ]] || usage "Cannot read snapshot: $2"
    classify "$(cat "$2")" "$4"
  fi
fi

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
repo="$1"
epic="$2"

err="$(mktemp)" || hold "mktemp failed"
trap 'rm -f "${err}"' EXIT
me="$(gh api user --jq .login 2>"${err}")" && [[ -n "${me}" ]] ||
  hold "gh api user failed: $(head -n1 "${err}")"
comments="$(
  set -o pipefail
  gh api "repos/${repo}/issues/${epic}/comments" --paginate --slurp 2>"${err}" | jq -c 'add // []'
)" ||
  hold "comment read failed: $(head -n1 "${err}")"
# shellcheck disable=SC2016 # jq program, not shell expansion.
pr="$(jq -r --arg me "${me}" "${COMMON}"' mine("'"${RECORD_MARKER}"'") // {} | field("pr") // ""' \
  <<<"${comments}" 2>/dev/null)" || hold "comments are not JSON of the expected shape"
pull=null
if [[ "${pr}" =~ ^[1-9][0-9]*$ ]]; then
  pull="$(gh api graphql -f query="${QUERY}" -f owner="${repo%/*}" -f repo="${repo#*/}" -F num="${pr}" 2>"${err}")" ||
    hold "gh api graphql failed: $(head -n1 "${err}")"
fi
classify "$(jq -cn --argjson c "${comments}" --argjson p "${pull}" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{comments: $c, pull: $p, now: $now}' 2>/dev/null)" "${me}"
