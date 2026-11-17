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
# | user | none | The authenticated user, whose login is me; a GitHub App identity is refused, as GitHub refuses it |
# | installation | none | The repositories of the App installation, which only a GitHub App identity can read |
# | ref | Branch name | The head of that branch |
# | comments | Issue number | The comments on that Issue, oldest first |
# | issue_rest | Issue number | The REST read of one Issue, with its number and body |
# | sub_issues | Epic number | The child Issues, each with its number and state |
# | checks | Commit SHA and cursor, as SHA:CURSOR | The page of checks on that commit after the cursor |
# | compare | Two commits, as BASE...HEAD | Whether HEAD contains BASE: ahead when it does, and diverged when it does not |
#
# Checks come 100 to a page, in every read that holds them.
#
# The state
#
# - Every time is a clock time on the day of the test, written as HH:MM.
# - The test runs at 08:00.
# - A field left out takes the default in the tables below.
#
# | Field | Holds | Default |
# |---|---|---|
# | identity | app when oe acts as a GitHub App installation, and anything else for a user | A user |
# | default_branch.pushed | When the default branch head was pushed | 07:00 |
# | default_branch.committed | The commit time of the default branch head | Same as pushed |
# | default_branch.checks | Check name to result | No checks |
# | default_branch.statuses | Status context to state | No statuses |
# | issues | The child Issues of the Epic | No Issues |
# | written_statuses | Commit statuses oe wrote, newest first, each with sha, context, state, description, and target_url | None |
# | branch_updates | Numbers of the pull requests whose branch a branch update moved, written by the fake, never read | None |
#
# | Issue field | Holds | Default |
# |---|---|---|
# | number | The Issue number | Required |
# | closed | Whether the Issue is closed as completed | false |
# | body | The Issue body | Empty |
# | blocked_by | Dependencies, each with a number and a state of open, completed, or not_planned | None |
# | branch | Whether the branch feat/issue-N exists | false |
# | branch_sha | The head of the branch feat/issue-N | The head of the newest pull request, or else the default branch head |
# | assignees | Logins oe assigned to the Issue | None |
# | comments | Issue comments, oldest first, each with by, at, body, and optionally login and type, as thread comments hold them | None |
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
# | base | The branch it merges into | main |
# | missing_merges | Numbers of merged pull requests whose merge commits its head lacks | None |
# | from_fork | Whether its branch lives in a fork | false |
# | conflicting | Whether it conflicts with its base | false |
# | pushed | When its head was pushed | Same as opened |
# | pushed_during_read | Whether a new head arrived after the pull request list was read | false |
# | committed | The commit time of its head | Same as opened |
# | checks | Check name to result on its head | No checks |
# | check_runs | Further check runs on its head, each with name, result, suite, started, and optionally the workflow that ran it, so one name can run in several check suites | None |
# | verdicts | oe/verify states on its head, newest first | None |
# | reviews | Changes requested reviews, each with by, at, and body | None |
# | approvals | Approved reviews, each with by, at, and the sha it approved | None |
# | thread_comments | Review-thread comments, each with by, at, and body | None |
# | threads | Whole review threads, each with resolved, outdated, and comments | One thread of thread_comments |
# | older_threads | How many older review threads GitHub leaves out of the read | 0 |
#
# - A check result is success, failure, cancelled, or in_progress.
# - The by field is an author association such as OWNER, MEMBER, or NONE.
# - A comment in threads holds by, at, body, and, for a bot, login and type.
#   Its by field defaults to NONE and its type to User, so a bot says type Bot.
# - An approval approves the pull request's head unless it names another sha.

def time: "2027-01-15T\(.):00Z";
def default_sha: "a" * 40;
def pr_sha: .head_sha // ("\(.number)" as $n | ("b" * (40 - ($n | length))) + $n);
# The commit GitHub records as a merged pull request's merge commit.
def merge_sha: "\(.number)" as $n | ("d" * (40 - ($n | length))) + $n;
def author: {authorAssociation: .by, body: .body};

def check_run($name; $result):
  {__typename: "CheckRun", name: $name, startedAt: ("07:20" | time), checkSuite: {databaseId: 1},
    status: (if $result == "in_progress" then "IN_PROGRESS" else "COMPLETED" end),
    conclusion: (if $result == "in_progress" then null else ($result | ascii_upcase) end)};
def status_context($context; $state):
  {__typename: "StatusContext", context: $context, state: ($state | ascii_upcase), createdAt: ("07:20" | time)};
