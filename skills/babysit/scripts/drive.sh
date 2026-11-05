#!/usr/bin/env bash
# Drives one pull request without a harness: loops on wait.sh in drive mode until a stop event, runs every
# deterministic step itself, and invokes the agent command from git config skills.babysit.agent once per
# check, conflict, or comment event that needs judgment.
# Usage: drive.sh <owner/repo> <pr>
# The agent runs in the drive worktree with the event file and result file named in its prompt and in
# BABYSIT_EVENT_FILE and BABYSIT_RESULT_FILE. It edits and commits there and writes one result:
#   {"outcome":"fixed"|"reply"|"none"|"park","reply":"<text>","reason":"<text>"}
# Only this script pushes, replies, parks, and records, through the scripts beside it. The agent never gets the
# session token, GH_TOKEN, or GITHUB_TOKEN, and a remote head that moves while it runs stops the drive.
# A review bot's status comment is recorded as reported with no agent call. A time limit restarts the session
# while rounds are below the cap. Nothing here merges, marks the pull request ready, or requests a review.
# Prints one JSON line when it stops: {stop, report, rounds, pushes, errors}. Progress goes to stderr.
# Test hooks: BABYSIT_WAIT replaces wait.sh, and BABYSIT_PR_STATE replaces pr-state.sh here and in the scripts it calls.
# Exit: 0 approved, ready, or merged; 1 closed, stalled, the rounds cap, an API failure, a nonzero agent exit,
# or a head that moved under the agent; 2 usage or configuration error; 3 another session holds the pull request.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

WAIT="${BABYSIT_WAIT:-${script_dir}/wait.sh}"
PR_STATE="${BABYSIT_PR_STATE:-${script_dir}/pr-state.sh}"
WAIT_MINUTES=60
# evaluate.jq's max_rounds: a limit at this many rounds is the rounds cap, below it the 8-hour session mark.
MAX_ROUNDS=5

