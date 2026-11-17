#!/usr/bin/env bash
# The release workflow's guards and Release notes, as docs/design/release-flow.md defines them.
# Usage: release.sh guard <tag> [<previous-release-tag>]
#        release.sh notes <tag> [<previous-release-tag>]
# Run in a checkout that holds the full history, the tags, and origin/main, with the cliff.toml to use.
# Env: MAIN_REF, the ref the Run commit must be reachable from; defaults to origin/main.
#      GIT_CLIFF, the git-cliff command; defaults to git-cliff.
# Exit: 0 every guard holds, or the notes are printed; 1 a guard failed or a command failed, with the reason on stderr; 2 bad usage.
set -uo pipefail

main_ref="${MAIN_REF:-origin/main}"
git_cliff="${GIT_CLIFF:-git-cliff}"
plugin=.claude-plugin/plugin.json
marketplace=.claude-plugin/marketplace.json

fail() {
  echo "$*" >&2
  exit 1
}

# json_at prints the file $2 as it is at the commit $1, with the filter $3 applied.
json_at() {
  git show "$1:$2" | jq -c "$3"
}

# normalize_readme prints README.md at the commit $1 with every npx skills tag and APM range replaced by a placeholder.
normalize_readme() {
  git show "$1:README.md" | sed -E 's/#v[0-9]+\.[0-9]+\.[0-9]+/#vTAG/g; s/#\^[0-9]+\.0\.0/#^RANGE/g'
}

guard() {
  local tag="$1" prev="${2:-}" version major commit run prev_run
  [[ "${tag}" =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] || fail "${tag} is not v<major>.<minor>.<patch>"
  version="${tag#v}"
  major="${BASH_REMATCH[1]}"
  commit="$(git rev-parse --verify "refs/tags/${tag}^{commit}")" || fail "${tag} does not name a commit"

  if [[ -n "${prev}" ]]; then
    [[ "$(printf '%s\n%s\n' "${prev#v}" "${version}" | sort -V | tail -n 1)" = "${version}" && "${prev#v}" != "${version}" ]] ||
      fail "${tag} is not above the previous release ${prev}"
  fi

  [[ "$(git rev-list --parents -n 1 "${commit}" | wc -w)" -eq 2 ]] || fail "${tag} commit must have one parent, the Run commit"
  run="${commit}^"
  git merge-base --is-ancestor "${run}" "${main_ref}" || fail "The Run commit ${run} is not reachable from ${main_ref}"

  if [[ -n "${prev}" ]]; then
    # A legacy release tag sits on main's first-parent line and is its own Run commit; a Bump commit's Run commit is its parent.
    if git rev-list --first-parent "${main_ref}" | grep -qx "$(git rev-parse "${prev}^{commit}")"; then
      prev_run="$(git rev-parse "${prev}^{commit}")"
    else
      prev_run="$(git rev-parse "${prev}^{commit}^")"
    fi
    git merge-base --is-ancestor "${prev_run}" "${run}" || fail "The Run commit does not descend from the previous release's Run commit ${prev_run}"
  fi

  local file
  while IFS= read -r file; do
    case "${file}" in
    "${plugin}" | "${marketplace}" | README.md) ;;
    *) fail "The Bump commit changes ${file}, which a Bump commit may not" ;;
    esac
  done < <(git diff --name-only "${run}" "${commit}")

  [[ "$(json_at "${run}" "${plugin}" 'del(.version)')" = "$(json_at "${commit}" "${plugin}" 'del(.version)')" ]] ||
    fail "${plugin} changes more than the version"
  local without_ref='del(.version) | (.plugins[]? |= (if (.source | type) == "object" then del(.source.ref) else . end))'
  [[ "$(json_at "${run}" "${marketplace}" "${without_ref}")" = "$(json_at "${commit}" "${marketplace}" "${without_ref}")" ]] ||
    fail "${marketplace} changes more than the version and the entry's ref"

  local found name
  found="$(json_at "${commit}" "${plugin}" '.version')"
  [[ "${found}" = "\"${version}\"" ]] || fail "${plugin} has version ${found//\"/}, expected ${version}"
  found="$(json_at "${commit}" "${marketplace}" '.version')"
  [[ "${found}" = "\"${version}\"" ]] || fail "${marketplace} has version ${found//\"/}, expected ${version}"
  name="$(json_at "${commit}" "${plugin}" '.name')"
  found="$(git show "${commit}:${marketplace}" | jq -r --argjson n "${name}" '[.plugins[]? | select(.name == $n) | .source.ref? // empty] | first // "none"')"
  [[ "${found}" = "${tag}" ]] || fail "The ${marketplace} entry has ref ${found}, expected ${tag}"

  [[ "$(normalize_readme "${run}")" = "$(normalize_readme "${commit}")" ]] ||
    fail "README.md changes more than the npx skills tag and the APM range"
  while IFS= read -r found; do
    [[ "${found}" = "#${tag}" ]] || fail "README.md names ${found}, expected #${tag}"
  done < <(git show "${commit}:README.md" | grep -oE '#v[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
  while IFS= read -r found; do
    [[ "${found}" = "#^${major}.0.0" ]] || fail "README.md names ${found}, expected #^${major}.0.0"
  done < <(git show "${commit}:README.md" | grep -oE '#\^[0-9]+\.0\.0' | sort -u)
}

notes() {
  local tag="$1" prev="${2:-}" run range
  run="$(git rev-parse --verify "refs/tags/${tag}^{commit}^")" || fail "${tag} does not name a commit with a parent"
  range="${run}"
  [[ -n "${prev}" ]] && range="${prev}..${run}"
  "${git_cliff}" --ignore-tags '^v[0-9]' "${range}" || fail "git-cliff failed for ${range}"
}

[[ $# -ge 2 && $# -le 3 ]] || {
  echo "Usage: release.sh guard|notes <tag> [<previous-release-tag>]" >&2
  exit 2
}
case "$1" in
guard) shift && guard "$@" ;;
notes) shift && notes "$@" ;;
*)
  echo "Usage: release.sh guard|notes <tag> [<previous-release-tag>]" >&2
  exit 2
  ;;
esac
