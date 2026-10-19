#!/usr/bin/env bash
# Classifies an Epic's freeze state and Epic-wide budget from its comments, so a re-invoked loop
# recovers both from GitHub instead of from memory. Read-only: it never posts or edits a comment.
# Usage: epic-freeze.sh <owner/repo> <epic-number> [<counter>=<n> ...]          query GitHub
#        epic-freeze.sh --snapshot <file|-> --me <login> [<counter>=<n> ...]     classify a saved
#          REST comment array, as `gh api .../comments --paginate --slurp | jq 'add // []'` prints
# <counter> is worker_dispatches, reviewer_passes, or fix_cycles; each pair asks whether the ledger
# can take <n> more without exceeding that counter's bound.
# Output, one per line: status=<CLEAR|FROZEN|RELEASE|UNREADABLE>, reason=, freeze_id=, release_id=,
#   ledger_id=, then ledger_release= and <counter>=<used>/<bound> when a ledger exists, then
#   reserve=<ok|exceed> only when status=CLEAR and a pair was given.
# Exit: 0 classified, 1 a signal could not be read (status=UNREADABLE), 2 usage error.
# Act — dispatch, review, ship, merge — only on exit 0 with status=CLEAR, and with reserve=ok
# when a reservation was asked. FROZEN and RELEASE both hold every action.
set -uo pipefail

usage() {
  echo "$1" >&2
  echo "Usage: epic-freeze.sh <owner/repo> <epic-number> [<counter>=<n> ...] | --snapshot <file|-> --me <login> [<counter>=<n> ...]" >&2
  exit 2
}

hold() {
  printf 'status=UNREADABLE\nreason=%s\n' "$1"
  exit 1
}

