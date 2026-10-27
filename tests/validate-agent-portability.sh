#!/usr/bin/env bash
set -euo pipefail

ALLOWED_AGENT_KEYS='name description'
GUIDANCE='portable agents may only use: description, name'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
# Without arguments it checks the shipped agents and the candidate's; each argument names a directory of agents instead.
if [[ "$#" -gt 0 ]]; then
  agent_dirs=("$@")
else
  agent_dirs=("${repo_root}/agents" "${repo_root}/docs/design/orchestrate-epic-v2/candidate/agents")
fi

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
for agents_dir in "${agent_dirs[@]}"; do
  for agent_path in "${agents_dir}"/*.md; do
    [[ -f "${agent_path}" ]] || continue
    count=$((count + 1))
    for key in $(extract_keys "${agent_path}"); do
      if [[ " ${ALLOWED_AGENT_KEYS} " != *" ${key} "* ]]; then
        printf '%s: non-portable frontmatter key "%s"\n' "${agent_path#"${repo_root}"/}" "${key}" >&2
        status=1
      fi
    done
  done
done

if [[ "${status}" -ne 0 ]]; then
  printf '%s\n' "${GUIDANCE}" >&2
fi

# Skills must resolve their own files from the harness-provided base directory,
# not from a Claude Code-only install location.
skills_dir="${repo_root}/skills"
if [[ -d "${skills_dir}" ]]; then
  grep_status=0
  # The patterns are literal text to match, not paths to expand.
  # shellcheck disable=SC2016,SC2088
  hits="$(grep -rnF -e '~/.claude' -e '$HOME/.claude' -e '${HOME}/.claude' "${skills_dir}")" || grep_status=$?
  if [[ "${grep_status}" -eq 0 ]]; then
    printf '%s\n' "${hits}" | sed "s|^${repo_root}/||" >&2
    printf '%s\n' 'skills must not hard-code ~/.claude paths; resolve files from the skill base directory' >&2
    status=1
  elif [[ "${grep_status}" -ne 1 ]]; then
    printf 'grep failed while scanning skills/ (exit %s)\n' "${grep_status}" >&2
    status=1
  fi
fi

if [[ "${status}" -ne 0 ]]; then
  exit 1
fi

printf 'agent portability OK (%s agent file(s); skills free of ~/.claude paths)\n' "${count}"
