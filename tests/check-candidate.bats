#!/usr/bin/env bats
# Tests for check-candidate.sh against candidates built in a temporary directory, plus the live candidate.
# shellcheck disable=SC2016,SC2292 # SC2016: the single-quoted lines are literal text for the guard to judge. SC2292: bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/check-candidate.sh"
  live="${BATS_TEST_DIRNAME}/../docs/design/orchestrate-epic-v2/candidate"
  cand="${BATS_TEST_TMPDIR}/candidate"
  mkdir -p "${cand}/agents" "${cand}/playbooks"
  printf -- '---\nname: issue-worker\ndescription: >\n  A worker.\n---\n\nYou implement one Issue.\n' >"${cand}/agents/issue-worker.md"
  printf '# Router\n\nRun the loop.\n' >"${cand}/router.md"
}

# shell_block <file> <line>... appends a fenced shell block holding the lines.
shell_block() {
  local file="$1"
  shift
  {
    printf '\n```bash\n'
    printf '%s\n' "$@"
    printf '```\n'
  } >>"${file}"
}

@test "a candidate of agents and prose with allowed commands passes" {
  shell_block "${cand}/router.md" 'oe gate --lease-token "$TOKEN"' 'git fetch origin main' 'sleep 60' 'f="$(mktemp)"'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"candidate OK"* ]]
}

@test "a file named SKILL.md anywhere under the candidate fails and names it" {
  printf '# Skill\n' >"${cand}/playbooks/SKILL.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"playbooks/SKILL.md"*"SKILL.md"* ]]
}

@test "a candidate agent with a model key fails as a non-portable key" {
  printf -- '---\nname: issue-worker\nmodel: some-model\ndescription: >\n  A worker.\n---\n' >"${cand}/agents/issue-worker.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"model"* ]]
}

@test "a command outside the allow-list fails and names the file and line" {
  for line in 'git push origin main' 'git commit -m x' 'gh pr create --title x' 'gh pr merge 7' 'gh issue edit 7 --add-label x' \
    'gh api -X POST repos/o/r/issues/7/comments' 'curl https://example.com' 'rm -rf "$HOME"'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
    [[ "${output}" == *"router.md:4"* ]] || {
      echo "no location for: ${line}: ${output}"
      return 1
    }
  done
}

@test "a worker may read an Issue and its comments with gh" {
  shell_block "${cand}/agents/issue-worker.md" 'gh issue view 7 --repo o/r --json title,body --jq .body' \
    'gh api repos/o/r/issues/7/comments --paginate --jq .[].body'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
}

@test "a gh api call that writes fails even under an allowed prefix" {
  shell_block "${cand}/agents/issue-worker.md" 'gh api repos/o/r/issues/7/comments -f body=x'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"issue-worker.md"* ]]
}

@test "the body of a heredoc into oe is data and is never judged" {
  shell_block "${cand}/router.md" "oe worker report --issue 7 --lease-token t <<'REPORT'" 'git push origin main' 'REPORT'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
}

@test "the command that opens a heredoc is still judged" {
  shell_block "${cand}/router.md" "git push origin main <<'EOF'" 'text' 'EOF'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
}

@test "a report may be written to a temporary file with cat and a heredoc" {
  shell_block "${cand}/router.md" 'f="$(mktemp)"' "cat >\"\$f\" <<'REPORT'" 'git push origin main' 'REPORT' 'oe worker report --issue 7 --file "$f"'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
}

@test "cat is allowed only to write a variable-named file from a heredoc" {
  for line in 'cat /etc/passwd' 'cat "$f"' "cat >/tmp/x <<'EOF'" "cat >>\"\$f\" <<'EOF'" "cat >\"\$f\" <<'EOF' && git push"; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "a continuation line belongs to its command" {
  shell_block "${cand}/router.md" "oe worker brief --issue 7 \\" '  --lease-token t'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
}

@test "a continuation after a forbidden command does not hide it" {
  shell_block "${cand}/router.md" "git push \\" '  origin main'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
}

@test "a fenced block that is not shell is never judged" {
  printf '\n```text\ngit push origin main\n```\n\n```\ngit commit\n```\n' >>"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
}

@test "an emoji fails and Japanese text and arrows pass" {
  printf '\n日本語の本文 → 矢印 `oe` [!]\n' >>"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
  printf '\nDone ✅\n' >>"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"router.md"*"emoji"* ]]
}

@test "every violation is listed, not only the first" {
  printf '# Skill\n' >"${cand}/SKILL.md"
  printf '# Router\n' >"${cand}/router.md"
  shell_block "${cand}/router.md" 'git push origin main' 'gh pr merge 7'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"SKILL.md"* ]]
  [[ "${output}" == *"router.md:4"* ]]
  [[ "${output}" == *"router.md:5"* ]]
}

@test "a missing candidate directory is a usage error" {
  run bash "${target}" "${BATS_TEST_TMPDIR}/none"
  [ "${status}" -eq 2 ]
}

@test "the live candidate passes" {
  run bash "${target}" "${live}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"candidate OK"* ]]
}
