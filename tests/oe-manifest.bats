#!/usr/bin/env bats
# Tests for bin/oe-manifest.sh, which pins a published oe release in the repository manifest, and for the make target that runs it.
# A fake gh serves a local directory as the release.
# One test feeds the generated manifest to the real wrapper.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.
# shellcheck disable=SC2030,SC2031 # every @test runs in its own subshell, so exports and `run` results stay inside it by design.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  generator="${repo_root}/bin/oe-manifest.sh"
  sandbox="$(mktemp -d)"
  release="${sandbox}/release"
  fakebin="${sandbox}/bin"
  manifest="${sandbox}/oe-manifest.tsv"
  mkdir -p "${release}" "${fakebin}"

  export FAKE_RELEASE_DIR="${release}"
  export FAKE_DRAFT=false
  export FAKE_REF_TYPE=commit
  export FAKE_REF_SHA=0123456789abcdef0123456789abcdef01234567
  export FAKE_TAG_TARGET=fedcba9876543210fedcba9876543210fedcba98
  export GH_LOG="${sandbox}/gh.log"
  : >"${GH_LOG}"
  PATH="${fakebin}:${PATH}"
  tag=oe-v0.1.0

  write_gh
  publish_release
  printf '# header\nrepo\tmaro114510/skills\n' >"${manifest}"
}

teardown() {
  rm -rf "${sandbox}"
}

ASSETS='oe_darwin_arm64 oe_darwin_amd64 oe_linux_arm64 oe_linux_amd64'

write_gh() {
  cat >"${fakebin}/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "release view")
    case "$*" in
      *"--json isDraft"*) printf '%s\n' "$FAKE_DRAFT" ;;
      *"--json assets"*) ls "$FAKE_RELEASE_DIR" ;;
      *) exit 2 ;;
    esac
    ;;
  "release download")
    dir='' patterns=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dir) dir="$2"; shift ;;
        --pattern) patterns="$patterns $2"; shift ;;
      esac
      shift
    done
    for p in $patterns; do
      for f in "$FAKE_RELEASE_DIR"/$p; do cp "$f" "$dir/"; done
    done
    ;;
  "api repos/maro114510/skills/git/ref/tags/"*)
    printf '%s\t%s\n' "$FAKE_REF_TYPE" "$FAKE_REF_SHA"
    ;;
  "api repos/maro114510/skills/git/tags/"*)
    printf '%s\n' "$FAKE_TAG_TARGET"
    ;;
  *) exit 2 ;;
esac
EOF
  chmod 755 "${fakebin}/gh"
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Publishes four fake binaries and the SHA256SUMS the workflow would write.
publish_release() {
  local a
  for a in ${ASSETS}; do
    printf '#!/bin/sh\necho %s\n' "${a}" >"${release}/${a}"
  done
  rewrite_sums
}

rewrite_sums() {
  local a
  : >"${release}/SHA256SUMS"
  for a in ${ASSETS}; do
    printf '%s  %s\n' "$(sha_of "${release}/${a}")" "${a}" >>"${release}/SHA256SUMS"
  done
}

# Fails the test unless the manifest is exactly what it was before the generator ran.
manifest_untouched() {
  [ "$(cat "${manifest}")" = "$(printf '# header\nrepo\tmaro114510/skills')" ]
  [ -z "$(find "${sandbox}" -maxdepth 1 -name 'oe-manifest.tsv.new*')" ]
}

@test "pins the tag, its commit, and the sha256 of each asset" {
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 0 ]
  grep -qx "repo$(printf '\t')maro114510/skills" "${manifest}"
  grep -qx "tag$(printf '\t')${tag}" "${manifest}"
  grep -qx "revision$(printf '\t')${FAKE_REF_SHA}" "${manifest}"
  for a in ${ASSETS}; do
    grep -qx "asset$(printf '\t')${a}$(printf '\t')$(sha_of "${release}/${a}")" "${manifest}"
  done
  [ "$(grep -c '^asset' "${manifest}")" -eq 4 ]
}

@test "resolves an annotated tag to the commit it points at" {
  export FAKE_REF_TYPE=tag FAKE_REF_SHA=1111111111111111111111111111111111111111
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 0 ]
  grep -qx "revision$(printf '\t')${FAKE_TAG_TARGET}" "${manifest}"
}

@test "writes the same header the shipped manifest carries" {
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 0 ]
  shipped="${repo_root}/skills/orchestrate-epic/scripts/oe-manifest.tsv"
  [ "$(grep '^#' "${manifest}")" = "$(grep '^#' "${shipped}")" ]
}

