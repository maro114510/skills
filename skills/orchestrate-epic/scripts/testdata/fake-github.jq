# Turns a test's GitHub state into the response GitHub would send to one oe ready read.
# fake-gh.sh runs it with $state, $call, and $arg.
#
# | $call | $arg | Response |
# |---|---|---|
# | epic | none | The Epic read |
# | issue | Issue number | The read of one Issue |
# | pulls | none | The open pull request list |
# | statuses | Commit SHA | The commit statuses on that commit, newest first |
# | activity | Branch name | The pushes to that branch |
# | repo | none | The repository, naming its default branch |
# | ref | Branch name | The head of that branch |
# | comments | Issue number | The comments on that Issue, oldest first |
# | sub_issues | Epic number | The child Issues, each with its number, state, and repository_url |
#
# The state
#
# - Every time is a clock time on the day of the test, written as HH:MM.
# - The test runs at 08:00.
# - A field left out takes the default in the tables below.
#
# | Field | Holds | Default |
# |---|---|---|
# | default_branch.pushed | When the default branch head was pushed | 07:00 |
# | default_branch.committed | The commit time of the default branch head | Same as pushed |
# | default_branch.checks | Check name to result | No checks |
# | default_branch.statuses | Status context to state | No statuses |
# | issues | The child Issues of the Epic | No Issues |
# | written_statuses | Commit statuses oe wrote, newest first, each with sha, context, state, description, and target_url | None |
#
# | Issue field | Holds | Default |
# |---|---|---|
# | number | The Issue number | Required |
# | closed | Whether the Issue is closed as completed | false |
# | repository | The repository the Issue lives in, as the sub-issue list reports it | o/r |
# | blocked_by | Dependencies, each with a number and a state of open, completed, or not_planned | None |
# | branch | Whether the branch feat/issue-N exists | false |
# | branch_sha | The head of the branch feat/issue-N | None |
# | comments | Issue comments, oldest first, each with by, at, and body | None |
# | pull_requests | Pull requests opened from the branch; the Issue read returns only the newest, as its query asks | None |
# | older_comments | How many older comments GitHub leaves out of the read | 0 |
# | older_pull_requests | How many older pull requests GitHub leaves out of the read | 0 |
#
# | Pull request field | Holds | Default |
# |---|---|---|
# | number | The pull request number, which also names its head SHA | Required |
# | head_sha | Its head SHA, set to model a push | Named by number |
# | comments | Conversation comments, oldest first, each with by, at, and body | None |
# | state | open, merged, or closed | open |
# | opened | When it was opened | Required |
# | merged | When it was merged | Not merged |
# | from_fork | Whether its branch lives in a fork | false |
# | conflicting | Whether it conflicts with its base | false |
# | pushed | When its head was pushed | Same as opened |
# | pushed_during_read | Whether a new head arrived after the pull request list was read | false |
# | committed | The commit time of its head | Same as opened |
# | checks | Check name to result on its head | No checks |
# | verdicts | oe/verify states on its head, newest first | None |
# | reviews | Changes requested reviews, each with by, at, and body | None |
# | thread_comments | Review-thread comments, each with by, at, and body | None |
# | older_threads | How many older review threads GitHub leaves out of the read | 0 |
#
# - A check result is success, failure, cancelled, or in_progress.
# - The by field is an author association such as OWNER, MEMBER, or NONE.

def time: "2027-01-15T\(.):00Z";
def default_sha: "a" * 40;
def pr_sha: .head_sha // ("\(.number)" as $n | ("b" * (40 - ($n | length))) + $n);
def author: {authorAssociation: .by, body: .body};

def check_run($name; $result):
  {__typename: "CheckRun", name: $name, startedAt: ("07:20" | time), checkSuite: {databaseId: 1},
    status: (if $result == "in_progress" then "IN_PROGRESS" else "COMPLETED" end),
    conclusion: (if $result == "in_progress" then null else ($result | ascii_upcase) end)};
def status_context($context; $state):
  {__typename: "StatusContext", context: $context, state: ($state | ascii_upcase), createdAt: ("07:20" | time)};
