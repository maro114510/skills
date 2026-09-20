#!/usr/bin/env bash
set -euo pipefail

AGENT_NAMES=(issue-implementer issue-reviewer)
PORTABLE_AGENT_KEYS='name description'
OPENCODE_REJECT_MARKER='OpenCode will reject this agent'
OPENCODE_CLI='opencode'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

targets=("$@")
if [[ "${#targets[@]}" -eq 0 || "${targets[0]}" == 'all' ]]; then
  targets=(claude codex opencode)
fi

if ! command -v apm >/dev/null 2>&1; then
  printf 'apm CLI not found on PATH; install it from https://github.com/microsoft/apm\n' >&2
  exit 1
fi

work_root="$(mktemp -d)"
cleanup() { rm -rf "${work_root}"; }
trap cleanup EXIT

status=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  status=1
}

frontmatter_keys() {
  awk '
    BEGIN { infront = 0 }
    NR == 1 {
      if ($0 ~ /^---[[:space:]]*$/) infront = 1
      next
    }
    !infront { exit }
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

check_claude() {
  local project_dir="$1" name
  for name in "${AGENT_NAMES[@]}"; do
    local deployed="${project_dir}/.claude/agents/${name}.md"
    local source_file="${repo_root}/agents/${name}.md"
    if [[ ! -f "${deployed}" ]]; then
      fail "[claude] ${name}.md was not deployed under .claude/agents/"
    elif ! cmp -s "${deployed}" "${source_file}"; then
      fail "[claude] ${name}.md does not match the source agent body"
    fi
  done
}

check_codex() {
  local project_dir="$1" name
  for name in "${AGENT_NAMES[@]}"; do
    local deployed="${project_dir}/.codex/agents/${name}.toml"
    if [[ ! -s "${deployed}" ]]; then
      fail "[codex] ${name}.toml was not produced under .codex/agents/"
      continue
    fi
    if ! grep -q "^name = \"${name}\"$" "${deployed}"; then
      fail "[codex] ${name}.toml is missing a matching name field"
    fi
    if ! grep -q '^developer_instructions = ' "${deployed}"; then
      fail "[codex] ${name}.toml is missing its agent instructions"
    fi
  done
}

check_opencode() {
  local project_dir="$1" home_dir="$2" log_file="$3" name key
  for name in "${AGENT_NAMES[@]}"; do
    local deployed="${project_dir}/.opencode/agents/${name}.md"
    if [[ ! -f "${deployed}" ]]; then
      fail "[opencode] ${name}.md was not deployed under .opencode/agents/"
      continue
    fi
    while IFS= read -r key; do
      [[ -n "${key}" ]] || continue
      if [[ " ${PORTABLE_AGENT_KEYS} " != *" ${key} "* ]]; then
        fail "[opencode] ${name}.md has non-portable frontmatter key \"${key}\""
      fi
    done < <(frontmatter_keys "${deployed}")
  done

  if grep -q "${OPENCODE_REJECT_MARKER}" "${log_file}" ||
    tr '\n' ' ' <"${log_file}" | tr -s ' ' | grep -q "${OPENCODE_REJECT_MARKER}"; then
    fail "[opencode] APM reported an incompatible-frontmatter warning:"
    grep '\[!\]' "${log_file}" | sed 's/^/  /' >&2
  fi

  if ! command -v "${OPENCODE_CLI}" >/dev/null 2>&1; then
    printf '[opencode] %s CLI not found; skipping the agent-load smoke test\n' "${OPENCODE_CLI}"
    return
  fi

  local list_output
  if ! list_output="$(cd "${project_dir}" && HOME="${home_dir}" "${OPENCODE_CLI}" agent list 2>&1)"; then
    fail "[opencode] ${OPENCODE_CLI} failed to load the project agents:"
    printf '%s\n' "${list_output}" | sed 's/^/  /' >&2
    return
  fi
  for name in "${AGENT_NAMES[@]}"; do
    if ! printf '%s\n' "${list_output}" | grep -q "${name}"; then
      fail "[opencode] ${OPENCODE_CLI} agent list does not include ${name}"
    fi
  done
}

for target in "${targets[@]}"; do
  home_dir="${work_root}/${target}/home"
  project_dir="${work_root}/${target}/project"
  log_file="${work_root}/${target}/install.log"
  mkdir -p "${home_dir}" "${project_dir}"

  if ! (cd "${project_dir}" && HOME="${home_dir}" apm install "${repo_root}" -t "${target}") >"${log_file}" 2>&1; then
    fail "[${target}] apm install failed:"
    sed 's/^/  /' "${log_file}" >&2
    continue
  fi

  case "${target}" in
  claude) check_claude "${project_dir}" ;;
  codex) check_codex "${project_dir}" ;;
  opencode) check_opencode "${project_dir}" "${home_dir}" "${log_file}" ;;
  *) fail "[${target}] unknown target (expected claude, codex, or opencode)" ;;
  esac
done

if [[ "${status}" -ne 0 ]]; then
  exit 1
fi

printf 'APM portability OK (%s)\n' "${targets[*]}"
