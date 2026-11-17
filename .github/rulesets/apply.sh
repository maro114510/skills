#!/usr/bin/env bash
# Applies main.json to a repository as its "Protect main" ruleset: creates it, or updates the one that carries the name.
# Usage: apply.sh <owner/repo>
# Needs: gh authenticated as a repository admin, because a ruleset is a repository setting.
# Exit: 0 applied, 1 gh failed (its error is on the output), 2 bad usage.
set -uo pipefail

if [[ $# -ne 1 || "$1" != */* ]]; then
  echo "Usage: apply.sh <owner/repo>" >&2
  exit 2
fi
repo="$1"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="${dir}/main.json"

name="$(jq -r '.name' "${file}")" || exit 1
list="$(gh api "repos/${repo}/rulesets?per_page=100" 2>&1)" || {
  echo "${list}"
  exit 1
}
id="$(jq -r --arg name "${name}" '[.[] | select(.name == $name) | .id][0] // empty' <<<"${list}")" || exit 1

if [[ -n "${id}" ]]; then
  out="$(gh api --method PUT "repos/${repo}/rulesets/${id}" --input "${file}" 2>&1)" && echo "updated ${id}"
else
  out="$(gh api --method POST "repos/${repo}/rulesets" --input "${file}" 2>&1)" && echo "created"
fi || {
  echo "${out}"
  exit 1
}
