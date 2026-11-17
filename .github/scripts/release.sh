#!/usr/bin/env bash
# The release workflow's guards and Release notes, as docs/design/release-flow.md defines them.
# Usage: release.sh guard <tag> <previous-release-tag>
#        release.sh notes <tag> <previous-release-tag>
# Run in a checkout that holds the full history, the tags, and origin/main, with the cliff.toml to use.
# Exit: 0 every guard holds, or the notes are printed; 1 a guard failed or a command failed, with the reason on stderr; 2 bad usage.
set -uo pipefail

npx_tag='#v[0-9]+\.[0-9]+\.[0-9]+'
apm_range='#\^[0-9]+\.0\.0'
plugin=.claude-plugin/plugin.json
marketplace=.claude-plugin/marketplace.json
# The ref of the plugin's own entry is the one field besides the version a Bump commit sets; every other field stays.
# shellcheck disable=SC2016 # $n is a jq variable.
without_ref='del(.version) | del(.plugins[]? | select(.name == $n) | select(.source | type == "object") | .source.ref)'

fail() {
  echo "$*" >&2
  exit 1
}

# json_at prints the file $2 as it is at the commit $1, with the filter $3 applied and $n set to the JSON value $4, or null.
# It fails when git or jq does, so a caller that cannot read a file never counts two unreadable files as equal.
json_at() {
  git show "$1:$2" | jq -c --argjson n "${4:-null}" "$3"
}

# normalize_readme prints README.md at the commit $1 with every npx skills tag and APM range replaced by a placeholder.
normalize_readme() {
  git show "$1:README.md" | sed -E "s/${npx_tag}/#vTAG/g; s/${apm_range}/#^RANGE/g"
}

# bump_violation prints why the change from commit $1 to commit $2 is more than the version fields a Bump commit sets,
# and returns 1; it returns 0 when it is only that.
bump_violation() {
  local file name before after
  while IFS= read -r file; do
    case "${file}" in
    "${plugin}" | "${marketplace}" | README.md) ;;
    *)
      echo "The Bump commit changes ${file}, which a Bump commit may not"
      return 1
      ;;
    esac
  done < <(git diff --name-only "$1" "$2")
  before="$(json_at "$1" "${plugin}" 'del(.version)')" || {
    echo "${plugin} cannot be read"
    return 1
  }
  after="$(json_at "$2" "${plugin}" 'del(.version)')" || {
    echo "${plugin} cannot be read"
    return 1
  }
  if [[ "${before}" != "${after}" ]]; then
    echo "${plugin} changes more than the version"
    return 1
  fi
  name="$(json_at "$1" "${plugin}" '.name')" || {
    echo "${plugin} cannot be read"
    return 1
  }
  before="$(json_at "$1" "${marketplace}" "${without_ref}" "${name}")" || {
    echo "${marketplace} cannot be read"
    return 1
  }
  after="$(json_at "$2" "${marketplace}" "${without_ref}" "${name}")" || {
    echo "${marketplace} cannot be read"
    return 1
  }
  if [[ "${before}" != "${after}" ]]; then
    echo "${marketplace} changes more than the version and the entry's ref"
    return 1
  fi
  if [[ "$(normalize_readme "$1")" != "$(normalize_readme "$2")" ]]; then
    echo "README.md changes more than the npx skills tag and the APM range"
    return 1
  fi
}

