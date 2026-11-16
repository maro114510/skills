# Owner starts and whether each pushed, shared by oe ready and oe attempt.
# A subcommand puts this file in front of its own jq program, and runs the definitions below on an Issue's records, oldest first.
#
# - An Owner start is an attempt record after the latest claim record, or any attempt record when there is no claim.
# - Each start records head, the head of the Issue branch when it began; the field is absent when the branch did not exist.
# - A start pushed when the head read later differs from the one it recorded:
#   the next start's recorded head, or $current, the branch's head now, for the latest start.
# - An attempt is a start that pushed.
# - No agent's report decides it, so a start that ended in a question or in nothing never counts as an attempt.

def owner_starts:
  (map(.kind == "claim") | rindex(true)) as $claim
  | [.[($claim // -1) + 1:][] | select(.kind == "attempt")];

# Whether each Owner start pushed, oldest first.
def start_flags($current):
  owner_starts as $s
  | [range(0; $s | length) as $i
      | (if $i + 1 < ($s | length) then $s[$i + 1].head else $current end) != $s[$i].head];

def attempts_used($current): [start_flags($current)[] | select(.)] | length;

# How many of the latest starts, in a row, pushed nothing.
def starts_without_push($current): start_flags($current) | reverse | (index(true) // length);
