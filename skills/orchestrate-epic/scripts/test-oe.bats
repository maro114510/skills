#!/usr/bin/env bats
# Tests for the oe wrapper.
# Each case copies the wrapper next to a manifest it writes, puts a fake gh and uname on PATH, and points the cache at a temp directory.
# The fake release holds one small script per platform that records when it runs, so a test can prove an unverified binary never executed.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.
# shellcheck disable=SC2030,SC2031 # every @test runs in its own subshell, so exports and `run` results stay inside it by design.

setup() {
  real_wrapper="${BATS_TEST_DIRNAME}/oe"
  real_manifest="${BATS_TEST_DIRNAME}/oe-manifest.tsv"
  sandbox="$(mktemp -d)"
  skill="${sandbox}/skill/scripts"
  release="${sandbox}/release"
  fakebin="${sandbox}/bin"
  mkdir -p "${skill}" "${release}" "${fakebin}"
  cp "${real_wrapper}" "${skill}/oe"
  chmod 755 "${skill}/oe"

  export XDG_CACHE_HOME="${sandbox}/cache"
  export GH_LOG="${sandbox}/gh.log"
  export RAN_LOG="${sandbox}/ran.log"
  export FAKE_RELEASE_DIR="${release}"
  export FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64
  unset FAKE_GH_FAIL
  : >"${GH_LOG}"
  PATH="${fakebin}:${PATH}"

  tag=oe-v0.1.0
  revision=0123456789abcdef0123456789abcdef01234567
  write_fakes
  publish_release
  write_manifest
}

teardown() {
  rm -rf "${sandbox}"
}

write_fakes() {
  cat >"${fakebin}/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GH_LOG"
if [ -n "${FAKE_GH_FAIL:-}" ]; then
  echo "gh: network is down" >&2
  exit 1
fi
[ "$1 $2" = "release download" ] || exit 2
[ -z "${FAKE_GH_HANG:-}" ] || sleep "$FAKE_GH_HANG"
pattern='' dir=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pattern) pattern="$2"; shift ;;
    --dir) dir="$2"; shift ;;
  esac
  shift
done
cp "$FAKE_RELEASE_DIR/$pattern" "$dir/$pattern"
EOF
  cat >"${fakebin}/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) printf '%s\n' "$FAKE_UNAME_S" ;;
  -m) printf '%s\n' "$FAKE_UNAME_M" ;;
  *) exit 2 ;;
esac
EOF
  chmod 755 "${fakebin}/gh" "${fakebin}/uname"
}

ASSETS='oe_darwin_arm64 oe_darwin_amd64 oe_linux_arm64 oe_linux_amd64'

# Writes one fake binary per platform into the release.
# Each reports its own asset name, records that it ran, and exits with the status given after --exit.
publish_release() {
  local a
  for a in ${ASSETS}; do
    cat >"${release}/${a}" <<EOF
#!/bin/sh
echo "ran ${a}" >>"\$RAN_LOG"
case "\$1" in
  --version) echo "${tag}" ;;
  --exit) exit "\$2" ;;
  *) echo "asset=${a}"; printf 'arg=%s\n' "\$@" ;;
esac
EOF
  done
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Writes the manifest for the fake release as it stands now.
write_manifest() {
  local a
  {
    printf 'repo\tmaro114510/skills\n'
    printf 'tag\t%s\n' "${tag}"
    printf 'revision\t%s\n' "${revision}"
    for a in ${ASSETS}; do
      printf 'asset\t%s\t%s\n' "${a}" "$(sha_of "${release}/${a}")"
    done
  } >"${skill}/oe-manifest.tsv"
}

# Stands in for a swapped binary and records "ran <label>" if it ever runs.
tampered() { printf '#!/bin/sh\necho "ran %s" >>"%s"\n' "$1" "${RAN_LOG}"; }
cached() { printf '%s/oe/%s/%s' "${XDG_CACHE_HOME}" "${tag}" "$1"; }
gh_calls() { wc -l <"${GH_LOG}" | tr -d ' '; }
ran_count() { if [ -f "${RAN_LOG}" ]; then wc -l <"${RAN_LOG}" | tr -d ' '; else echo 0; fi; }

