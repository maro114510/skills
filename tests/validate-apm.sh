#!/usr/bin/env bash
set -euo pipefail

AGENT_NAMES=(pr-owner pr-verify)
PORTABLE_AGENT_KEYS='name description mode'
# OpenCode V2 makes an agent without a mode a primary agent, which its subagent tool refuses to start.
OPENCODE_AGENT_MODE='subagent'
OPENCODE_REJECT_MARKER='OpenCode will reject this agent'
OPENCODE_CLI='opencode'
# Skills that must run only when a user names them.
CODEX_EXPLICIT_SKILLS=(orchestrate-epic pr-owner pr-verify)

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

# Succeeds when the frontmatter of file $1 sets top-level key $2 to the plain value $3.
frontmatter_has() {
  awk -v want_key="$2" -v want_value="$3" '
    BEGIN { infront = 0; found = 0 }
    NR == 1 {
      if ($0 ~ /^---[[:space:]]*$/) infront = 1
      next
    }
    !infront { exit }
    /^---[[:space:]]*$/ { exit }
    {
      line = $0
      sub(/[[:space:]]+$/, "", line)
      if (line == want_key ": " want_value) found = 1
    }
    END { exit found ? 0 : 1 }
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

  # Codex ignores disable-model-invocation, so only agents/openai.yaml keeps these skills from
  # starting on their own; orchestrate-epic pushes branches, and invoking it is the consent.
  local skill policy
  for skill in "${CODEX_EXPLICIT_SKILLS[@]}"; do
    policy="${project_dir}/.agents/skills/${skill}/agents/openai.yaml"
    if [[ ! -f "${policy}" ]]; then
      fail "[codex] ${skill} has no agents/openai.yaml, so Codex may invoke it implicitly"
    elif ! grep -q '^policy:[[:space:]]*$' "${policy}" ||
      ! grep -Eq '^[[:space:]]+allow_implicit_invocation:[[:space:]]*false[[:space:]]*$' "${policy}"; then
      fail "[codex] ${skill}/agents/openai.yaml does not set policy.allow_implicit_invocation: false"
    fi
  done
}

check_opencode() {
  local project_dir="$1" home_dir="$2" log_file="$3" name key
  # OpenCode V2 resolves a project's `.opencode/agents/` only inside a Git worktree, and the temp
  # consumer project is a bare directory, so the agent-load probe below would see no project agents.
  git init -q "${project_dir}"
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
    if ! frontmatter_has "${deployed}" mode "${OPENCODE_AGENT_MODE}"; then
      fail "[opencode] ${name}.md does not declare mode: ${OPENCODE_AGENT_MODE}, so OpenCode V2 cannot start it as a subagent"
    fi
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

  local list_file="${project_dir}/../agent-list.log" missing_agent=0
  # `agent list` is OpenCode V1; V2 rejects it before reading any config. V2's replacement,
  # `debug agents`, lists a project's agents only once the shared service has indexed that project,
  # and a freshly created project legitimately yields an empty list, so an empty V2 listing is
  # inconclusive rather than a failure. V2 also starts its own managed service when HOME is
  # overridden, which fails while another service holds the fixed port, so it keeps the caller's HOME.
  local cli_version cli_major
  cli_version="$("${OPENCODE_CLI}" --version 2>&1 || true)"
  cli_major="$(printf '%s\n' "${cli_version}" | grep -oE '[0-9]+\.[0-9]+' | head -n1 | cut -d. -f1)"
  if [[ "${cli_major:-0}" -ge 2 ]]; then
    # The service reports built-in agents before it has indexed the project, so retry until the
    # expected project agents appear rather than until the listing is merely non-empty.
    local attempt missing
    for attempt in 1 2 3 4 5; do
      if ! (cd "${project_dir}" && "${OPENCODE_CLI}" debug agents) >"${list_file}" 2>&1; then
        fail "[opencode] ${OPENCODE_CLI} failed to list agents:"
        sed 's/^/  /' "${list_file}" >&2
        return
      fi
      missing=0
      for name in "${AGENT_NAMES[@]}"; do
        if ! grep -q "${name}" "${list_file}"; then
          missing=1
        fi
      done
      if [[ "${missing}" -eq 0 ]]; then
        break
      fi
      sleep 1
    done
    if ! grep -q '"id"' "${list_file}"; then
      printf '[opencode] %s (%s) listed no agents after %s attempts; skipping the agent-load smoke test\n' \
        "${OPENCODE_CLI}" "${cli_version}" "${attempt}"
      return
    fi
  elif ! (cd "${project_dir}" && HOME="${home_dir}" "${OPENCODE_CLI}" agent list) >"${list_file}" 2>&1; then
    fail "[opencode] ${OPENCODE_CLI} failed to load the project agents:"
    sed 's/^/  /' "${list_file}" >&2
    return
  fi
  for name in "${AGENT_NAMES[@]}"; do
    if ! grep -q "${name}" "${list_file}"; then
      fail "[opencode] ${OPENCODE_CLI} does not list the agent ${name}"
      missing_agent=1
    fi
  done
  if [[ "${missing_agent}" -ne 0 ]]; then
    printf '[opencode] agent list output: %s bytes\n' "$(wc -c <"${list_file}" | tr -d '[:space:]')" >&2
    printf '[opencode] Listed agent names:\n' >&2
    # V1 prints one unindented `name (permissions)` header per agent; V2 prints pretty JSON ids.
    if grep -q '"id"' "${list_file}"; then
      sed -n 's/.*"id": *"\([^"]*\)".*/  \1/p' "${list_file}" >&2
    elif ! grep -E '^[^[:space:]]+ \(' "${list_file}" >&2; then
      printf '  (no agent name lines)\n' >&2
    fi
    printf '[opencode] Deployed .opencode/agents/ files:\n' >&2
    ls -laR "${project_dir}/.opencode/agents/" >&2 || true
    printf '[opencode] APM install log:\n' >&2
    sed 's/^/  /' "${log_file}" >&2
  fi
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
