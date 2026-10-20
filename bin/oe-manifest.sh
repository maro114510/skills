#!/usr/bin/env bash
# Pins a published oe release in the repository manifest.
# Run it after the oe-release workflow has published the assets of an oe-v tag.
# The wrapper skills/orchestrate-epic/scripts/oe runs only bytes that this manifest pins.
#
# It downloads the four assets and takes the sha256 of each from the bytes it received.
# It cross-checks those against the SHA256SUMS of the release and resolves the commit the tag points at.
# It then rewrites the manifest locally, and writes nothing unless every check passes.
# It never commits or pushes. Commit the change on a branch and open a PR, so the manifest lands through review.
#
# Usage  oe-manifest.sh <oe-vX.Y.Z> [--manifest <file>]
# Exit   0 manifest written, 1 a check or a call failed with the manifest untouched, 2 usage error
set -euo pipefail

ASSETS=(oe_darwin_arm64 oe_darwin_amd64 oe_linux_arm64 oe_linux_amd64)
SUMS=SHA256SUMS

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
manifest="${repo_root}/skills/orchestrate-epic/scripts/oe-manifest.tsv"

fail() {
  printf 'oe-manifest: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'oe-manifest: %s\nUsage: oe-manifest.sh <oe-vX.Y.Z> [--manifest <file>]\n' "$1" >&2
  exit 2
}

tag=''
while [[ $# -gt 0 ]]; do
  case "$1" in
  --manifest)
    [[ $# -ge 2 ]] || usage "--manifest needs a file"
    manifest="$2"
    shift 2
    ;;
  -*) usage "unknown option $1" ;;
  *)
    [[ -z "${tag}" ]] || usage "more than one tag given"
    tag="$1"
    shift
    ;;
  esac
done
[[ -n "${tag}" ]] || usage "missing tag"
[[ "${tag}" =~ ^oe-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage "'${tag}' is not oe-vMAJOR.MINOR.PATCH"

# The release is read from the repository the current manifest names.
[[ -f "${manifest}" ]] || fail "manifest ${manifest} does not exist"
repo="$(awk -F '\t' '$1 == "repo" { print $2 }' "${manifest}")"
[[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "manifest ${manifest} has no valid repo line"

sha256_of() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum -- "$1")"
  else
    out="$(shasum -a 256 -- "$1")"
  fi
  printf '%s' "${out%% *}"
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

draft="$(gh release view "${tag}" --repo "${repo}" --json isDraft --jq '.isDraft')" ||
  fail "release ${tag} not found in ${repo}"
[[ "${draft}" == "false" ]] || fail "release ${tag} is a draft"

published="$(gh release view "${tag}" --repo "${repo}" --json assets --jq '.assets[].name')" ||
  fail "cannot list the assets of ${tag}"
for name in "${ASSETS[@]}" "${SUMS}"; do
  grep -qx -- "${name}" <<<"${published}" || fail "release ${tag} has no asset ${name}"
done

gh release download "${tag}" --repo "${repo}" --dir "${work}" \
  --pattern 'oe_*' --pattern "${SUMS}" >&2 || fail "cannot download the assets of ${tag}"

# SHA256SUMS comes from the workflow run that built the assets.
# A disagreement means an asset changed after the build, so nothing is pinned.
declare -a digests=()
for name in "${ASSETS[@]}"; do
  [[ -f "${work}/${name}" && ! -L "${work}/${name}" ]] || fail "download of ${name} left no file"
  got="$(sha256_of "${work}/${name}")"
  listed="$(awk -v n="${name}" '$2 == n { print $1 }' "${work}/${SUMS}")"
  [[ "${listed}" == "${got}" ]] ||
    fail "${name}: downloaded sha256 ${got} differs from the ${SUMS} entry '${listed}'. Not pinning ${tag}"
  digests+=("${got}")
done

# Resolve the commit the tag points at, through the tag object when it is annotated.
ref="$(gh api "repos/${repo}/git/ref/tags/${tag}" --jq '[.object.type, .object.sha] | @tsv')" ||
  fail "cannot resolve the tag ${tag}"
object_type="${ref%%$'\t'*}"
revision="${ref#*$'\t'}"
if [[ "${object_type}" == "tag" ]]; then
  revision="$(gh api "repos/${repo}/git/tags/${revision}" --jq '.object.sha')" ||
    fail "cannot dereference the annotated tag ${tag}"
elif [[ "${object_type}" != "commit" ]]; then
  fail "tag ${tag} points at a ${object_type}, not a commit"
fi
[[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || fail "tag ${tag} resolved to '${revision}', not a commit sha"

out="${manifest}.new.$$"
{
  printf '%s\n' \
    '# Pins the oe release that scripts/oe may run, with the sha256 of each asset.' \
    '# Written by make oe-manifest TAG=oe-vX.Y.Z after the release workflow publishes the assets.' \
    '# Lands only by reviewed PR and is never edited by hand.' \
    '# Without a tag line nothing is pinned and the wrapper refuses to run.'
  printf 'repo\t%s\n' "${repo}"
  printf 'tag\t%s\n' "${tag}"
  printf 'revision\t%s\n' "${revision}"
  for i in "${!ASSETS[@]}"; do
    printf 'asset\t%s\t%s\n' "${ASSETS[i]}" "${digests[i]}"
  done
} >"${out}"
mv -f -- "${out}" "${manifest}"

printf 'Pinned %s at %s in %s\n' "${tag}" "${revision}" "${manifest}"
printf 'Next, commit this on a branch and open a PR. The manifest lands only through review.\n'