@test "an empty cache downloads, verifies, installs, and runs oe" {
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tag}" ]
  [ "$(gh_calls)" -eq 1 ]
  # The download goes to a staging directory beside the final path, so the install is one atomic rename.
  grep -q -- "^release download ${tag} --repo maro114510/skills --pattern oe_linux_amd64 --dir ${XDG_CACHE_HOME}/oe/${tag}/\.download\." "${GH_LOG}"
  [ -x "$(cached oe_linux_amd64)" ]
}

@test "a populated cache runs offline without calling gh" {
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  calls="$(gh_calls)"
  export FAKE_GH_FAIL=1
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tag}" ]
  [ "$(gh_calls)" -eq "${calls}" ]
}

@test "a populated cache runs with gh missing from PATH" {
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  rm "${fakebin}/gh"
  PATH="${fakebin}:/usr/bin:/bin"
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tag}" ]
}

@test "oe's own exit code and arguments pass through" {
  run "${skill}/oe" --exit 7
  [ "${status}" -eq 7 ]
  run "${skill}/oe" resolve --epic 3
  [ "${status}" -eq 0 ]
  [[ ${output} == *"arg=resolve"* ]]
  [[ ${output} == *"arg=--epic"* ]]
  [[ ${output} == *"arg=3"* ]]
}

@test "a tampered Release asset is refused, never executed, and never cached" {
  tampered tampered >"${release}/oe_linux_amd64"
  run "${skill}/oe" --version
  [ "${status}" -eq 8 ]
  [[ ${output} == *"refused: oe wrapper: "* ]]
  [[ ${output} == *"does not match the manifest sha256"* ]]
  [ "$(ran_count)" -eq 0 ]
  [ ! -e "$(cached oe_linux_amd64)" ]
  [ -z "$(find "${XDG_CACHE_HOME}" -name '.download.*' 2>/dev/null)" ]
}

@test "a manifest checksum that does not match the asset is refused" {
  sed -i.bak "s/^\(asset.oe_linux_amd64.\).*/\1$(printf '0%.0s' $(seq 64))/" "${skill}/oe-manifest.tsv"
  run "${skill}/oe" --version
  [ "${status}" -eq 8 ]
  [[ ${output} == *"does not match the manifest sha256"* ]]
  [ "$(ran_count)" -eq 0 ]
  [ ! -e "$(cached oe_linux_amd64)" ]
}

@test "a tampered cached binary is refused while offline" {
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  tampered tampered >"$(cached oe_linux_amd64)"
  chmod 755 "$(cached oe_linux_amd64)"
  before="$(ran_count)"
  export FAKE_GH_FAIL=1
  run "${skill}/oe" --version
  [ "${status}" -ne 0 ]
  [ "${status}" -eq 1 ]
  [ "$(ran_count)" -eq "${before}" ]
  if grep -q tampered "${RAN_LOG}"; then false; fi
  [ ! -e "$(cached oe_linux_amd64)" ]
}

@test "a tampered cached binary is replaced from the Release when gh can reach it" {
  run "${skill}/oe" --version
  tampered tampered >"$(cached oe_linux_amd64)"
  chmod 755 "$(cached oe_linux_amd64)"
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  [[ ${output} == *"replacing it"* ]]
  [[ ${output} == *"${tag}" ]]
  if grep -q tampered "${RAN_LOG}"; then false; fi
  [ "$(sha_of "$(cached oe_linux_amd64)")" = "$(sha_of "${release}/oe_linux_amd64")" ]
}

@test "a truncated cached binary is replaced, not executed" {
  run "${skill}/oe" --version
  : >"$(cached oe_linux_amd64)"
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  [ "$(sha_of "$(cached oe_linux_amd64)")" = "$(sha_of "${release}/oe_linux_amd64")" ]
}