usage() {
  echo "$1" >&2
  echo "Usage: drive.sh <owner/repo> <pr>" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v git >/dev/null 2>&1 || usage "git is required"

(($# == 2)) || usage "drive.sh takes a repository and a pull request number"
repo="$1"
pr="$2"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr}"
babysit_ledger_path "${repo}" "${pr}" >/dev/null || usage "Not inside a Git repository"
agent_cmd="$(git config --get skills.babysit.agent)" || usage "git config skills.babysit.agent is not set"
# Split on whitespace without shell evaluation; the prompt becomes the last argument.
read -r -a agent <<<"${agent_cmd}"
((${#agent[@]} > 0)) || usage "git config skills.babysit.agent is empty"

snapshot() {
  "${PR_STATE}" "${repo}" "${pr}" 2>/dev/null </dev/null
}

snap="$(snapshot)" || {
  echo "Could not read ${repo}#${pr} from GitHub" >&2
  exit 1
}
why_not="$(jq -r '[ (if .viewer != .author then "authored by \(.author), not \(.viewer)" else empty end),
  (if .isCrossRepository != false then "from a fork" else empty end),
  (if .state != "OPEN" then "\(.state), not open" else empty end),
  (if .automationOwner != null then "owned by the automation \(.automationOwner)" else empty end)] | join("; ")' \
  <<<"${snap}")" || usage "Unreadable pull request snapshot"
[[ -z "${why_not}" ]] || usage "Cannot drive ${repo}#${pr}: ${why_not}"

token=""
errors='[]'
work=""

note() {
  echo "drive: $1" >&2
}

add_error() {
  errors="$(jq -c --arg e "$1" '. + [$e]' <<<"${errors}")"
  note "$1"
}

# Stops with exit $1 after clearing the lock, unless the lock is already another session's, and prints the report.
finish() {
  local code="$1" stop="$2" report="${3:-null}" shown
  if ((code != 3)) && [[ -n "${token}" ]]; then
    bash "${script_dir}/ledger.sh" stop "${repo}" "${pr}" "${token}" >/dev/null 2>&1
  fi
  [[ -z "${work}" ]] || rm -rf "${work}"
  shown="$(bash "${script_dir}/ledger.sh" show "${repo}" "${pr}" 2>/dev/null)" || shown='{}'
  jq -nc --arg stop "${stop}" --argjson report "${report}" --argjson errors "${errors}" --argjson l "${shown}" \
    '{stop: $stop, report: $report, rounds: ($l.rounds // 0), pushes: ($l.own.pushes // []), errors: $errors}'
  exit "${code}"
}

# Maps a helper script's lock and usage exits onto the drive's own stop.
helper_failed() {
  (($1 == 3)) && finish 3 "another session took the pull request over"
  finish 2 "$2 failed with exit $1"
}

start_session() {
  local code
  token="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [[ -n "${token}" ]] || token="drive-$(babysit_now)-$$-${RANDOM}"
  bash "${script_dir}/ledger.sh" start "${repo}" "${pr}" "${token}" >/dev/null
  code=$?
  if ((code != 0)); then
    token=""
    ((code == 3)) && finish 3 "another session holds the pull request"
    finish 2 "ledger.sh start failed with exit ${code}"
  fi
}

record() {
  local key="$1" disposition="$2" hash="$3" code
  local args=("${repo}" "${pr}" "${token}" "${key}" "${disposition}")
  [[ -z "${hash}" ]] || args+=(--hash "${hash}")
  bash "${script_dir}/ledger.sh" record "${args[@]}" >/dev/null
  code=$?
  ((code == 0)) || helper_failed "${code}" "ledger.sh record"
  note "${disposition} ${key}"
}

park() {
  local key="$1" hash="$2" reason="$3" code
  local args=(--session "${token}" --key "${key}" --reason "${reason}")
  [[ -z "${hash}" ]] || args+=(--hash "${hash}")
  bash "${script_dir}/park.sh" "${repo}" "${pr}" "${args[@]}" >/dev/null
  code=$?
  ((code == 0)) || helper_failed "${code}" "park.sh"
  note "parked ${key}: ${reason}"
}

# Succeeds when comment $1, a pr-state comment object, is a review bot's status comment: its author is the bot
# and its body holds one of that bot's status markers. A bot's review findings carry no such marker.
bot_status() {
  jq -e '(.author == "coderabbitai"
      and ((.body // "") | test("<!-- This is an auto-generated comment: [^>]* by coderabbit\\.ai -->")))
    or (.author == "chatgpt-codex-connector"
      and ((.body // "") | test("<!-- codex-(pull-request-review-summary|review-receipt)(:v[0-9]+)? -->")))' \
    <<<"$1" >/dev/null 2>&1
}

# Posts reply text $1 for the comment event $2. Succeeds when the reply went out; otherwise the item is parked.
post_reply() {
  local text="$1" line="$2" key hash thread out code file target
  key="$(jq -r '.key' <<<"${line}")"
  hash="$(jq -r '.hash // ""' <<<"${line}")"
  thread="$(jq -r '.comment.thread // ""' <<<"${line}")"
  file="${work}/reply.md"
  printf '%s\n' "${text}" >"${file}"
  target=(--conversation)
  [[ -z "${thread}" ]] || target=(--thread "${thread}")
  out="$(bash "${script_dir}/reply.sh" "${repo}" "${pr}" --session "${token}" "${target[@]}" --body-file "${file}")"
  code=$?
  case "${code}" in
  0) return 0 ;;
  10) park "${key}" "${hash}" "the thread already holds 2 agent replies" ;;
  11)
    if jq -e 'has("owner")' <<<"${out}" >/dev/null 2>&1; then
      finish 1 "another automation owns the pull request: $(jq -r .owner <<<"${out}")"
    fi
    park "${key}" "${hash}" "the agent's reply asks a bot to approve or resolve"
    ;;
  1)
    if jq -e '.posted == true' <<<"${out}" >/dev/null 2>&1; then
      add_error "reply for ${key}: $(jq -r '.error // ""' <<<"${out}")"
      return 0
    fi
    park "${key}" "${hash}" "GitHub did not accept the agent's reply"
    ;;
  *) helper_failed "${code}" "reply.sh" ;;
  esac
  return 1
}

# Pushes the worktree's commits for event $1 from start $2 on branch $3. Succeeds when the push went out.
push_fix() {
  local line="$1" start="$2" branch="$3" wt="$4" key hash out code checks=()
  key="$(jq -r '.key' <<<"${line}")"
  hash="$(jq -r '.hash // ""' <<<"${line}")"
  [[ "$(jq -r '.event' <<<"${line}")" != check_* ]] || checks=(--check "$(jq -r '.check.key' <<<"${line}")")
  out="$(bash "${script_dir}/push.sh" "${repo}" "${pr}" --session "${token}" --worktree "${wt}" --start "${start}" \
    --branch "${branch}" ${checks[@]+"${checks[@]}"})"
  code=$?
  case "${code}" in
  0) return 0 ;;
  10) park "${key}" "${hash}" "the gate parked the fix: $(jq -r '.reason + " " + (.matches // [] | tojson)' <<<"${out}" 2>/dev/null)" ;;
  11)
    if jq -e 'has("owner")' <<<"${out}" >/dev/null 2>&1; then
      finish 1 "another automation owns the pull request: $(jq -r .owner <<<"${out}")"
    fi
    # A head that moved since the start is the next event's to describe, so the item stays unrecorded.
    jq -e '.reason | test("remote branch moved")' <<<"${out}" >/dev/null 2>&1 ||
      park "${key}" "${hash}" "the gate refused the fix: $(jq -r '.reason // ""' <<<"${out}")"
    ;;
  1)
    if jq -e '.pushed == true' <<<"${out}" >/dev/null 2>&1; then
      add_error "push for ${key}: $(jq -r '.error // ""' <<<"${out}")"
      return 0
    fi
    park "${key}" "${hash}" "git push failed"
    ;;
  *) helper_failed "${code}" "push.sh" ;;
  esac
  return 1
}

