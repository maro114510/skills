# The decision logic of oe ready.
# oe-ready.sh passes every GitHub response through these definitions with gh --jq.
# oe-ready.sh defines these values in front of this file.
#
# | Name | Value |
# |---|---|
# | now_s | The current time in epoch seconds |
# | no_checks_grace | Seconds a commit may go without checks before its CI counts as missing |
# | max_attempts | Owner attempts after the latest claim before the Issue parks |
# | max_verifier_starts | Verifier starts on one commit before the Issue parks |
# | verify_context | The commit status context that holds the verdict |
# | pr_heads | The verdict, the Verifier starts, and the push time of each open pull request head |

def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;

# The positions in an array whose element matches f.
def indexes(f): . as $a | [range(0; length) | select($a[.] | f)];

# Who counts
#
# | Signal | Rule |
# |---|---|
# | Trusted author | The author association is OWNER, MEMBER, or COLLABORATOR |
# | Record | A comment by a trusted author whose body starts with the record's marker |
# | Engineer input | A comment or review by a trusted author whose body does not start with the oe marker prefix |
#
# | Record | Marker |
# |---|---|
# | Claim | `<!-- oe:claim -->` |
# | Attempt | `<!-- oe:attempt -->` |
# | Question | `<!-- oe:question -->` |
def trusted: (.authorAssociation // "") as $a | $a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR";
def record($kind): trusted and ((.body // "") | startswith("<!-- oe:\($kind) -->"));
def engineer_input: trusted and ((.body // "") | startswith("<!-- oe:") | not);

# CI
#
# ci reduces a commit's checks to one state.
#
# | State | When |
# |---|---|
# | failed | A check finished without passing |
# | pending | No check failed, and a check is still running |
# | none | The commit has no checks |
# | passed | Every check passed |
#
# - A check passes when its conclusion is success, neutral, or skipped.
# - Only the latest run of each check counts.
# - The verdict status is oe's own, so it never counts as a check.
def check_name: .name // .context // "unnamed check";
def check_class:
  if .__typename == "CheckRun" then
    if .status != "COMPLETED" then "pending"
    elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "passed"
    else "failed" end
  elif .__typename == "StatusContext" then
    if .state == "SUCCESS" then "passed"
    elif .state == "PENDING" or .state == "EXPECTED" then "pending"
    else "failed" end
  else error("unknown check type \(.__typename)") end;
def check_key($i):
  if .__typename == "StatusContext" then ["status", check_name]
  elif (.checkSuite.databaseId | type) == "number" then ["suite", (.checkSuite.databaseId | tostring), check_name]
  else ["unkeyed", ($i | tostring)] end;
def ci:
  .oid as $oid
  | if .statusCheckRollup == null then {state: "none", detail: ""}
    else .statusCheckRollup.contexts
    | if (.nodes | type) != "array" or (.totalCount | type) != "number" then error("checks unreadable on \($oid)")
      elif .totalCount > (.nodes | length) then error("checks truncated on \($oid)")
      else . end
    | [.nodes | to_entries[] | .key as $i | .value
        | select(.__typename != "StatusContext" or .context != verify_context)
        | {key: check_key($i), value: .}]
    | group_by(.key)
    | map(map(.value) | sort_by(.startedAt // .createdAt // "") | last | {name: check_name, class: check_class})
    | (map(select(.class == "failed") | .name)) as $failed
    | (map(select(.class == "pending") | .name)) as $pending
    | if ($failed | length) > 0 then {state: "failed", detail: ($failed | join(", "))}
      elif ($pending | length) > 0 then {state: "pending", detail: ($pending | join(", "))}
      elif length == 0 then {state: "none", detail: ""}
      else {state: "passed", detail: ""} end
    end;

# Reading the Epic
#
# epic_lines prints tab-separated lines for oe-ready.sh.
#
# | First field | Other fields |
# |---|---|
# | default | Branch name, head SHA, commit time, CI state, failing or pending check names |
# | issue | Child Issue number |
def epic_lines:
  .data.repository as $r
  | if ($r | type) != "object" then error("repository not found") else . end
  | ($r.defaultBranchRef.target // error("default branch head unreadable")) as $head
  | ($head | ci) as $ci
  | "default\t\($r.defaultBranchRef.name)\t\($head.oid)\t\($head.committedDate | epoch)\t\($ci.state)\t\($ci.detail)",
    (($r.issue // error("Epic not found")).subIssues
      | if .totalCount > (.nodes | length) then error("more than \(.nodes | length) child Issues") else . end
      | .nodes[]
      | if (.repository.nameWithOwner | ascii_downcase) != ($r.nameWithOwner | ascii_downcase)
        then error("child Issue #\(.number) is in \(.repository.nameWithOwner), not \($r.nameWithOwner)")
        else "issue\t\(.number)" end);

# Reading one Issue
#
# issue_state reduces one Issue response to the facts that next_action decides on.
#
# - Only records after the latest claim count.
#   - Records are ordered by their place in the comment list, because a claim and its first attempt can share a timestamp.
#   - Every record counts when there is no claim.
# - The pull request is the newest one opened from the Issue's branch after the latest claim.
#   - A pull request from a fork never counts.
# - Engineer input counts once.
#   - Input before the latest attempt was already handed to that attempt's Owner.
def issue_state:
  .data.repository as $r
  | ($r.issue // error("Issue not found")) as $issue
  | ($issue.comments.nodes // error("comments unreadable")) as $comments
  | ($r.ref != null) as $branch
  | [($r.pullRequests.nodes // error("pull requests unreadable"))[] | select(.isCrossRepository == false)] as $prs
  | ($comments | indexes(record("claim")) | last) as $claim
  | if $issue.comments.totalCount > ($comments | length) and $claim == null and ($branch or ($prs | length) > 0)
    then error("Issue #\($issue.number) has over \($comments | length) comments and none of the latest is a claim record")
    else . end
  | (if $claim == null then null else $comments[$claim].createdAt end) as $claimed_at
  | ($comments | indexes(record("attempt")) | map(select(. > ($claim // -1)))) as $attempts
  | ($comments | indexes(record("question")) | map(select(. > ($claim // -1))) | last) as $question
  | ($attempts | last // $claim) as $last_start
  | (if $last_start == null then null else $comments[$last_start].createdAt end) as $since
  | ($comments | indexes(engineer_input) | map(select(. > ($question // infinite)))) as $answers
  | (if any($answers[]; . > ($last_start // -1)) then ["a trusted answer to the question"] else [] end) as $answered
  | ([$prs[] | select($claimed_at == null or .createdAt >= $claimed_at)] | first) as $pr
  | ([$prs[] | select(.mergedAt != null and ($claimed_at == null or .mergedAt >= $claimed_at))] | first) as $merged
  | (if $branch and $pr.state == "OPEN" then
      ($pr.headRef.target // error("PR #\($pr.number) head unreadable")) as $target
      | if $target.oid != $pr.headRefOid then error("PR #\($pr.number) head changed during the read") else . end
      | (pr_heads[$target.oid] // error("PR #\($pr.number) head \($target.oid) changed during the read")) as $facts
      | ($target | ci) as $ci
      | {sha: $target.oid[0:7], ci: $ci.state, ci_detail: $ci.detail, verdict: $facts.verdict, starts: $facts.starts,
          age: (now_s - ($facts.pushed // ($target.committedDate | epoch)))}
    else null end) as $head
  | {
      number: $issue.number,
      closed: ($issue.state == "CLOSED"),
      branch: $branch,
      merged_pr: $merged.number,
      abandoned_pr: (if $branch and $pr.state == "CLOSED" then $pr.number else null end),
      waiting_on: (if $branch then [] else
        $issue.blockedBy
        | if (.nodes | type) != "array" or .totalCount > (.nodes | length)
          then error("Issue #\($issue.number) dependencies unreadable") else .nodes end
        | map(select(.state != "CLOSED" or .stateReason != "COMPLETED")
            | "#\(.number) " + (if .state == "OPEN" then "open" else "closed as \(.stateReason // "unknown")" end))
      end),
      question_open: ($question != null and ($answers | length) == 0),
      attempts: ($attempts | length),
      head: $head,
      repairs: (if $pr == null then $answered + ["no PR yet"]
        elif $head == null then []
        else $answered + [
          if $pr.mergeable == "CONFLICTING" then "PR #\($pr.number) conflicts with its base" else empty end,
          if $head.ci == "failed" then "checks failed on \($head.sha): \($head.ci_detail)" else empty end,
          if $head.verdict == "failure" or $head.verdict == "error" then "failure verdict on \($head.sha)" else empty end,
          if any($pr.reviews.nodes[]?; engineer_input and ($since == null or .submittedAt > $since))
          then "a trusted Changes requested review" else empty end,
          if any($pr.reviewThreads.nodes[]?.comments.nodes[]?; engineer_input and ($since == null or .createdAt > $since))
          then "a trusted review-thread comment" else empty end
        ] end)
    };

# Deciding
#
# next_action walks rows 3 to 12 of the next-action table in docs/design/orchestrate-epic.md from the top.
# oe-ready.sh applies rows 1 and 2 before any Issue is read.
#
# | Row | When | Action |
# |---|---|---|
# | 3 | The Issue is closed | done |
# | 4 | A pull request merged after the latest claim | wait-engineer |
# | 4 | The branch exists and its pull request closed without merging | wait-engineer |
# | 5 | No branch, and a dependency is not closed as completed | wait-dependencies |
# | 6 | No branch, and every dependency is closed as completed | claim |
# | 7 | The latest question has no engineer input after it | wait-answer |
# | 8 | A repair signal is present, and fewer than max_attempts attempts were used | start-owner |
# | 8 | A repair signal is present, and max_attempts attempts were used | parked |
# | 9 | A check on the head is pending | wait-ci |
# | 9 | The head has no checks, and no_checks_grace has not passed since its push | wait-ci |
# | 10 | The head has no checks, and no_checks_grace has passed since its push | parked |
# | 11 | The head has no verdict, and the Verifier started max_verifier_starts times | parked |
# | 11 | The head has no verdict, and the Verifier started fewer times | start-verifier |
# | 12 | The head has a success verdict | wait-merge |
#
# Repair signals
#
# - No pull request exists yet
# - The pull request conflicts with its base
# - A check on the head failed
# - The verdict on the head is a failure
# - Engineer input arrived after the latest attempt
#   - An answer to the latest question
#   - A Changes requested review
#   - A review-thread comment
def act($action; $reason): "\(.number)\t\($action)\t\($reason)";
def next_action:
  if .closed then act("done"; "closed")
  elif .merged_pr != null then act("wait-engineer"; "PR #\(.merged_pr) merged; the Issue is still open")
  elif .abandoned_pr != null then act("wait-engineer"; "PR #\(.abandoned_pr) closed without merging")
  elif .branch | not then
    if (.waiting_on | length) > 0 then act("wait-dependencies"; .waiting_on | join(", "))
    else act("claim"; "every dependency completed") end
  elif .question_open then act("wait-answer"; "the question has no unmarked comment from a trusted role yet")
  elif (.repairs | length) > 0 then
    (.repairs | join("; ")) as $why
    | if .attempts >= max_attempts then act("parked"; "\(.attempts) attempts used; still: \($why)")
      else act("start-owner"; "attempt \(.attempts + 1) of \(max_attempts): \($why)") end
  elif .head.ci == "pending" then act("wait-ci"; "checks pending on \(.head.sha): \(.head.ci_detail)")
  elif .head.ci == "none" and .head.age < no_checks_grace then
    act("wait-ci"; "no checks yet on \(.head.sha), \(.head.age)s after its push")
  elif .head.ci == "none" then act("parked"; "no checks on \(.head.sha) \(.head.age)s after its push")
  elif .head.verdict != "success" and .head.starts >= max_verifier_starts then
    act("parked"; "Verifier started \(.head.starts) times on \(.head.sha) without a verdict")
  elif .head.verdict != "success" then act("start-verifier"; "checks passed on \(.head.sha)")
  else act("wait-merge"; "success verdict on \(.head.sha)") end;

def classify: issue_state | next_action;
