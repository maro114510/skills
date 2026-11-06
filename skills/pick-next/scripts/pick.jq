# Every rule pick-next uses to group and order the facts pick.sh collects.
# Input: {repo, viewer, limit, issues, prs, worktrees, discussions}, where issues, prs, and discussions are the
# GraphQL nodes of pick-issues.graphql, pick-prs.graphql, and pick-discussions.graphql, discussions is null when
# they were not read, and worktrees is [{path, branch, dirty}].
#
# Groups
#   owner    open pull requests whose checks passed or never ran and whose review asks for no changes
#   next     unblocked Issues, and pull requests that close no open Issue and do not wait on the owner
#   blocked  Issues with at least one open blocker
#   local    dirty worktrees whose branch belongs to no open Issue or pull request
#   discussions  open Discussions, only when they were read. Ideas and questions, not work, so they are never
#                ranked with Issues
# An Epic, an Issue with sub-issues, is in no group: its children are the work.
# An Issue assigned only to others is in no group: someone else owns it.
#
# next order: work in progress, then the number of open Issues it unblocks, then a parent Epic with progress, then
# the lower number. In progress means a worktree, an open pull request, or the viewer among the assignees.
# blocked order: fewer open blockers, then more Issues unblocked, then the lower number.
# discussions order: the most recently updated, then the lower number.

def checks: .commits.nodes[0].commit.statusCheckRollup.state // null;

def waits_on_owner: (checks == null or checks == "SUCCESS") and .reviewDecision != "CHANGES_REQUESTED";

# True when branch name $b follows the issue-<n> convention for Issue $n.
def names_issue($b; $n): $b | test("(^|/)issue-\($n)(-|$)");

def body_excerpt: (.body // "")[0:1500];

. as $in
| ($in.issues | map(.number)) as $open
| ($in.prs | map(. + {closes: [.closingIssuesReferences.nodes[].number | select(IN($open[]))]})) as $prs
| ($in.issues | map({key: (.number | tostring), value: .title}) | from_entries) as $titles

| def pr_summary: {number, checks: checks, isDraft, review: .reviewDecision};
  def worktrees_on($branches): [$in.worktrees[] | select(.branch | IN($branches[]))];

  def issue_item:
    . as $i
    | [$prs[] | select(.closes | index($i.number))] as $own_prs
    | ([$i.linkedBranches.nodes[].ref.name] + [$own_prs[].headRefName]
       + [$in.worktrees[].branch | select(names_issue(.; $i.number))]) as $branches
    | worktrees_on($branches) as $wts
    | ([$i.assignees.nodes[].login]) as $assignees
    | {kind: "issue", number, title, url, body: body_excerpt,
       inProgress: (($wts | length) > 0 or ($own_prs | length) > 0 or ($assignees | index($in.viewer)) != null),
       unblocks: ([$i.blocking.nodes[] | select(.state == "OPEN")] | length),
       epic: (if $i.parent then {number: $i.parent.number, title: $i.parent.title,
                completed: $i.parent.subIssuesSummary.completed, total: $i.parent.subIssuesSummary.total}
              else null end),
       pr: ($own_prs | max_by(.number) | if . then pr_summary else null end),
       worktrees: $wts,
       blockedBy: [$i.blockedBy.nodes[] | select(.state == "OPEN") | {number, title}],
       epicContainer: ($i.subIssuesSummary.total > 0),
       assignedElsewhere: (($assignees | length) > 0 and ($assignees | index($in.viewer)) == null),
       waitsOnOwner: any($own_prs[]; waits_on_owner)};

  def pr_item:
    {kind: "pr", number, title, url, body: body_excerpt, inProgress: true, unblocks: 0, epic: null,
     pr: pr_summary, worktrees: worktrees_on([.headRefName])};

  def public: del(.blockedBy, .epicContainer, .assignedElsewhere, .waitsOnOwner);

  [$in.issues[] | issue_item | select((.epicContainer or .assignedElsewhere) | not)] as $issues

  | [$prs[] | select(waits_on_owner)
     | {kind: "pr", number, title, url, body: body_excerpt, isDraft, checks: checks, review: .reviewDecision,
        issues: [.closes[] | {number: ., title: $titles[tostring]}], worktrees: worktrees_on([.headRefName])}]
    | sort_by(.isDraft, .number) as $owner

  | ([$issues[] | select((.blockedBy | length) == 0 and (.waitsOnOwner | not)) | public]
     + [$prs[] | select((waits_on_owner | not) and (.closes | length) == 0) | pr_item])
    | sort_by((.inProgress | not), -.unblocks, ((.epic.completed // 0) > 0 | not), .number) as $next

  | [$issues[] | select((.blockedBy | length) > 0)]
    | sort_by((.blockedBy | length), -.unblocks, .number)
    | map(public + {blockedBy}) as $blocked

  | ([$in.issues[] | issue_item | .worktrees[].branch] + [$prs[].headRefName]) as $claimed
  | [$in.worktrees[] | select(.dirty and (.branch | IN($claimed[]) | not))] as $local

  | {repo: $in.repo, viewer: $in.viewer, owner: $owner,
     next: $next[0:$in.limit], nextTotal: ($next | length),
     blocked: $blocked[0:$in.limit], blockedTotal: ($blocked | length),
     local: $local}
  + if $in.discussions == null then {} else
      ([$in.discussions[]
        | {kind: "discussion", number, title, url, body: body_excerpt, category: .category.name,
           answered: .isAnswered, updatedAt}]
       | sort_by(.updatedAt, -.number) | reverse) as $discussions
      | {discussions: $discussions, discussionsTotal: ($discussions | length)}
    end
