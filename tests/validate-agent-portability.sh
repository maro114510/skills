#!/usr/bin/env bash
set -euo pipefail

ALLOWED_AGENT_KEYS='name description'
GUIDANCE='portable agents may only use: description, name'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
agents_dir="${repo_root}/agents"

extract_keys() {
  awk '
    BEGIN { infront = 0 }
    NR == 1 {
      if ($0 ~ /^---[[:space:]]*$/) infront = 1
      next
    }
    !infront { next }
    /^---[[:space:]]*$/ { exit }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]/ { next }
    {
      if (match($0, /^[^:]+:/)) {
        key = substr($0, 1, RLENGTH - 1)
        sub(/[[:space:]]+$/, "", key)
      } else {
        key = $0
      }
      print key
    }
  ' "$1"
}

status=0
count=0
for agent_path in "${agents_dir}"/*.md; do
  [[ -f "${agent_path}" ]] || continue
  count=$((count + 1))
  agent_name="${agent_path##*/}"
  for key in $(extract_keys "${agent_path}"); do
    if [[ " ${ALLOWED_AGENT_KEYS} " != *" ${key} "* ]]; then
      printf 'agents/%s: non-portable frontmatter key "%s"\n' "${agent_name}" "${key}" >&2
      status=1
    fi
  done
done

if [[ "${status}" -ne 0 ]]; then
  printf '%s\n' "${GUIDANCE}" >&2
  exit 1
fi

printf 'agent portability OK (%s file(s))\n' "${count}"
