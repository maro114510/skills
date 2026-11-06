#!/usr/bin/env bash
# Writes the personal Herdr automation that runs watch.sh for this clone every 5 minutes and notifies the owner with
# the line it prints, then checks the automation with herdr-automate check. It never approves the automation: the
# owner does, with herdr-automate approve in their own terminal.
# Usage: watch-setup.sh, from the clone, inside Herdr.
# Writes ~/.config/herdr-automate/automations/pick-next-<owner>-<repo>.luau, replacing any earlier one. The
# automation runs in the main worktree with the PATH of this shell, because the Herdr daemon may not find gh and jq.
# Prints the file's path, then herdr-automate check's plan, then one line for each of a stopped daemon and paused
# scheduling, naming the command that fixes it.
# Exit: 0 written and checked, 1 the file could not be written or herdr-automate check rejected it,
#   2 not inside Herdr, herdr-automate missing, not a clone whose origin is on GitHub, or a path or PATH holding a
#   single quote.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  echo "pick-next watch: $1" >&2
  exit 2
}

fail() {
  echo "pick-next watch: $1" >&2
  exit 1
}

[[ "${HERDR_ENV:-}" == 1 ]] || usage "watching needs Herdr, and this session does not run inside it"
automate="$(command -v herdr-automate)" || automate=/Applications/Herdr.app/Contents/MacOS/herdr-automate
[[ -x "${automate}" ]] || usage "herdr-automate is not on PATH or in /Applications/Herdr.app"
command -v jq >/dev/null 2>&1 || usage "jq is required"

origin="$(git remote get-url origin 2>/dev/null)" || usage "Not inside a Git repository with an origin remote"
origin_re='github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$'
[[ "${origin}" =~ ${origin_re} ]] || usage "origin is not a GitHub repository: ${origin}"
owner="${BASH_REMATCH[1]}"
repo="${BASH_REMATCH[2]%.git}"

# The first worktree git lists is the main one, which outlives every linked worktree.
main="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[[ -n "${main}" ]] || usage "cannot find the main worktree"
main="$(cd "${main}" && pwd -P)" || usage "cannot enter the main worktree ${main}"
for value in "${main}" "${dir}" "${PATH}"; do
  [[ "${value}" != *"'"* ]] || usage "a path holding a single quote cannot go into the automation: ${value}"
done

name="pick-next-${owner}-${repo}"
file="${HOME}/.config/herdr-automate/automations/${name}.luau"
mkdir -p "$(dirname "${file}")" || fail "cannot create $(dirname "${file}")"
cat >"${file}" <<EOF || fail "cannot write ${file}"
-- Written by pick-next watch-setup.sh for ${owner}/${repo}. Run /pick-next watch again to rewrite it.
herdr.caps { agents_per_run = 0, tokens_per_day = 0, wall_time = "2m" }

herdr.every("5m", { name = "${name}" }, function()
  local v = sh("cd '${main}' && PATH='${PATH}' bash '${dir}/watch.sh'", { check = false, timeout = "1m" })
  if not v.ok then
    notify(v.log_tail)
  end
end)
EOF

echo "${file}"
plan="$("${automate}" check "${file}" 2>&1)" || fail "herdr-automate check rejected ${file}: ${plan}"
echo "${plan}"

status="$("${automate}" status --json 2>/dev/null)" || exit 0
[[ "$(jq -r '.daemon.running' <<<"${status}")" != false ]] ||
  echo "The herdr-automate daemon is not running: run herdr-automate start"
[[ "$(jq -r '.daemon.paused_all' <<<"${status}")" != true ]] ||
  echo "Scheduling is paused: run herdr-automate resume --all"
exit 0