@test "a symlink in place of the cached binary is replaced, not followed" {
  run "${skill}/oe" --version
  tampered elsewhere >"${sandbox}/elsewhere"
  chmod 755 "${sandbox}/elsewhere"
  cp "${release}/oe_linux_amd64" "${sandbox}/good"
  rm "$(cached oe_linux_amd64)"
  ln -s "${sandbox}/good" "$(cached oe_linux_amd64)"
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  [ ! -L "$(cached oe_linux_amd64)" ]
}

@test "an interrupted download leaves no staging directory behind" {
  export FAKE_GH_HANG=2
  "${skill}/oe" --version >/dev/null 2>&1 &
  pid=$!
  # Interrupt the wrapper once gh has been called, so the staging directory exists.
  for _ in $(seq 50); do
    [ "$(gh_calls)" -ge 1 ] && break
    sleep 0.1
  done
  [ "$(gh_calls)" -ge 1 ]
  kill -TERM "${pid}"
  wait "${pid}" || true
  [ -z "$(find "${XDG_CACHE_HOME}" -name '.download.*')" ]
  [ ! -e "$(cached oe_linux_amd64)" ]
  [ "$(ran_count)" -eq 0 ]
}

@test "a failed download executes nothing and exits 1" {
  export FAKE_GH_FAIL=1
  run "${skill}/oe" --version
  [ "${status}" -eq 1 ]
  [[ ${output} == *"unreadable: oe wrapper: "* ]]
  [ "$(ran_count)" -eq 0 ]
}

@test "a download that leaves no file is not executed" {
  rm "${release}/oe_linux_amd64"
  run "${skill}/oe" --version
  [ "${status}" -ne 0 ]
  [ "$(ran_count)" -eq 0 ]
}

@test "each supported platform selects its own asset" {
  while read -r uname_s uname_m want; do
    rm -rf "${XDG_CACHE_HOME}"
    FAKE_UNAME_S="${uname_s}" FAKE_UNAME_M="${uname_m}" run "${skill}/oe" noop
    [ "${status}" -eq 0 ]
    [[ ${output} == *"asset=${want}"* ]]
  done <<'EOF'
Darwin arm64 oe_darwin_arm64
Darwin x86_64 oe_darwin_amd64
Linux aarch64 oe_linux_arm64
Linux arm64 oe_linux_arm64
Linux x86_64 oe_linux_amd64
Linux amd64 oe_linux_amd64
EOF
}

@test "an unsupported OS or CPU is refused without calling gh" {
  FAKE_UNAME_S=FreeBSD run "${skill}/oe" --version
  [ "${status}" -eq 8 ]
  [[ ${output} == *"unsupported OS"* ]]
  FAKE_UNAME_M=riscv64 run "${skill}/oe" --version
  [ "${status}" -eq 8 ]
  [[ ${output} == *"unsupported CPU"* ]]
  [ "$(gh_calls)" -eq 0 ]
}

@test "a manifest that pins nothing is refused without calling gh" {
  printf '# nothing yet\nrepo\tmaro114510/skills\n' >"${skill}/oe-manifest.tsv"
  run "${skill}/oe" --version
  [ "${status}" -eq 8 ]
  [[ ${output} == *"no oe release is pinned yet"* ]]
  [[ ${output} == *"make oe-manifest"* ]]
  [ "$(gh_calls)" -eq 0 ]
  [ "$(ran_count)" -eq 0 ]
}

@test "a missing manifest is refused" {
  rm "${skill}/oe-manifest.tsv"
  run "${skill}/oe" --version
  [ "${status}" -eq 8 ]
  [ "$(gh_calls)" -eq 0 ]
}

# Takes a description of the break just made to the manifest.
# The wrapper must refuse it before calling gh or running anything.
expect_refused() {
  run "${skill}/oe" --version
  [ "${status}" -eq 8 ] || {
    echo "$1: status ${status}: ${output}"
    return 1
  }
  [ "$(gh_calls)" -eq 0 ] || {
    echo "$1: called gh"
    return 1
  }
  [ "$(ran_count)" -eq 0 ] || {
    echo "$1: ran a binary"
    return 1
  }
}

