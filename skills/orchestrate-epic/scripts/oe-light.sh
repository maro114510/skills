# shellcheck shell=bash
# The light read, and what oe wait and oe status --watch decide with it.
# Each of them sources this file, so neither restates when a full oe ready read is due.
#
# A full read costs 2 GraphQL points per child Issue and 2 REST requests per open PR.
# The light read is one GraphQL query that costs 1 point for a 10-child Epic, and it shows whether anything oe ready reads has changed.
#
# What the light read holds, with the local state beside it, is the fingerprint:
#
# | Part | Changes when |
# |---|---|
# | The default branch head and its checks' state | A PR merges, or the base's checks finish |
# | Each child Issue's state and update time | It closes, or gets a comment, an edit, a label, or a dependency |
# | Each Issue branch's head, its checks' state and count, and its newest PR's state and update time | A push, a check or verdict finishing, a review, a comment, a merge, or a close |
# | This session's lock, the Issues' records on this host, and the worktrees of the agents | An agent starts or ends, or a record is written |
#
# The child Issues are those the previous full read printed, so the first read of an Epic fingerprints them after the full read.
# A thread resolved by itself, or a conflict that appears without a push, shows in no part, and the full read every full_read_every seconds finds it.
#
# A full read is also due at a deadline that time alone brings:
#
# | Deadline | When |
# |---|---|
# | A head with no checks | no_checks_grace seconds after its push, when the Issue's action turns from wait-ci to parked |
# | The latest full read | full_read_every seconds after it |
#
# oe-ready.jq writes the reason that light_deadline reads, `no checks yet on <sha>, <age>s after its push`.

# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2154 # branch_prefix, no_checks_grace, and full_read_every come from oe-config.sh, which the sourcing command has sourced
light_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prints the fields of the light read for the child Issue $1.
light_child_fields() {
  local n="$1"
  printf 'b%s: ref(qualifiedName: "refs/heads/%s%s") {\n' "${n}" "${branch_prefix}" "${n}"
  printf '  target { ... on Commit { oid statusCheckRollup { state contexts(first: 1) { totalCount } } } }\n'
  printf '  associatedPullRequests(first: 1, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { number state updatedAt } }\n'
  printf '}\n'
  printf 'c%s: issue(number: %s) { blockedBy(first: 100) { nodes { number state stateReason } } }' "${n}" "${n}"
}

# Prints the light read of Epic $2 in repository $1 as one line of JSON, for the child Issues numbered $3 on.
# With OE_LIGHT_COST set, also prints the dry-run cost GitHub would charge, on stderr.
# Returns 1 with the reason on stderr when the read fails.
light_read() {
  local repo="$1" epic="$2" template children="" n response cost="" err
  shift 2
  template="$(<"${light_dir}/oe-light.graphql")" || {
    echo "oe light: cannot read oe-light.graphql" >&2
    return 1
  }
  for n in "$@"; do
    [[ "${n}" =~ ^[1-9][0-9]*$ ]] || {
      echo "oe light: invalid Issue number: ${n}" >&2
      return 1
    }
    children+="$(light_child_fields "${n}")"$'\n'
  done
  [[ -z "${OE_LIGHT_COST:-}" ]] || cost='rateLimit(dryRun: true) { cost }'
  template="${template//__CHILDREN__/${children}}"
  template="${template//__COST__/${cost}}"
  err="$(mktemp)" || return 1
  if ! response="$(gh api graphql -f query="${template}" -F owner="${repo%/*}" -F repo="${repo#*/}" -F epic="${epic}" 2>"${err}")"; then
    echo "oe light: light read failed: $(head -n1 "${err}")" >&2
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
  if [[ -n "${cost}" ]]; then
    jq -r '"cost \(.data.rateLimit.cost)"' <<<"${response}" >&2
  fi
  jq -cS '.data | del(.rateLimit)' <<<"${response}" || {
    echo "oe light: light read unreadable" >&2
    return 1
  }
}

# Prints the number of each child Issue of Epic $2 in repository $1, one per line, from a light read that names none.
light_children() {
  local light
  light="$(light_read "$1" "$2")" || return 1
  jq -r '.repository.issue.subIssues.nodes[]?.number' <<<"${light}"
}

# Prints the local state that oe ready's output depends on beside GitHub's, for the child Issues numbered $3 on:
# the lock of the session holding Epic $2 in repository $1, the Issues' records, and the names under the worktree root.
light_local() {
  local repo="$1" epic="$2" n root
  shift 2
  lock_started "${repo}" "${epic}" 2>/dev/null || echo "no lock"
  for n in "$@"; do
    cat "$(record_path "${repo}" "${n}")" 2>/dev/null || true
  done
  if root="$(worktree_root 2>/dev/null)"; then
    for n in "${root}"/issue-*; do
      [[ ! -e "${n}" ]] || echo "${n##*/}"
    done
  fi
}

# Prints the fingerprint of Epic $2 in repository $1 for the child Issues numbered $3 on.
# Returns 1 when the light read fails, so the caller reads in full instead.
light_fingerprint() {
  local repo="$1" epic="$2" light
  shift 2
  light="$(light_read "${repo}" "${epic}" "$@")" || return 1
  {
    printf '%s\n' "${light}"
    light_local "${repo}" "${epic}" "$@"
  } | git hash-object --stdin
}

# Prints the epoch second at which the next full read is due, given the time $1 of the full read just made and its output $2.
# Each line of $2 holds an Issue number, an action, and a reason, separated by tabs.
# The time of a full read with no deadline of its own is full_read_every seconds on.
# A reason light_deadline cannot read counts as due at once, so a change in oe ready's words costs reads instead of a stale answer.
light_deadline() {
  local at="$1" due n action reason age
  due=$((at + full_read_every))
  while IFS=$'\t' read -r n action reason _; do
    [[ "${action}" == wait-ci && "${reason}" == "no checks yet on "* ]] || continue
    if [[ "${reason}" =~ ,\ ([0-9]+)s\ after\ its\ push$ ]]; then
      age="${BASH_REMATCH[1]}"
      ((at + no_checks_grace - age < due)) && due=$((at + no_checks_grace - age))
    else
      due=0
    fi
  done <<<"$2"
  printf '%s' "${due}"
}
