#!/usr/bin/env bash
# Runs pick.sh and tells, in one line, whether the pick changed since the last run, so a schedule can notify the owner.
# It only reads GitHub; the one file it writes is its record, pick-next/watch.json in the clone's git common directory,
# which every worktree of the clone shares.
# Usage: watch.sh, from the clone.
# A change is a different list of items under waits on you (owner) or start next (next); blocked and local state never
# count. The line names the first item under waits on you when that group changed and is not empty, otherwise the first
# item under start next. A failed pick is told once, and later failures stay silent until a pick succeeds again.
# Exit: 0 nothing to tell, and nothing printed: the first run, an unchanged pick, or a failure already told,
#   3 one line printed to tell the owner: a changed pick or a new failure,
#   1 the record could not be read or written, 2 not inside a Git repository.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || {
  echo "pick-next watch: jq is required"
  exit 2
}
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "pick-next watch: not inside a Git repository"
  exit 2
}
record="${common}/pick-next/watch.json"

fail() {
  echo "pick-next watch: $1"
  exit 1
}

last='{}'
if [[ -e "${record}" ]]; then
  last="$(jq -ce 'objects' "${record}" 2>/dev/null)" || fail "cannot read ${record}"
fi

save() {
  { mkdir -p "${common}/pick-next" && printf '%s\n' "$1" >"${record}.tmp" && mv "${record}.tmp" "${record}"; } ||
    fail "cannot write ${record}"
}

err="$(mktemp)" || fail "cannot create a temporary file"
trap 'rm -f "${err}"' EXIT

if ! picked="$(bash "${dir}/pick.sh" 2>"${err}")"; then
  [[ "$(jq -r '.failed // false' <<<"${last}")" == true ]] && exit 0
  save "$(jq -c '.failed = true' <<<"${last}")"
  origin="$(git remote get-url origin 2>/dev/null)"
  name="$(sed -E 's#^.*github\.com[:/]([^/]+)/([^/]+)/?$#\1/\2#; s#\.git$##' <<<"${origin}")"
  echo "${name:-$(basename "${common%/.git}")}: pick-next failed: $(head -n1 "${err}")"
  exit 3
fi

# Only the item numbers, in order, decide whether the pick changed.
now="$(jq -ce '{owner: [.owner[].number], next: [.next[].number]}' <<<"${picked}")" || fail "pick.sh printed no pick"
save "$(jq -nc --argjson key "${now}" '{key: $key}')"
before="$(jq -c '.key // null' <<<"${last}")"
[[ "${before}" == null || "${before}" == "${now}" ]] && exit 0

jq -r --argjson last "${last}" '
  def ref: "(" + (if .kind == "pr" then "PR" else "Issue" end) + " " + (.number | tostring) + ")";
  .repo + ": " +
  if (.owner | length) > 0 and [.owner[].number] != $last.key.owner then
    "waits on you: " + .owner[0].title + " " + (.owner[0] | ref)
  elif (.next | length) > 0 then "start next: " + .next[0].title + " " + (.next[0] | ref)
  else "start next: nothing" end' <<<"${picked}" || fail "pick.sh printed no pick"
exit 3
