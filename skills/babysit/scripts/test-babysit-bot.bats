#!/usr/bin/env bats
# Tests for the Bot identity in babysit: the drive worktree carries it, and a drive that
# cannot act as the Bot refuses before it starts anything.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  script_dir="${BATS_TEST_DIRNAME}"
  tmp="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
  export GIT_CONFIG_GLOBAL="${tmp}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name owner
  git config --global user.email owner@example.com
  git config --global init.defaultBranch main
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = api ] || exit 1
printf '123
'
EOF
  cat >"${tmp}/bin/bot-helper" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = token ] || exit 1
printf 'ghs_test_token\n'
EOF
  chmod +x "${tmp}/bin/gh" "${tmp}/bin/bot-helper"
  export PATH="${tmp}/bin:${PATH}"

  git init -q --bare "${tmp}/origin.git"
  git clone -q "${tmp}/origin.git" "${tmp}/seed"
  git -C "${tmp}/seed" commit -q --allow-empty -m base
  git -C "${tmp}/seed" push -q origin main
  git -C "${tmp}/seed" switch -q -c feat/x
  echo work >"${tmp}/seed/work"
  git -C "${tmp}/seed" add work
  git -C "${tmp}/seed" commit -q -m work
  git -C "${tmp}/seed" push -q origin feat/x
  head="$(git -C "${tmp}/seed" rev-parse HEAD)"

  git clone -q "${tmp}/origin.git" "${tmp}/clone"
  cd "${tmp}/clone" || return 1
  # The fetch stays on the local transport while the push target reads as the HTTPS GitHub one a
  # Bot worktree requires, which is what pushInsteadOf rewrites.
  git remote set-url origin "file://${tmp}/origin.git"
  git config "url.https://github.com/maro/x.git.pushInsteadOf" "file://${tmp}/origin.git"
}

opt_in() {
  git config skills.bot 'maronium[bot]'
}

@test "worktree.sh prepare gives the drive worktree the Bot identity" {
  opt_in
  git config --global skills.bot.helper bot-helper

  run bash "${script_dir}/ledger.sh" start maro/x 7 token-1
  [ "${status}" -eq 0 ]

  run bash "${script_dir}/worktree.sh" prepare maro/x 7 --session token-1 --branch feat/x --head "${head}"
  [ "${status}" -eq 0 ]
  wt="$(jq -r .path <<<"${output}")"
  [ "$(git -C "${wt}" config user.name)" = "maronium[bot]" ]
  [ "$(git -C "${wt}" config user.email)" = "123+maronium[bot]@users.noreply.github.com" ]
  [ "$(git -C "${wt}" config --get skills.bot.identity)" = "maronium" ]
  [ "$(git -C "${wt}" config --get-all credential.https://github.com.helper | tail -n3 | tr '\n' ' ')" = " !bot-helper !f() { echo quit=true; }; f " ]
  [ "$(git config user.name)" = "owner" ]
}

@test "prepare clears the identity when the clone no longer opts in" {
  opt_in
  git config --global skills.bot.helper bot-helper
  run bash "${script_dir}/ledger.sh" start maro/x 7 token-1
  [ "${status}" -eq 0 ]
  run bash "${script_dir}/worktree.sh" prepare maro/x 7 --session token-1 --branch feat/x --head "${head}"
  [ "${status}" -eq 0 ]
  wt="$(jq -r .path <<<"${output}")"
  [ "$(git -C "${wt}" config user.name)" = "maronium[bot]" ]

  git config --unset skills.bot
  run bash "${script_dir}/worktree.sh" prepare maro/x 7 --session token-1 --branch feat/x --head "${head}"
  [ "${status}" -eq 0 ]
  [ "$(git -C "${wt}" config user.name)" = "owner" ]
  [ -z "$(git -C "${wt}" config --get skills.bot.identity)" ]
}

@test "drive.sh refuses to start when the clone opts in but the Bot helper is unset" {
  opt_in
  git config skills.babysit.agent "touch ${tmp}/agent-ran"
  cat >"${tmp}/pr-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"viewer":"owner","author":"owner","isCrossRepository":false,"state":"OPEN","automationOwner":null}'
EOF
  chmod +x "${tmp}/pr-state.sh"
  export BABYSIT_PR_STATE="${tmp}/pr-state.sh"
  git config --global --unset skills.bot.helper || true

  run bash "${script_dir}/drive.sh" maro/x 7
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"skills.bot.helper"* ]]
  [ ! -e "${tmp}/agent-ran" ]
}
