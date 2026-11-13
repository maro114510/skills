# Owner starts and whether each pushed, shared by oe ready and oe attempt.
# A subcommand puts this file in front of its own jq program, and runs the definitions below on an Issue's records, oldest first.
#
# - An Owner start is an attempt record after the latest claim record, or any attempt record when there is no claim.
# - Each start records head, the head of the Issue branch when it began; the field is absent when the branch did not exist.
# - A start pushed when the head it left differs from the one it recorded.
#   - The head it left is the head of the next record that follows it, an attempt or an update: the next start's recorded head,
#     or the head an update recorded before it merged the base into the branch.
#   - With no such record, it is $current, the branch's head now.
#   - An update moves the head without an Owner, so reading the head after it would count a merge as the start's push.
# - An attempt is a start that pushed.
# - No agent's report decides it, so a start that ended in a question or in nothing never counts as an attempt.

# Whether each Owner start pushed, oldest first.
def start_flags($current):
  (map(.kind == "claim") | rindex(true)) as $claim
  | .[($claim // -1) + 1:] as $r
  | [range(0; $r | length) as $i
      | select($r[$i].kind == "attempt")
      | ([$r[$i + 1:][] | select(.kind == "attempt" or .kind == "update")] | first) as $next
      | (if $next == null then $current else $next.head end) != $r[$i].head];

def attempts_used($current): [start_flags($current)[] | select(.)] | length;

# How many of the latest starts, in a row, pushed nothing.
def starts_without_push($current): start_flags($current) | reverse | (index(true) // length);