# Hands event $1 to the agent in a freshly prepared worktree, then acts on the result it wrote.
invoke_agent() {
  local line="$1" event key hash head now branch prep code wt start event_file result_file prompt
  local outcome reply reason allowed sha
  event="$(jq -r '.event' <<<"${line}")"
  key="$(jq -r '.key' <<<"${line}")"
  hash="$(jq -r '.hash // ""' <<<"${line}")"
  head="$(jq -r '.head' <<<"${line}")"
  now="$(snapshot)" || {
    add_error "could not read the pull request for ${key}"
    return
  }
  branch="$(jq -r '.headRef' <<<"${now}")"
  prep="$(bash "${script_dir}/worktree.sh" prepare "${repo}" "${pr}" --session "${token}" --branch "${branch}" \
    --head "${head}")"
  code=$?
  # Exit 1 means the pull request moved since the event, so the next event describes it.
  ((code == 1)) && return
  ((code == 0)) || helper_failed "${code}" "worktree.sh prepare"
  wt="$(jq -r '.path' <<<"${prep}")"
  start="$(jq -r '.sha' <<<"${prep}")"

  rm -rf "${work}"
  work="$(mktemp -d)" || finish 2 "cannot create a temporary directory"
  event_file="${work}/event.json"
  result_file="${work}/result.json"
  # The event carries a 200-character excerpt; the agent gets the whole body.
  jq -c --argjson s "${now}" '. + {baseRef: $s.baseRef, headRef: $s.headRef}
    | if .comment then .comment.id as $id
        | .comment.body = ([$s.comments[], $s.reviews[], $s.threads[].comments[]] | map(select(.id == $id))[0].body // null)
      else . end' <<<"${line}" >"${event_file}" || finish 2 "cannot write the event file"
  prompt="Follow the \"Single event\" section of ${script_dir%/scripts}/SKILL.md for one babysit event, then exit. Event file: ${event_file}. Worktree: ${wt}. Result file: ${result_file}."
  note "invoking the agent for ${event} ${key}"
  (cd "${wt}" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    BABYSIT_EVENT_FILE="${event_file}" BABYSIT_RESULT_FILE="${result_file}" "${agent[@]}" "${prompt}" </dev/null >&2)
  code=$?
  ((code == 0)) || finish 1 "the agent exited ${code} on ${key}"

  # The agent must not push. A moved remote head means it did, or someone else did, so stop for a human.
  now="$(snapshot)" || {
    add_error "could not read the pull request after the agent ran on ${key}"
    return
  }
  if [[ "$(jq -r '.head' <<<"${now}")" != "${start}" ]]; then
    park "${key}" "${hash}" "the remote head moved while the agent ran"
    finish 1 "the remote head moved while the agent ran"
  fi

  outcome="$(jq -r 'if type == "object" then (.outcome // "") | strings else "" end' "${result_file}" 2>/dev/null)"
  reply="$(jq -r '(.reply // "") | strings' "${result_file}" 2>/dev/null)"
  reason="$(jq -r '(.reason // "") | strings' "${result_file}" 2>/dev/null)"
  allowed="fixed park"
  [[ "${event}" != comment ]] || allowed="fixed reply none park"
  if [[ -z "${outcome}" || " ${allowed} " != *" ${outcome} "* ]]; then
    park "${key}" "${hash}" "the agent left no valid result"
    return
  fi
  case "${outcome}" in
  fixed)
    sha="$(git -C "${wt}" rev-parse HEAD 2>/dev/null)"
    if [[ "${sha}" == "${start}" ]]; then
      park "${key}" "${hash}" "the agent reported a fix without a commit"
      return
    fi
    push_fix "${line}" "${start}" "${branch}" "${wt}" || return
    if [[ "${event}" == comment && "${reply}" =~ [^[:space:]] ]]; then
      post_reply "${reply}" "${line}" || return
    fi
    record "${key}" handled "${hash}"
    ;;
  reply)
    [[ "${reply}" =~ [^[:space:]] ]] || {
      park "${key}" "${hash}" "the agent chose a reply but wrote none"
      return
    }
    post_reply "${reply}" "${line}" || return
    record "${key}" handled "${hash}"
    ;;
  none) record "${key}" handled "${hash}" ;;
  park) park "${key}" "${hash}" "${reason:-the agent asked for a human}" ;;
  esac
}

