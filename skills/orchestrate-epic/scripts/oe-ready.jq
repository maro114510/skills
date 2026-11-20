# The decision logic of oe ready.
# oe-ready.sh passes every GitHub response through these definitions with gh --jq.
# oe-ready.sh puts the oe_bot definition, oe-records.jq, and these values in front of this file.
#
# | Name | Value |
# |---|---|
# | now_s | The current time in epoch seconds |
# | no_checks_grace | Seconds a commit may go without checks before its CI counts as missing |
# | marker_ttl | Seconds a working marker stays live without a result |
# | repair_cap | Commits of the PR with a failed check, since the latest answer, that hold the Issue |
# | verify_context | The commit status context that holds the verdict |
# | branch_prefix | The prefix of an Issue branch, followed by the Issue number |
# | pr_heads | The verdict and the push time of each open pull request head |

def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;

# The positions in an array whose element matches f.
def indexes(f): . as $a | [range(0; length) | select($a[.] | f)];

# Who counts on GitHub: trusted, record, and engineer_input come from oe-records.jq.

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
# - A cancelled run does not count when a run of the same name from the same workflow started later in another check suite,
#   as when a workflow cancels its own run in progress.
# - The verdict status is oe's own, so it never counts as a check.
def check_name: .name // .context // "unnamed check";
def check_time: .startedAt // .createdAt // "";
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
def check_workflow: .checkSuite.workflowRun.workflow.databaseId;
# A check from an app other than Actions has no workflow, so nothing ties its runs together and none supersedes another.
def superseded($runs):
  .__typename == "CheckRun" and .conclusion == "CANCELLED" and check_workflow != null
  and (check_name as $n | check_workflow as $w | check_time as $t
    | any($runs[]; .__typename == "CheckRun" and check_name == $n and check_workflow == $w and check_time > $t));
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
    | map(map(.value) | sort_by(check_time) | last)
    | . as $latest
    | map(select(superseded($latest) | not) | {name: check_name, class: check_class})
    | (map(select(.class == "failed") | .name)) as $failed
    | (map(select(.class == "pending") | .name)) as $pending
    | if ($failed | length) > 0 then {state: "failed", detail: ($failed | join(", "))}
      elif ($pending | length) > 0 then {state: "pending", detail: ($pending | join(", "))}
      elif length == 0 then {state: "none", detail: ""}
      else {state: "passed", detail: ""} end
    end;

