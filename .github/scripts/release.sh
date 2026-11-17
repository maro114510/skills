#!/usr/bin/env bash
# The release workflow's guards and Release notes, as docs/design/release-flow.md defines them.
# Usage: release.sh guard <tag> <previous-release-tag>
#        release.sh notes <tag> <previous-release-tag>
# Run in a checkout that holds the full history, the tags, and origin/main, with the cliff.toml to use.
# Exit: 0 every guard holds, or the notes are printed; 1 a guard failed or a command failed, with the reason on stderr; 2 bad usage.
set -uo pipefail

plugin=.claude-plugin/plugin.json
marketplace=.claude-plugin/marketplace.json
without_ref='del(.version) | (.plugins[]? |= (if (.source | type) == "object" then del(.source.ref) else . end))'

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

# bump_violation prints why the change from commit $1 to commit $2 is more than the version fields a Bump commit sets,
# and returns 1; it returns 0 when it is only that.
bump_violation() {
  local file
  while IFS= read -r file; do
    case "${file}" in
    "${plugin}" | "${marketplace}" | README.md) ;;
    *)
      echo "The Bump commit changes ${file}, which a Bump commit may not"
      return 1
      ;;
    esac
  done < <(git diff --name-only "$1" "$2")
  if [[ "$(json_at "$1" "${plugin}" 'del(.version)')" != "$(json_at "$2" "${plugin}" 'del(.version)')" ]]; then
    echo "${plugin} changes more than the version"
    return 1
  fi
  if [[ "$(json_at "$1" "${marketplace}" "${without_ref}")" != "$(json_at "$2" "${marketplace}" "${without_ref}")" ]]; then
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
  git rev-list --first-parent origin/main | grep -qx "${prev_run}" || prev_run="${prev_run}^"
  git merge-base --is-ancestor "${prev_run}" "${run}" || fail "The Run commit does not descend from the previous release's Run commit ${prev_run}"

  why="$(bump_violation "${run}" "${commit}")" || fail "${why}"

  found="$(json_at "${commit}" "${plugin}" '.version')"
  [[ "${found}" = "\"${version}\"" ]] || fail "${plugin} has version ${found//\"/}, expected ${version}"
  found="$(json_at "${commit}" "${marketplace}" '.version')"
  [[ "${found}" = "\"${version}\"" ]] || fail "${marketplace} has version ${found//\"/}, expected ${version}"
  found="$(git show "${commit}:${marketplace}" | jq -r --argjson n "$(json_at "${commit}" "${plugin}" '.name')" \
    '[.plugins[]? | select(.name == $n) | .source.ref? // empty] | first // "none"')"
  [[ "${found}" = "${tag}" ]] || fail "The ${marketplace} entry has ref ${found}, expected ${tag}"

  while IFS= read -r found; do
    [[ "${found}" = "#${tag}" ]] || fail "README.md names ${found}, expected #${tag}"
  done < <(git show "${commit}:README.md" | grep -oE '#v[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
  while IFS= read -r found; do
    [[ "${found}" = "#^${major}.0.0" ]] || fail "README.md names ${found}, expected #^${major}.0.0"
  done < <(git show "${commit}:README.md" | grep -oE '#\^[0-9]+\.0\.0' | sort -u)
}

# notes leaves out the commits that change only the version fields, which are the Back-merge PRs' commits, whatever their subject.
notes() {
  local tag="$1" prev="$2" run sha
  local -a skip=()
  run="$(git rev-parse --verify "refs/tags/${tag}^{commit}^")" || fail "${tag} does not name a commit with a parent"
  while IFS= read -r sha; do
    [[ -n "$(git diff --name-only "${sha}^" "${sha}")" ]] && bump_violation "${sha}^" "${sha}" >/dev/null && skip+=(--skip-commit "${sha}")
  done < <(git rev-list --no-merges "${prev}..${run}")
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