def rollup:
  if .checks == null and .statuses == null then null
  else [(.checks // {} | to_entries[] | check_run(.key; .value)),
      (.statuses // {} | to_entries[] | status_context(.key; .value))]
    | {contexts: {totalCount: length, nodes: .}}
  end;

def epic_response:
  (.default_branch // {}) as $d
  | {data: {repository: {
      nameWithOwner: "o/r",
      defaultBranchRef: {name: "main", target: {oid: default_sha,
        committedDate: ($d.committed // $d.pushed // "07:00" | time), statusCheckRollup: ($d | rollup)}},
      issue: {subIssues: {totalCount: (.issues | length),
        nodes: [.issues[] | {number, repository: {nameWithOwner: "o/r"}}]}}}}};

# The head the Issue read sees, which differs from the listed head after a push during the read.
def read_sha: if .pushed_during_read then "c" * 40 else pr_sha end;

def pull_request:
  {number, isCrossRepository: (.from_fork // false), headRefOid: read_sha,
    state: (.state // "open" | ascii_upcase), createdAt: (.opened | time),
    mergedAt: (if .merged then .merged | time else null end),
    mergeable: (if .conflicting then "CONFLICTING" else "MERGEABLE" end),
    reviews: {nodes: [.reviews[]? | author + {submittedAt: (.at | time)}]},
    reviewThreads: {totalCount: (1 + (.older_threads // 0)), nodes: [{comments: {nodes: [.thread_comments[]? | author + {createdAt: (.at | time)}]}}]},
    headRef: {target: {oid: read_sha, committedDate: (.committed // .opened | time), statusCheckRollup: rollup}}};

def issue_response($n):
  (.issues[] | select(.number == $n)) as $i
  | {data: {repository: {
      issue: {number: $n,
        state: (if $i.closed then "CLOSED" else "OPEN" end),
        stateReason: (if $i.closed then "COMPLETED" else null end),
        blockedBy: {totalCount: ($i.blocked_by // [] | length), nodes: [$i.blocked_by[]? | {number,
          state: (if .state == "open" then "OPEN" else "CLOSED" end),
          stateReason: (if .state == "open" then null else (.state | ascii_upcase) end)}]},
        comments: {totalCount: (($i.comments // [] | length) + ($i.older_comments // 0)),
          nodes: [$i.comments[]? | author + {createdAt: (.at | time)}]}},
      ref: (if $i.branch then {name: "feat/issue-\($n)"} else null end),
      pullRequests: {totalCount: (($i.pull_requests // [] | length) + ($i.older_pull_requests // 0)), nodes: [$i.pull_requests // [] | sort_by(.opened) | reverse | .[0:1][] | pull_request]}}}};

def open_pull_requests:
  [.issues[] | .number as $n | .pull_requests[]? | select((.state // "open") == "open")
    | {number, head: {ref: "feat/issue-\($n)", sha: pr_sha, repo: {full_name: (if .from_fork then "fork/r" else "o/r" end)}}}];

def statuses($sha):
  [(.written_statuses[]? | select(.sha == $sha) | {context, state, target_url}),
    (.issues[].pull_requests[]? | select(pr_sha == $sha) | .verdicts[]? | {context: "oe/verify", state: .})];

def pushes($branch):
  if $branch == "main" then [{after: default_sha, timestamp: (.default_branch.pushed // "07:00" | time)}]
  else [.issues[] | select("feat/issue-\(.number)" == $branch) | .pull_requests[]?
      | select((.state // "open") == "open") | {after: pr_sha, timestamp: (.pushed // .opened | time)}]
  end;

def branch_head($branch):
  if $branch == "main" then {object: {sha: default_sha}}
  else error("unknown branch \($branch)") end;

def issue_comments($n):
  [.issues[] | select(.number == $n)] | first // error("Issue #\($n) not found")
  | [.comments[]? | {author_association: .by, body, created_at: (.at | time)}];

def sub_issues:
  [.issues[] | {number, state: (if .closed then "closed" else "open" end),
    repository_url: "https://api.github.com/repos/\(.repository // "o/r")"}];

$state
| if $call == "epic" then epic_response
  elif $call == "issue" then issue_response($arg | tonumber)
  elif $call == "pulls" then open_pull_requests
  elif $call == "statuses" then statuses($arg)
  elif $call == "activity" then pushes($arg)
  elif $call == "repo" then {full_name: "o/r", default_branch: "main"}
  elif $call == "ref" then branch_head($arg)
  elif $call == "comments" then issue_comments($arg | tonumber)
  elif $call == "sub_issues" then sub_issues
  else error("unknown call \($call)") end