@test "refuses when an asset no longer matches the SHA256SUMS the build published" {
  printf '#!/bin/sh\necho swapped\n' >"${release}/oe_linux_arm64"
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"oe_linux_arm64"*"differs from SHA256SUMS"* ]]
  manifest_untouched
}

@test "refuses when an asset is missing from the release" {
  rm "${release}/oe_darwin_amd64"
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"no asset oe_darwin_amd64"* ]]
  manifest_untouched
}

@test "refuses when SHA256SUMS is missing from the release" {
  rm "${release}/SHA256SUMS"
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"no asset SHA256SUMS"* ]]
  manifest_untouched
}

@test "refuses a draft release" {
  export FAKE_DRAFT=true
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 1 ]
  [[ ${output} == *"draft"* ]]
  manifest_untouched
}

@test "refuses a tag that does not point at a commit" {
  export FAKE_REF_TYPE=tree
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 1 ]
  manifest_untouched
}

@test "refuses a tag that is not an oe release version" {
  for bad in v0.1.0 oe-v1 oe-v1.0.0-rc.1 oe-v1.0.0/../x latest; do
    run "${generator}" "${bad}" --manifest "${manifest}"
    [ "${status}" -eq 2 ]
  done
  [ "$(wc -l <"${GH_LOG}" | tr -d ' ')" -eq 0 ]
  manifest_untouched
}

@test "usage errors exit 2" {
  run "${generator}"
  [ "${status}" -eq 2 ]
  run "${generator}" "${tag}" extra
  [ "${status}" -eq 2 ]
  run "${generator}" "${tag}" --bogus
  [ "${status}" -eq 2 ]
}

@test "a re-run replaces the previous pin" {
  run "${generator}" oe-v0.1.0 --manifest "${manifest}"
  [ "${status}" -eq 0 ]
  printf '#!/bin/sh\necho newer\n' >"${release}/oe_linux_amd64"
  rewrite_sums
  run "${generator}" oe-v0.2.0 --manifest "${manifest}"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^tag' "${manifest}")" -eq 1 ]
  grep -qx "tag$(printf '\t')oe-v0.2.0" "${manifest}"
  grep -qx "asset$(printf '\t')oe_linux_amd64$(printf '\t')$(sha_of "${release}/oe_linux_amd64")" "${manifest}"
}

@test "the manifest it writes is one the wrapper runs, and a tampered asset is then refused" {
  for a in ${ASSETS}; do
    printf '#!/bin/sh\necho %s\n' "${a}" >"${release}/${a}"
  done
  rewrite_sums
  run "${generator}" "${tag}" --manifest "${manifest}"
  [ "${status}" -eq 0 ]

  skill="${sandbox}/skill/scripts"
  mkdir -p "${skill}"
  cp "${repo_root}/skills/orchestrate-epic/scripts/oe" "${skill}/oe"
  cp "${manifest}" "${skill}/oe-manifest.tsv"
  # The wrapper downloads through a fake gh that copies the asset.
  cat >"${fakebin}/gh" <<'EOF'
#!/bin/sh
dir='' pattern=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift ;;
    --pattern) pattern="$2"; shift ;;
  esac
  shift
done
cp "$FAKE_RELEASE_DIR/$pattern" "$dir/$pattern"
EOF
  chmod 755 "${fakebin}/gh"
  export XDG_CACHE_HOME="${sandbox}/cache"
  uname_os="$(uname -s)"
  uname_cpu="$(uname -m)"
  case "${uname_os}-${uname_cpu}" in
  Darwin-arm64) want=oe_darwin_arm64 ;;
  Darwin-x86_64) want=oe_darwin_amd64 ;;
  Linux-aarch64 | Linux-arm64) want=oe_linux_arm64 ;;
  Linux-x86_64) want=oe_linux_amd64 ;;
  *) skip "unsupported test platform ${uname_os}-${uname_cpu}" ;;
  esac

  run "${skill}/oe"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${want}" ]

  rm -rf "${XDG_CACHE_HOME}"
  printf '#!/bin/sh\necho swapped\n' >"${release}/${want}"
  run "${skill}/oe"
  [ "${status}" -eq 8 ]
  [[ ${output} == *"does not match the manifest sha256"* ]]
}

@test "make oe-manifest runs the generator for TAG and requires one" {
  run make -C "${repo_root}" -n oe-manifest TAG=oe-v0.1.0
  [ "${status}" -eq 0 ]
  [[ ${output} == *"bin/oe-manifest.sh"*"oe-v0.1.0"* ]]
  run make -C "${repo_root}" oe-manifest
  [ "${status}" -ne 0 ]
  [[ ${output} == *"TAG"* ]]
}
