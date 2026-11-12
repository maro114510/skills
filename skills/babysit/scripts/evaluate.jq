# Evaluates one normalized pr-state snapshot against the babysit ledger.
# Input: [snapshot, ledger] from `jq -s`. Args: $now (epoch seconds), $mode (watch or drive), and $bot (the own bot's login from git config skills.bot, or "").
# Output: {ledger, status, event, blockers, pending, report}. ledger holds only the fields wait owns:
# head and heads. pending and report.pending list each unresolved item with the key, event, and where to look.
# report.reasons maps each parked key to the reason it was parked with.
# event is the first matching row of the event table, or null when nothing fires,
# which wait turns into idle once --max expires.

def no_ci_seconds: 600;
def session_seconds: 28800;
def max_rounds: 5;
def stuck_repairs: 2;
# An event carries this much of a comment body; the skill reads the rest from pr-state only when it acts.
def excerpt_chars: 200;

# The review bots whose comments drive may act on, by GraphQL login. The same logins as
# skills/orchestrate-epic/scripts/oe-bots.jq, which cannot be included here because it needs oe-records.jq.
def review_bots: ["coderabbitai", "chatgpt-codex-connector"];

# Succeeds for a comment drive may act on: one from a repository owner, member, or collaborator, or from a
# listed review bot, which has no association. A user who takes a bot's login is not a Bot.
def trusted: (.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR"))
  or (.authorType == "Bot" and (.author | IN(review_bots[])));

# Succeeds for a comment by the agents' own bot, as skills/orchestrate-epic/scripts/oe-records.jq defines it.
# It is neither a person's input to act on nor an untrusted author to park, so drive skips it like its own replies.
def own_bot: $bot != "" and .authorType == "Bot" and .author == $bot;

# The item keys of the ledger that still describe this head; comment keys never carry a head.
def relevant($head; $gen): select(startswith("c:") or endswith("@\($head)#\($gen)") or . == "x:\($head)#\($gen)");

.[0] as $s
| (.[1] // {}) as $l
| ($now | tonumber) as $t
# A new SHA raises gen, including a return to an earlier SHA, so check and conflict keys start fresh.
| ($l.head // null) as $h0
| (if $h0 == null then {sha: $s.head, gen: 0}
   elif $h0.sha == $s.head then $h0
   else {sha: $s.head, gen: (($h0.gen // 0) + 1)} end) as $head
| $head.gen as $g
| (($l.heads // {}) | if .[$s.head] == null then .[$s.head] = {first_seen: $t} else . end) as $heads
| ($l.items // {}) as $items
| ($l.started_at // null) as $started
# A report settles an item in both modes: drive.sh reports a review bot's status comment instead of acting on it.
| ["reported", "handled", "parked"] as $done
| def settled($key; $hash):
    ($items[$key] // null) as $d
    | $d != null and ($d.disposition | IN($done[])) and ($hash == null or $d.hash == $hash);
  ($l.own.replies // []) as $own_replies
| def own_reply($c): any($own_replies[]; (.id != null and .id == $c.id) or (.id == null and .hash == $c.bodyHash));
  def check_item_key: "k:\(.key)@\($s.head)#\($g)";
  "x:\($s.head)#\($g)" as $conflict_key
| ($s.mergeable == "CONFLICTING" or $s.mergeStateStatus == "DIRTY") as $conflicting
| [$s.checks[] | select(.status == "failed" or .status == "action")] as $failing

# Row 6: one conflict item per observed head.
| (if $conflicting and (settled($conflict_key; null) | not)
   then [{row: 6, event: "conflict", key: $conflict_key}] else [] end) as $conflict_items

# Rows 7 to 9. A re-run item waits, with no event, until a newer run of the same check fails.
| [ $failing[] | . as $c | check_item_key as $k | ($items[$k] // null) as $d
    | if settled($k; null) then empty
      elif ((($l.repairs // {})[$c.key] // 0) >= stuck_repairs) then {row: 7, event: "check_stuck", key: $k, check: $c}
      elif $d != null and $d.disposition == "rerun" then
        if ($c.runId // 0) > ($d.run_id // 0) then {row: 9, event: "check_confirmed", key: $k, check: $c}
        else {row: null, event: null, key: $k, check: $c} end
      elif $c.rerunnable then {row: 8, event: "check_failed", key: $k, check: $c}
      else {row: 9, event: "check_confirmed", key: $k, check: $c} end
  ] as $check_items

# Row 10. A resolved thread and a minimized comment are closed conversations; the agent's own replies never count.
| [ ($s.comments[] | . + {kind: "issue_comment"}),
    ($s.reviews[] | select(.state != "PENDING" and ((.body // "") | test("\\S"))) | . + {kind: "review"}),
    ($s.threads[] | select(.isResolved | not) | . as $th
      | .comments[] | . + {kind: "thread_comment", thread: $th.id, path: $th.path, line: $th.line}) ]
  | map(select((.isMinimized | not) and (own_reply(.) | not) and (own_bot | not)))
  | sort_by(.createdAt // "")
  as $comments

# In watch, comments created before the session started are a baseline taken on the first poll; each stays
# quiet until its body hash changes. The viewer's own comments stay quiet too. Drive acts on both.
| (if $mode == "watch" and $started != null
   then $l.baseline // ([$comments[] | select((.createdAt // "" | try fromdateiso8601 catch null) as $c
                          | $c != null and $c < $started) | {key: ("c:" + .id), value: .bodyHash}] | from_entries)
   else null end) as $baseline
| def muted: $baseline != null
    and (($s.viewer != null and .author == $s.viewer) or $baseline["c:" + .id] == .bodyHash);
  [$comments[] | select(muted) | {key: ("c:" + .id), author}] as $muted
| [ $comments[] | select(muted | not)
    | ("c:" + .id) as $k | select(settled($k; .bodyHash) | not)
    # An untrusted author's comment sorts first and never counts toward the limit, so drive parks it before acting.
    | (if trusted then {row: 10, event: "comment"} else {row: 5, event: "untrusted_comment"} end)
    + {key: $k, hash: .bodyHash,
       comment: {id, kind, author, authorAssociation, url, excerpt: ((.body // "")[:excerpt_chars]),
         bodyLength: ((.body // "") | length), thread, path, line, review_state: .state}} ]
  as $comment_items

| ($conflict_items + $check_items + $comment_items) as $pending
| [$pending[] | select(.event != null)] | sort_by(.row) as $firing

# READY. Without a check 10 minutes after the head was first seen, the PR has no CI and reviews alone decide.
| (($heads[$s.head].first_seen // $t)) as $first_seen
| ((($s.checks | length) == 0) and ($t - $first_seen) >= no_ci_seconds) as $no_ci
| [ (if $s.state != "OPEN" then "state \($s.state)" else empty end),
    (if $s.isDraft then "draft" else empty end),
    (if $conflicting then "conflict with base"
     elif $s.mergeable != "MERGEABLE" then "mergeability \($s.mergeable // "unreadable")" else empty end),
    (if $no_ci then empty
     elif ($s.checks | length) == 0 then "no check has started on the head yet; it counts as having no CI 10 minutes after watch first sees it"
     else ($s.checks[] | select(.status != "pass") | "check \(.status): \(.name)") end),
    ($s.latestReviews[] | select(.state == "CHANGES_REQUESTED") | "changes requested: \(.author // "unknown")"),
    ($s.reviewRequests[] | "review requested: \(.reviewer // "unknown") has not reviewed yet"),
    (if $s.reviewDecision == "REVIEW_REQUIRED" then "review required"
     elif $s.reviewDecision == "CHANGES_REQUESTED" then "review decision is changes requested" else empty end),
    ([$s.threads[] | select(.isResolved | not)] | length
      | if . > 0 then "\(.) unresolved review thread(s)" else empty end),
    (if ($pending | length) > 0 then "\($pending | length) pending item(s)" else empty end)
  ] as $blockers

# A parked item among these keys keeps READY away, which ends a drive session through stalled.
| ([$s.latestReviews[] | select(.state == "CHANGES_REQUESTED") | .author]) as $rejecting
| [ ($failing[] | check_item_key),
    (if $conflicting then $conflict_key else empty end),
    ($s.threads[] | select(.isResolved | not) | .comments[] | "c:\(.id)"),
    ($s.reviews[] | select(.state == "CHANGES_REQUESTED" and (.author | IN($rejecting[]))) | "c:\(.id)")
  ] as $blocker_keys

| (($started != null and ($t - $started) >= session_seconds)
   or ((($l.rounds // 0) >= max_rounds) and any($firing[]; .row | IN(6, 9, 10)))) as $limit
| (($pending | length) == 0 and any($blocker_keys[]; ($items[.] // {}).disposition == "parked")) as $stalled

| [$items | keys[] | relevant($s.head; $g)] as $keys
| [ $pending[] | {key, event: (.event // "awaiting_rerun")}
    + (if .comment then {author: .comment.author, url: .comment.url}
       elif .check then {name: .check.name, url: .check.url} else {} end) ] as $pending_list
| { parked: [$keys[] | select($items[.].disposition == "parked")],
    reported: [$keys[] | select($items[.].disposition == "reported")],
    handled: [$keys[] | select($items[.].disposition == "handled")],
    unresolved: $blockers,
    muted: $muted,
    pending: $pending_list,
    reasons: ([$keys[] | select($items[.].reason != null) | {key: ., value: $items[.].reason}] | from_entries) } as $report

# Nothing dismisses an approval when a later commit is pushed, so only one on the head counts.
# A bot's approval never counts, and a head that still needs a repair or a base merge is not approved.
| (any($s.latestReviews[]; .state == "APPROVED" and .commit == $s.head and .authorType != "Bot")
   and all($s.latestReviews[]; .state != "CHANGES_REQUESTED")
   and $s.mergeable == "MERGEABLE"
   and ($no_ci or (($s.checks | length) > 0 and all($s.checks[]; .status == "pass")))) as $approved

| {repo: $s.repo, pr: $s.number, head: $s.head, gen: $g} as $base
| def stop($name): $base + {event: $name, report: $report};
  (if $s.state == "MERGED" then "MERGED"
   elif $s.state == "CLOSED" then "CLOSED"
   elif ($blockers | length) == 0 then "READY"
   else "NOT_READY" end) as $status
| { ledger: ({head: $head, heads: $heads} + (if $baseline != null then {baseline: $baseline} else {} end)),
    status: $status,
    event: (
      if $status == "MERGED" then stop("merged")
      elif $status == "CLOSED" then stop("closed")
      elif $approved then stop("approved")
      elif $status == "READY" then stop("ready")
      elif $limit then stop("limit")
      elif $stalled then stop("stalled")
      elif ($firing | length) > 0 then $base + ($firing[0] | del(.row))
      else null end),
    blockers: $blockers,
    pending: $pending_list,
    report: $report }