start_session
while true; do
  line="$("${WAIT}" "${repo}" "${pr}" --max "${WAIT_MINUTES}" --session "${token}" --mode drive)"
  code=$?
  case "${code}" in
  0) ;;
  1) finish 1 "the GitHub API failed 5 times in a row" ;;
  3) finish 3 "another session took the pull request over" ;;
  *) finish 2 "wait.sh failed with exit ${code}" ;;
  esac
  event="$(jq -r '.event // ""' <<<"${line}" 2>/dev/null)" || finish 2 "wait.sh printed no event"
  report="$(jq -c '.report // null' <<<"${line}")"
  case "${event}" in
  idle) ;;
  merged | closed)
    bash "${script_dir}/worktree.sh" remove "${repo}" "${pr}" --session "${token}" >&2 ||
      add_error "could not remove the drive worktree"
    [[ "${event}" == merged ]] && finish 0 merged "${report}"
    finish 1 closed "${report}"
    ;;
  approved | ready) finish 0 "${event}" "${report}" ;;
  stalled) finish 1 stalled "${report}" ;;
  limit)
    rounds="$(bash "${script_dir}/ledger.sh" show "${repo}" "${pr}" | jq -r '.rounds // 0')"
    ((rounds >= MAX_ROUNDS)) && finish 1 limit "${report}"
    note "the session reached its time limit with ${rounds} round(s) used; starting a new one"
    bash "${script_dir}/ledger.sh" stop "${repo}" "${pr}" "${token}" >/dev/null
    code=$?
    ((code == 0)) || helper_failed "${code}" "ledger.sh stop"
    start_session
    ;;
  check_stuck)
    park "$(jq -r '.key' <<<"${line}")" "" "still failing after 2 repair pushes"
    ;;
  check_failed)
    bash "${script_dir}/rerun.sh" "${repo}" "${pr}" --session "${token}" --key "$(jq -r '.key' <<<"${line}")" \
      --workflow-run "$(jq -r '.check.workflowRunId' <<<"${line}")" --run-id "$(jq -r '.check.runId' <<<"${line}")" >&2
    code=$?
    case "${code}" in
    0) note "re-ran $(jq -r '.check.key' <<<"${line}")" ;;
    1) invoke_agent "${line}" ;;
    *) helper_failed "${code}" "rerun.sh" ;;
    esac
    ;;
  check_confirmed | conflict) invoke_agent "${line}" ;;
  comment)
    snap="$(snapshot)" || {
      add_error "could not read the pull request for $(jq -r '.key' <<<"${line}")"
      continue
    }
    comment="$(jq -c --arg id "$(jq -r '.comment.id' <<<"${line}")" \
      '[.comments[], .reviews[], .threads[].comments[]] | map(select(.id == $id))[0] // {}' <<<"${snap}")"
    if bot_status "${comment}"; then
      record "$(jq -r '.key' <<<"${line}")" reported "$(jq -r '.hash // ""' <<<"${line}")"
    else
      invoke_agent "${line}"
    fi
    ;;
  *) finish 2 "unknown event: ${event}" ;;
  esac
done
