#!/usr/bin/env bash
# Posts one agent reply and records it, so wait never raises it back as a new comment.
# Usage: reply.sh <owner/repo> <pr> --session <token> (--thread <review thread id> | --conversation) --body-file <file>
# A thread reply answers that review thread. --conversation posts a comment on the pull request, where issue
# comments and review bodies share one capped thread. At most 2 agent replies are posted per thread.
# It only ever replies: nothing here resolves or unresolves a thread.
# Prints one JSON line. Test hook BABYSIT_GH replaces gh.
# Exit: 0 posted, 1 the post failed, 2 usage error, 3 the lock is not ours, 10 the thread already holds 2 replies.
# An exit of 1 or 3 with "posted":true in the JSON line means the reply is out and only the ledger write failed.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

GH="${BABYSIT_GH:-gh}"
MAX_REPLIES=2

usage() {
  echo "$1" >&2
  echo "Usage: reply.sh <owner/repo> <pr> --session <token> (--thread <review thread id> | --conversation) --body-file <file>" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

repo="${1:-}"
pr="${2:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 2
token=""
thread=""
conversation=0
body_file=""
while (($# > 0)); do
  case "$1" in
  --conversation)
    conversation=1
    shift
    continue
    ;;
  --session) token="${2:-}" ;;
  --thread) thread="${2:-}" ;;
  --body-file) body_file="${2:-}" ;;
  *) usage "Unknown option: $1" ;;
  esac
  (($# >= 2)) || usage "$1 needs a value"
  shift 2
done
[[ "${token}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
if ((conversation == 1)); then
  [[ -z "${thread}" ]] || usage "Use --thread or --conversation, not both"
  target=conversation
else
  [[ "${thread}" =~ ^[A-Za-z0-9_=-]+$ ]] || usage "Give --thread <review thread id> or --conversation"
  target="${thread}"
fi
[[ -n "${body_file}" && -r "${body_file}" ]] || usage "--body-file needs a readable file"
# The substitution drops trailing newlines, which GitHub drops from a stored body as well.
body="$(cat "${body_file}")"
[[ "${body}" =~ [^[:space:]] ]] || usage "The reply is empty"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# The hash pr-state.sh gives a comment: the sha256 of the base64 of its body.
hash="$(printf '%s' "${body}" | jq -Rrs '@base64' | tr -d '\n' | sha256)"

# The lock check comes first, so a session that lost the PR posts nothing.
bash "${script_dir}/ledger.sh" touch "${repo}" "${pr}" "${token}" || exit $?
count="$(bash "${script_dir}/ledger.sh" replies "${repo}" "${pr}" "${target}")" || exit 2
if ((count >= MAX_REPLIES)); then
  jq -nc --arg target "${target}" --argjson count "${count}" \
    '{posted: false, reason: "this thread already holds the most agent replies", target: $target, replies: $count}'
  exit 10
fi

# The hash is listed before posting, so a reply that lands before its id is written is still known as ours.
bash "${script_dir}/ledger.sh" reply-begin "${repo}" "${pr}" "${token}" "${target}" --hash "${hash}" || exit $?

# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
THREAD_REPLY='mutation($id: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) { comment { id } }
}'
if ((conversation == 1)); then
  id="$("${GH}" api "repos/${repo}/issues/${pr}/comments" -f body="${body}" --jq .node_id 2>/dev/null </dev/null)"
else
  id="$("${GH}" api graphql -f query="${THREAD_REPLY}" -f id="${thread}" -f body="${body}" \
    --jq .data.addPullRequestReviewThreadReply.comment.id 2>/dev/null </dev/null)"
fi
post_status=$?
if ((post_status != 0)) || [[ -z "${id}" || "${id}" == null ]]; then
  jq -nc --arg target "${target}" '{posted: false, reason: "GitHub did not accept the reply", target: $target}'
  exit 1
fi

bash "${script_dir}/ledger.sh" reply-done "${repo}" "${pr}" "${token}" "${target}" --hash "${hash}" --id "${id}"
done_code=$?
if ((done_code != 0)); then
  # The reply is out, so the caller must not read this as a failed post; 3 still means the lock is gone.
  jq -nc --arg id "${id}" --arg target "${target}" \
    '{posted: true, id: $id, target: $target, error: "the reply was posted but the ledger write failed"}'
  ((done_code == 3)) && exit 3
  exit 1
fi
replies="$(bash "${script_dir}/ledger.sh" replies "${repo}" "${pr}" "${target}")"
jq -nc --arg id "${id}" --arg target "${target}" --argjson replies "${replies}" \
  '{posted: true, id: $id, target: $target, replies: $replies}'