# Whether one commit of a pull request had a failed check, from the checks the read holds of it.
# The read holds the first 100 checks of each earlier commit, enough for the repair cap, which only counts commits.
def commit_failed:
  ((.statusCheckRollup.contexts.nodes // [])
    | map(select(.__typename != "StatusContext" or .context != verify_context))) as $nodes
  | [$nodes | to_entries[] | .key as $i | .value | {key: check_key($i), value: .}]
  | group_by(.key) | map(map(.value) | sort_by(check_time) | last)
  | . as $latest
  | any(.[]; (superseded($latest) | not) and check_class == "failed");

# Reading the Epic
#
# epic_lines prints tab-separated lines for oe-ready.sh.
#
# | First field | Other fields |
# |---|---|
# | default | Branch name |
# | issue | Child Issue number, and its state: OPEN or CLOSED |
def epic_lines:
  .data.repository as $r
  | if ($r | type) != "object" then error("repository not found") else . end
  | ($r.defaultBranchRef.name // error("default branch unreadable")) as $default
  | "default\t\($default)",
    (($r.issue // error("Epic not found")).subIssues
      | if .totalCount > (.nodes | length) then error("more than \(.nodes | length) child Issues") else . end
      | .nodes[]
      | if (.repository.nameWithOwner | ascii_downcase) != ($r.nameWithOwner | ascii_downcase)
        then error("child Issue #\(.number) is in \(.repository.nameWithOwner), not \($r.nameWithOwner)")
        else "issue\t\(.number)\t\(.state)" end);

# The question a question record's body asks, without the marker, the heading, and the closing part after the last `---` line, that oe question wraps it in.
def question_text:
  gsub("\r"; "") | split("\n")
  | (indexes(. == "---") | last) as $end
  | (if $end == null then . else .[:$end] end)
  | (indexes(test("^(<!-- oe:|### |\\s*$)") | not) | first) as $start
  | (indexes(test("^\\s*$") | not) | last) as $last
  | if $start == null then "" else .[$start:$last + 1] | join("\n") end;

# The working marker oe start writes as the last line of that form in the Issue body, or null.
# A line that does not hold every field in this form is no marker.
def marker_pattern:
  "^<!-- oe:working role=(?<role>owner|verifier) at=(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)( sha=(?<sha>[0-9a-f]{40}))?( session=(?<session>[^ ]+))? -->$";
def working_marker:
  [gsub("\r"; "") | split("\n")[] | sub("[ \t]+$"; "") | select(test(marker_pattern)) | capture(marker_pattern)]
  | last
  | if . == null or (.role == "verifier" and .sha == null) then null else . end;

# Whether one review thread asks the Owner for a change since the head was pushed at $pushed, epoch seconds.
#
# - A resolved thread asks nothing, and so does one whose lines a later push changed, which GitHub marks outdated.
# - A thread asks only while its last comment is engineer input, so a last comment from a bot or an untrusted author asks nothing.
def thread_waits($pushed):
  (.isResolved != true)
  and (.isOutdated != true)
  and ((.comments.nodes // []) | last as $last
    | $last != null and ($last | engineer_input) and (($last.createdAt | epoch) > $pushed));

# Reading one Issue
#
# issue_state reduces one Issue response to the facts that next_action decides on.
#
# - A wait is a hold or a question record, and an answer is an answer record, or engineer input after the first wait.
# - A read cut short by GitHub fails when the Issue has a branch or a pull request and the comments it holds show no wait and no answer,
#   because an older one could still decide the Issue.
# - The PR is the newest pull request opened from the Issue's branch that is open or whose head is the branch's current head.
#   - A pull request from a fork never counts.
#   - A PR left from a branch the engineer deleted is never the PR, so an Owner starts the Issue over.
# - A head that moved between the reads leaves only its Issue unreadable, and the read goes on with every other Issue.
#   - next_action gives that Issue read-again right before the working marker, the first row that needs the head.
# - The working marker gives its result, ends, stays live, or expires:
#   - An Owner's gives its result when the PR is open with a head pushed after its start, or a question came after its start.
#   - A Verifier's gives its result when its SHA has a verdict.
#   - An answer newer than its start ends it, so the answer starts the next agent.
#   - It stays live until marker_ttl passes since its start, and expires with no result after that.
# - Repair signals count only engineer input and answers since the PR's head was pushed.
# - The repair cap counts the PR's commits with a failed check that were committed after the latest answer.
def issue_state:
  .data.repository as $r
  | ($r.issue // error("Issue not found")) as $issue
  | ($issue.comments.nodes // error("comments unreadable")) as $comments
  | ($r.ref != null) as $branch
  | ($r.ref.target.oid // null) as $branch_head
  | [($r.pullRequests.nodes // error("pull requests unreadable"))[] | select(.isCrossRepository == false)] as $prs
  | ([$prs[] | select(.state == "OPEN" or ($branch_head != null and .headRefOid == $branch_head))] | first) as $pr
  | ($comments | indexes(record("question") or record("hold"))) as $waits
  | ($waits | first) as $first_wait
  | [range(0; $comments | length) | . as $i
      | select($comments[$i] | record("answer") or ($first_wait != null and $i > $first_wait and engineer_input))] as $answers
  | if $issue.comments.totalCount > ($comments | length) and ($branch or ($prs | length) > 0)
      and ($waits | length) == 0 and ($answers | length) == 0
    then error("Issue #\($issue.number) has over \($comments | length) comments, and the read holds no hold, question, or answer")
    else . end
  | ($waits | last) as $wait
  | ($answers | last) as $answer
  | (if $answer == null then null else $comments[$answer].createdAt | epoch end) as $answered_at
  | (if $branch and $pr.state == "OPEN" then try (
      ($pr.headRef.target // error("PR #\($pr.number) head unreadable")) as $target
      | if $target.oid != $pr.headRefOid then error("PR #\($pr.number) head changed during the read") else . end
      | (pr_heads[$target.oid] // error("PR #\($pr.number) head \($target.oid) changed during the read")) as $facts
      | if $pr.reviewThreads.totalCount > ($pr.reviewThreads.nodes | length)
        then error("PR #\($pr.number) has more review threads than one read holds") else . end
      | ($target | ci) as $ci
      | ($facts.pushed // ($target.committedDate | epoch)) as $pushed
      | {sha: $target.oid[0:7], oid: $target.oid, ci: $ci.state, ci_detail: $ci.detail, verdict: $facts.verdict,
          pushed: $pushed, age: (now_s - $pushed)}
    ) catch {unreadable: .}
    else null end) as $head
  | ($issue.body // "" | working_marker) as $marker
  | (if $marker == null then null
     else ($marker.at | epoch) as $started
     | (if $marker.role == "owner" then
          ($head != null and $head.unreadable == null and $head.pushed > $started)
          or any($comments[]; record("question") and (.createdAt | epoch) > $started)
        else ((pr_heads[$marker.sha].verdict // "none") | . == "success" or . == "failure" or . == "error") end) as $result
     | if $answered_at != null and $answered_at > $started then null
       elif $result then null
       elif now_s - $started < marker_ttl then {state: "live", role: $marker.role, at: $marker.at}
       else {state: "expired", role: $marker.role, at: $marker.at} end
     end) as $working
  | ($issue.blockedBy
      | if (.nodes | type) != "array" or .totalCount > (.nodes | length)
        then error("Issue #\($issue.number) dependencies unreadable") else .nodes end) as $dependencies
  | {
      number: $issue.number,
      closed: ($issue.state == "CLOSED"),
      wait: (if $wait == null or ($answer != null and $answer > $wait) then null
        else $comments[$wait] | {kind: (if record("hold") then "hold" else "question" end), url, text: (.body | question_text),
          at: .createdAt} end),
      pr: $pr.number,
      pr_closed: ($pr.state == "CLOSED"),
      pr_merged: ($pr.state == "MERGED"),
      dropped: [$dependencies[] | select(.state == "CLOSED" and (.stateReason == "NOT_PLANNED" or .stateReason == "DUPLICATE"))
        | "dependency #\(.number) closed as \(.stateReason | ascii_downcase)"],
      waiting_on: [$dependencies[] | select(.state != "CLOSED") | "#\(.number) open"],
      head: $head,
      working: $working,
      failed_commits: (if $head == null or $head.unreadable != null then 0
        else [$pr.commits.nodes[]?.commit | select($answered_at == null or (.committedDate | epoch) > $answered_at) | select(commit_failed)]
          | length end),
      repairs: (if $pr == null then ["no PR yet"]
        elif $head == null or $head.unreadable != null then []
        else [
          if $pr.mergeable == "CONFLICTING" then "PR #\($pr.number) conflicts with its base" else empty end,
          if $head.ci == "failed" then "checks failed on \($head.sha): \($head.ci_detail)" else empty end,
          if $answered_at != null and $answered_at > $head.pushed then "an answer since the head's push" else empty end,
          if any($pr.reviews.nodes[]?; .commit.oid == $head.oid and engineer_input and ((.submittedAt | epoch) > $head.pushed))
          then "a trusted Changes requested review" else empty end,
          if any($pr.reviewThreads.nodes[]?; thread_waits($head.pushed))
          then "a trusted review-thread comment" else empty end
        ] end)
    };

# Deciding
#
# next_action walks the next-action table in docs/design/orchestrate-epic.md from the top.
#
# | Row | When | Action |
# |---|---|---|
# | 1 | The Issue is closed | done |
# | 2 | A hold or a question is newer than the latest answer | wait-answer |
# | 3 | The PR was closed without merging, or merged with the Issue open | hold |
# | 4 | A dependency was closed as not planned or duplicate | hold |
# | 5 | A dependency is not completed | wait-dependencies |
# | - | The PR's head moved during the read | read-again |
# | 6 | The working marker is live | wait-agent |
# | 7 | The working marker expired with no result | hold |
# | 8 | A repair signal is present, and repair_cap commits of the PR since the latest answer had a failed check | hold |
# | 8 | A repair signal is present otherwise | start-owner |
# | 9 | A check on the head is pending, or the head has had no checks for less than no_checks_grace | wait-ci |
# | 10 | The head still has no checks after no_checks_grace | hold |
# | 11 | The head has no verdict | start-verifier |
# | 12 | The head has a failure verdict | hold |
# | 13 | The head has a success verdict | wait-merge |
#
# A reason quotes check names and logins from GitHub, so tabs and line breaks in it become spaces and cannot add a field or a line.
def act($action; $reason): "\(.number)\t\($action)\t\($reason | gsub("[\t\r\n]"; " "))";
def agent($role): if $role == "owner" then "pr-owner" else "pr-verify" end;
def next_action:
  if .closed then act("done"; "closed")
  elif .wait != null then
    act("wait-answer"; "\(.wait.kind) \(.wait.url) has no answer yet:\n\(.wait.text)" | gsub("\r?\n"; "\\n"))
  elif .pr_closed then act("hold"; "PR #\(.pr) was closed without merging")
  elif .pr_merged then act("hold"; "PR #\(.pr) merged; the Issue is still open")
  elif (.dropped | length) > 0 then act("hold"; .dropped | join("; "))
  elif (.waiting_on | length) > 0 then act("wait-dependencies"; .waiting_on | join(", "))
  elif .head.unreadable != null then
    if .head.unreadable | test("changed during the read$") then act("read-again"; "\(.head.unreadable); read again at the next pass")
    else error(.head.unreadable) end
  elif .working.state == "live" then act("wait-agent"; "\(agent(.working.role)) started at \(.working.at)")
  elif .working.state == "expired" then
    act("hold"; "\(agent(.working.role)) started at \(.working.at) and gave no result within \(marker_ttl / 3600) hours")
  elif (.repairs | length) > 0 then
    (.repairs | join("; ")) as $why
    | if .failed_commits >= repair_cap
      then act("hold"; "\(.failed_commits) commits of PR #\(.pr) had a failed check since the latest answer; still: \($why)")
      else act("start-owner"; $why) end
  elif .head.ci == "pending" then act("wait-ci"; "checks pending on \(.head.sha): \(.head.ci_detail)")
  elif .head.ci == "none" and .head.age < no_checks_grace then
    act("wait-ci"; "no checks yet on \(.head.sha), \(.head.age)s after its push")
  elif .head.ci == "none" then act("hold"; "no checks on \(.head.sha) \(.head.age)s after its push")
  elif .head.verdict == "failure" or .head.verdict == "error" then act("hold"; "failure verdict on \(.head.sha)")
  elif .head.verdict == "success" then act("wait-merge"; "success verdict on \(.head.sha)")
  else act("start-verifier"; "checks passed on \(.head.sha)") end;

# A closed Issue is done before anything else is read, so a busy closed Issue never fails the read.
def classify:
  if .data.repository.issue.state == "CLOSED" then .data.repository.issue | act("done"; "closed")
  else issue_state | next_action end;