def rollup_nodes:
  if .checks == null and .check_runs == null and .statuses == null then null
  else [(.checks // {} | to_entries[] | check_run(.key; .value)),
      (.check_runs[]? | check_run(.name; .result) + {startedAt: (.started | time),
        checkSuite: {databaseId: .suite, workflowRun: (if .workflow then {workflow: {databaseId: .workflow}} else null end)}}),
      (.statuses // {} | to_entries[] | status_context(.key; .value))]
  end;

# One page of checks, which holds 100 at most, as GitHub returns them; the cursor is the position after the page.
def contexts_page($after):
  if . == null then null
  else {contexts: {totalCount: length,
    pageInfo: {hasNextPage: (length > $after + 100), endCursor: "\([length, $after + 100] | min)"},
    nodes: .[$after:$after + 100]}}
  end;
def rollup: rollup_nodes | contexts_page(0);

def epic_response:
  {data: {repository: {
      nameWithOwner: "o/r",
      defaultBranchRef: {name: "main"},
      issue: {subIssues: {totalCount: (.issues | length),
        nodes: [.issues[] | {number, state: (if .closed then "CLOSED" else "OPEN" end),
          repository: {nameWithOwner: "o/r"}}]}}}}};

# The head the Issue read sees, which differs from the listed head after a push during the read.
def read_sha: if .pushed_during_read then "c" * 40 else pr_sha end;

# A review-thread comment as the Issue read returns it, with the Bot type a listed bot carries.
def thread_comment:
  {authorAssociation: (.by // "NONE"), author: {login: (.login // ""), __typename: (.type // "User")},
    body, createdAt: (.at | time)};

# A review thread with its root comment apart from the comments a trusted reply can appear in.
def review_thread:
  {isResolved: (.resolved // false), isOutdated: (.outdated // false),
    root: {nodes: [(.comments // [])[0]? | thread_comment]},
    comments: {nodes: [.comments[]? | thread_comment]}};

# The review threads of a pull request: its threads, or one thread of its thread_comments.
def review_threads:
  if .threads then [.threads[] | review_thread]
  else [{isResolved: false, isOutdated: false,
    root: {nodes: [(.thread_comments // [])[0]? | thread_comment]},
    comments: {nodes: [.thread_comments[]? | thread_comment]}}]
  end;

def pull_request:
  (read_sha) as $sha
  | {number, isCrossRepository: (.from_fork // false), headRefOid: $sha,
    state: (.state // "open" | ascii_upcase), createdAt: (.opened | time),
    mergedAt: (if .merged then .merged | time else null end),
    baseRefName: (.base // "main"),
    mergeCommit: (if .merged then {oid: merge_sha} else null end),
    mergeable: (if .conflicting then "CONFLICTING" else "MERGEABLE" end),
    reviews: {nodes: [.reviews[]? | author + {submittedAt: (.at | time)}]},
    approvals: {nodes: [.approvals[]? | {authorAssociation: (.by // "NONE"), commit: {oid: (.sha // $sha)}}]},
    reviewThreads: {totalCount: ((review_threads | length) + (.older_threads // 0)), nodes: review_threads},
    headRef: {target: {oid: $sha, committedDate: (.committed // .opened | time), statusCheckRollup: rollup}}};

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
          nodes: [$i.comments // [] | to_entries[] | .key as $c | .value | author + {createdAt: (.at | time),
            url: "https://github.com/o/r/issues/\($n)#issuecomment-\($c + 1)",
            author: {login: (.login // ""), __typename: (.type // "User")}}]}},
      ref: (if $i.branch then {name: "feat/issue-\($n)", target: {oid: ($i.branch_sha // ([$i.pull_requests // [] | sort_by(.opened) | reverse | .[0] | select(. != null) | read_sha] | first) // default_sha)}} else null end),
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
  | [.comments // [] | to_entries[] | .key as $i | .value
    | {author_association: .by, body, created_at: (.at | time),
      html_url: "https://github.com/o/r/issues/\($n)#issuecomment-\($i + 1)",
      user: {login: ((.login // "") + (if .type == "Bot" then "[bot]" else "" end)), type: (.type // "User")}}];

def issue_rest($n):
  [.issues[] | select(.number == $n)] | first // error("Issue #\($n) not found")
  | {number, body: (.body // "")};

def sub_issues:
  [.issues[] | {number, state: (if .closed then "closed" else "open" end)}];

# The page of checks after the cursor $after on the pull request head $oid.
def checks_response($oid; $after):
  ([.issues[].pull_requests[]? | select(read_sha == $oid)] | first // error("unknown commit \($oid)")) as $commit
  | {data: {repository: {object: {oid: $oid, statusCheckRollup: ($commit | rollup_nodes | contexts_page($after))}}}};

# Whether the head $head contains the merge commit $base, as GitHub's compare status says.
def compare_response($base; $head):
  ([.issues[].pull_requests[]? | select(.merged and merge_sha == $base)] | first // error("unknown commit \($base)")) as $merged
  | ([.issues[].pull_requests[]? | select(pr_sha == $head)] | first // error("unknown commit \($head)")) as $pr
  | {status: (if any($pr.missing_merges[]?; . == $merged.number) then "diverged" else "ahead" end)};

$state
| if $call == "epic" then epic_response
  elif $call == "issue" then issue_response($arg | tonumber)
  elif $call == "pulls" then open_pull_requests
  elif $call == "statuses" then statuses($arg)
  elif $call == "activity" then pushes($arg)
  elif $call == "repo" then {full_name: "o/r", default_branch: "main"}
  elif $call == "user" then
    if .identity == "app" then error("HTTP 403: Resource not accessible by integration") else {login: "me"} end
  elif $call == "installation" then
    if .identity == "app" then {total_count: 1}
    else error("HTTP 403: You must authenticate with an installation access token") end
  elif $call == "ref" then branch_head($arg)
  elif $call == "comments" then issue_comments($arg | tonumber)
  elif $call == "issue_rest" then issue_rest($arg | tonumber)
  elif $call == "sub_issues" then sub_issues
  elif $call == "checks" then ($arg | split(":")) as [$oid, $after] | checks_response($oid; $after | tonumber)
  elif $call == "compare" then ($arg | split("...")) as [$base, $head] | compare_response($base; $head)
  else error("unknown call \($call)") end