@test "malformed manifests are refused without calling gh" {
  manifest="${skill}/oe-manifest.tsv"
  zeros="$(printf '0%.0s' $(seq 64))"

  sed -i.bak 's/^\(asset.oe_linux_amd64.\)[0-9a-f]\{4\}/\1/' "${manifest}"
  expect_refused "short sha256"
  write_manifest
  sed -i.bak '/oe_linux_amd64/s/[0-9a-f]\{64\}$/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' "${manifest}"
  expect_refused "upper-case sha256"
  write_manifest
  sed -i.bak 's/^tag.*/tag\tv0.1.0/' "${manifest}"
  expect_refused "bad tag"
  write_manifest
  sed -i.bak 's/^revision.*/revision\tabc123/' "${manifest}"
  expect_refused "bad revision"
  write_manifest
  printf 'extra\tfield\n' >>"${manifest}"
  expect_refused "unknown record"
  write_manifest
  printf 'asset\toe_linux_amd64\t%s\n' "${zeros}" >>"${manifest}"
  expect_refused "duplicate asset"
  write_manifest
  sed -i.bak 's/^asset\toe_linux_amd64/asset\toe_windows_amd64/' "${manifest}"
  expect_refused "unknown asset"
  write_manifest
  sed -i.bak '/oe_darwin_arm64/d' "${manifest}"
  expect_refused "missing asset"
  write_manifest
  sed -i.bak 's/^tag\t.*/&\tjunk/' "${manifest}"
  expect_refused "extra field"
  write_manifest
  sed -i.bak '/^revision/d' "${manifest}"
  expect_refused "missing revision"
  write_manifest
  printf 'tag\toe-v0.1.1\n' >>"${manifest}"
  expect_refused "repeated tag"
}

@test "the wrapper resolves its manifest through a symlink and from any directory" {
  mkdir "${sandbox}/elsewhere"
  ln -s "${skill}/oe" "${sandbox}/elsewhere/oe"
  cd "${sandbox}/elsewhere/.." || return 1
  run "${sandbox}/elsewhere/oe" --version
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tag}" ]
  cd "${skill}" || return 1
  run bash oe --version
  [ "${status}" -eq 0 ]
  run ./oe --version
  [ "${status}" -eq 0 ]
}

@test "a relative symlink to the wrapper resolves too" {
  mkdir "${sandbox}/skill/links"
  ln -s ../scripts/oe "${sandbox}/skill/links/oe"
  run "${sandbox}/skill/links/oe" --version
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tag}" ]
}

@test "the cache falls back to HOME/.cache when XDG_CACHE_HOME is unset" {
  unset XDG_CACHE_HOME
  export HOME="${sandbox}/home"
  mkdir "${HOME}"
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  [ -x "${HOME}/.cache/oe/${tag}/oe_linux_amd64" ]
}

@test "the cache directory is private to the user" {
  run "${skill}/oe" --version
  [ "${status}" -eq 0 ]
  perms="$(stat -c %a "${XDG_CACHE_HOME}/oe/${tag}" 2>/dev/null || stat -f %Lp "${XDG_CACHE_HOME}/oe/${tag}")"
  [ "${perms}" = "700" ]
}

@test "the repository manifest and wrapper are shipped and well formed" {
  [ -x "${real_wrapper}" ]
  [ -f "${real_manifest}" ]
  # gh fails here and the cache is empty, so only a download failure or an unpinned manifest is acceptable.
  # Any other refusal means the manifest itself is unusable.
  cp "${real_manifest}" "${skill}/oe-manifest.tsv"
  export FAKE_GH_FAIL=1
  run "${skill}/oe" --version
  [ "${status}" -eq 1 ] || [[ ${output} == *"no oe release is pinned yet"* ]]
  [ "$(ran_count)" -eq 0 ]
  if [[ ${output} == *"malformed"* || ${output} == *"unknown"* || ${output} == *"does not pin"* || ${output} == *"missing"* ]]; then false; fi
}