# The trust rule is the one commands §1.5's oe_human applies: OWNER, MEMBER, or COLLABORATOR, a
# body not starting with `orchestrate-epic` or `<!--`, and every non-blank trimmed line exactly the
# command. Only the loop identity's own comments count as a freeze marker or a ledger, so a planted
# marker can neither fake a freeze nor hand the loop a larger budget.
# shellcheck disable=SC2016 # jq program, not shell expansion.
CLASSIFY='
  def counters: ["worker_dispatches", "reviewer_passes", "fix_cycles"];
  def mine($m): [.[] | select(.user.login == $me and ((.body // "") | startswith($m)))]
    | sort_by(.created_at, .id) | last;
  def lines: (.body // "") | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));
  def release_command:
    (.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")
    and (((.body // "") | startswith("orchestrate-epic") or startswith("<!--")) | not)
    and (lines | length > 0 and all(.[]; . == "epic-release"));
  # A comment edited in the web UI can come back with CRLF line endings, so trim any whitespace.
  def field($name): (.body // "") | split("\n")
    | map(capture("^- " + $name + ":\\s*(?<v>.*?)\\s*$").v) | first;
  def counter($name): field($name) // ""
    | capture("^(?<used>[0-9]+) / (?<bound>[0-9]+)$")? // null
    | if . then {used: (.used | tonumber), bound: (.bound | tonumber)} else null end;

  if type != "array" or any(.[]; type != "object") then {status: "UNREADABLE", reason: "comments are not an array of objects"}
  else
    mine("<!-- orchestrate-epic:freeze -->") as $freeze
    | mine("<!-- orchestrate-epic:ledger -->") as $ledger_c
    | (if $freeze then [.[] | select([.created_at, .id] > [$freeze.created_at, $freeze.id] and release_command)]
         | sort_by(.created_at, .id) | first
       else null end) as $release
    | (if $ledger_c then
         {id: $ledger_c.id, release: ($ledger_c | field("release") // ""),
          counts: ([counters[] as $n | {key: $n, value: ($ledger_c | counter($n))}] | from_entries)}
       else null end) as $ledger
    | ([$ledger.counts // {} | to_entries[] | select(.value == null) | .key]
       + (if $ledger and ($ledger.release | test("^([0-9]+|none)$") | not) then ["release"] else [] end)) as $bad
    | {freeze_id: ($freeze.id // "none"), release_id: ($release.id // "none"), ledger: $ledger}
    | if ($bad | length) > 0 then {status: "UNREADABLE", reason: "ledger \($ledger.id) has no readable \($bad | join(", "))"}
      elif $freeze and ($release | not) then
        . + {status: "FROZEN", reason: ($freeze | field("reason") // "" | if . == "" then "unrecorded" else . end)}
      elif $freeze and (($ledger.release // "none") != ($release.id | tostring)) then
        . + {status: "RELEASE", reason: "epic-release \($release.id) lifts freeze \($freeze.id); reset the ledger before acting"}
      elif ($reserve | length) > 0 and ($ledger | not) then
        {status: "UNREADABLE", reason: "no ledger to reserve against; create it first"} + .
      else
        . + {status: "CLEAR",
             reason: (if $release then "freeze \($freeze.id) released by \($release.id)" else "no freeze" end)}
        | if ($reserve | length) > 0 then
            ([$reserve[] as $r | $ledger.counts[$r.name] as $c
              | select($c.used + $r.n > $c.bound) | "\($r.name) \($c.used) + \($r.n) > \($c.bound)"]) as $over
            | if ($over | length) > 0 then . + {reserve: "exceed", reason: ($over | join("; "))}
              else . + {reserve: "ok", reason: "within bounds"} end
          else . end
      end
  end
  | "status=\(.status)", "reason=\(.reason)",
    (if .freeze_id != null then "freeze_id=\(.freeze_id)", "release_id=\(.release_id)",
       "ledger_id=\(.ledger.id // "none")" else empty end),
    (if .ledger and .status != "UNREADABLE" then "ledger_release=\(.ledger.release)",
       (.ledger.counts | to_entries[] | "\(.key)=\(.value.used)/\(.value.bound)") else empty end),
    (if .reserve then "reserve=\(.reserve)" else empty end)'

RESERVE='[]'
parse_reserve() {
  local pair name n
  for pair in "$@"; do
    [[ "${pair}" =~ ^(worker_dispatches|reviewer_passes|fix_cycles)=([1-9][0-9]*)$ ]] ||
      usage "Invalid reservation: ${pair}"
    name="${BASH_REMATCH[1]}"
    n="${BASH_REMATCH[2]}"
    RESERVE="$(jq -c --arg name "${name}" --argjson n "${n}" '. + [{name: $name, n: $n}]' <<<"${RESERVE}")"
  done
}

classify() {
  local comments="$1" me="$2" result
  [[ -n "${comments}" ]] || hold "empty response"
  result="$(jq -r --arg me "${me}" --argjson reserve "${RESERVE}" "${CLASSIFY}" <<<"${comments}" 2>/dev/null)" ||
    hold "response is not JSON of the expected shape"
  printf '%s\n' "${result}"
  grep -qxF 'status=UNREADABLE' <<<"${result}" && exit 1
  exit 0
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

if [[ "${1:-}" == --snapshot ]]; then
  [[ $# -ge 4 && "$3" == --me && -n "$4" ]] || usage "--snapshot needs a file or - and --me <login>"
  src="$2"
  me="$4"
  shift 4
  parse_reserve "$@"
  if [[ "${src}" == - ]]; then
    classify "$(cat)" "${me}"
  else
    [[ -r "${src}" ]] || usage "Cannot read snapshot: ${src}"
    classify "$(cat "${src}")" "${me}"
  fi
fi

[[ $# -ge 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
repo="$1"
epic="$2"
shift 2
parse_reserve "$@"

err="$(mktemp)" || hold "mktemp failed"
trap 'rm -f "${err}"' EXIT
me="$(gh api user --jq .login 2>"${err}")" && [[ -n "${me}" ]] ||
  hold "gh api user failed: $(head -n1 "${err}")"
comments="$(
  set -o pipefail
  gh api "repos/${repo}/issues/${epic}/comments" --paginate --slurp 2>"${err}" | jq -c 'add // []'
)" ||
  hold "comment read failed: $(head -n1 "${err}")"
classify "${comments}" "${me}"