guard() {
  local tag="$1" prev="$2" version major commit run prev_run found why
  [[ "${tag}" =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] || fail "${tag} is not v<major>.<minor>.<patch>"
  version="${tag#v}"
  major="${BASH_REMATCH[1]}"
  commit="$(git rev-parse --verify "refs/tags/${tag}^{commit}")" || fail "${tag} does not name a commit"

  [[ "${prev#v}" != "${version}" && "$(printf '%s\n%s\n' "${prev#v}" "${version}" | sort -V | tail -n 1)" = "${version}" ]] ||
    fail "${tag} is not above the previous release ${prev}"

  [[ "$(git rev-list --parents -n 1 "${commit}" | wc -w)" -eq 2 ]] || fail "${tag} commit must have one parent, the Run commit"
  run="${commit}^"
  git merge-base --is-ancestor "${run}" origin/main || fail "The Run commit ${run} is not reachable from origin/main"

  # A legacy release tag sits on main's first-parent line and is its own Run commit; a Bump commit's Run commit is its parent.
  prev_run="$(git rev-parse "${prev}^{commit}")"
  # grep -q would exit early and SIGPIPE rev-list, which pipefail reports as a miss.
  git rev-list --first-parent origin/main | grep -x "${prev_run}" >/dev/null || prev_run="${prev_run}^"
  git merge-base --is-ancestor "${prev_run}" "${run}" || fail "The Run commit does not descend from the previous release's Run commit ${prev_run}"

  why="$(bump_violation "${run}" "${commit}")" || fail "${why}"

  found="$(json_at "${commit}" "${plugin}" '.version')"
  [[ "${found}" = "\"${version}\"" ]] || fail "${plugin} has version ${found//\"/}, expected ${version}"
  found="$(json_at "${commit}" "${marketplace}" '.version')"
  [[ "${found}" = "\"${version}\"" ]] || fail "${marketplace} has version ${found//\"/}, expected ${version}"
  found="$(git show "${commit}:${marketplace}" | jq -r --argjson n "$(json_at "${commit}" "${plugin}" '.name')" \
    '[.plugins[]? | select(.name == $n) | .source.ref? // empty] | first // "none"')"
  [[ "${found}" = "${tag}" ]] || fail "The ${marketplace} entry has ref ${found}, expected ${tag}"

  # A README with no token gives the two loops nothing to check, so each route must name its version at least once.
  found="$(git show "${commit}:README.md" | grep -oE "${npx_tag}" | sort -u)"
  [[ -n "${found}" ]] || fail "README.md names no npx skills tag, expected #${tag}"
  [[ "${found}" = "#${tag}" ]] || fail "README.md names ${found//$'\n'/ }, expected #${tag}"
  found="$(git show "${commit}:README.md" | grep -oE "${apm_range}" | sort -u)"
  [[ -n "${found}" ]] || fail "README.md names no APM range, expected #^${major}.0.0"
  [[ "${found}" = "#^${major}.0.0" ]] || fail "README.md names ${found//$'\n'/ }, expected #^${major}.0.0"
}

# back_merge_commit succeeds for a commit that moves the plugin manifest's version and nothing else a Bump commit may not,
# which is what a Back-merge PR adds to main, whatever its subject. A merge commit is judged against its first parent.
back_merge_commit() {
  git diff --name-only "$1^1" "$1" | grep -Fx "${plugin}" >/dev/null && bump_violation "$1^1" "$1" >/dev/null
}

notes() {
  local tag="$1" prev="$2" run sha
  local -a skip=()
  run="$(git rev-parse --verify "refs/tags/${tag}^{commit}^")" || fail "${tag} does not name a commit with a parent"
  while IFS= read -r sha; do
    back_merge_commit "${sha}" && skip+=(--skip-commit "${sha}")
  done < <(git rev-list "${prev}..${run}")
  git-cliff --ignore-tags '^v[0-9]' ${skip[@]+"${skip[@]}"} "${prev}..${run}" || fail "git-cliff failed for ${prev}..${run}"
}

[[ $# -eq 3 ]] || {
  echo "Usage: release.sh guard|notes <tag> <previous-release-tag>" >&2
  exit 2
}
case "$1" in
guard) guard "$2" "$3" ;;
notes) notes "$2" "$3" ;;
*)
  echo "Usage: release.sh guard|notes <tag> <previous-release-tag>" >&2
  exit 2
  ;;
esac
