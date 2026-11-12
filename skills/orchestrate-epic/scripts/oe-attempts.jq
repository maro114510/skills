# Owner starts and the pushes that end them, shared by oe ready and oe attempt.
# A subcommand puts this file in front of its own jq program, and runs the definitions below on an Issue's records, oldest first.
#
# - An Owner start is an attempt record after the latest claim record, or any attempt record when there is no claim.
# - A start ended in a push when GitHub shows a push to the Issue branch from the start's time until the next start,
#   or until now for the latest start, so no agent's report decides it.
# - An attempt is a start that ended in a push, so a start that pushed nothing spends none of max_attempts.
# - $pushes holds the epoch seconds of each push to the Issue branch, as branch_pushes in oe-config.sh reads them.

def record_s: sub("\\.[0-9]+"; "") | fromdateiso8601;

# The Owner starts, oldest first, each with from and until in epoch seconds; until is null for the latest start.
def owner_starts:
  (map(.kind == "claim") | rindex(true)) as $claim
  | [.[($claim // -1) + 1:][] | select(.kind == "attempt") | .at | record_s]
  | [range(0; length) as $i | {from: .[$i], until: .[$i + 1]}];

# Whether the epoch second falls in the start $s.
def in_start($s): . >= $s.from and ($s.until == null or . < $s.until);

# Whether the start ended in a push.
def pushed($pushes): . as $s | any($pushes[]; in_start($s));

def attempts_used($pushes): [owner_starts[] | select(pushed($pushes))] | length;
