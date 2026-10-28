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
    "gh api repos/o/r/issues/7/comments --paginate --jq '.[].body'"
  shell_block "${cand}/agents/issue-worker.md" 'gh issue view <number> --repo <REPO> --json title,body --jq .body' \
    "gh api repos/<REPO>/issues/<number>/comments --paginate --jq '.[]|select(.author_association==\"OWNER\")|.body'"
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

@test "a variable may be set to a literal path and to nothing else" {
  shell_block "${cand}/router.md" 'f="/tmp/tmp.abc123"' "cat >\"\$f\" <<'REPORT'" 'text' 'REPORT' 'oe worker report --issue 7 --file "$f"'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
  for line in 'f="$HOME/x"' 'f="$(git push)"' 'f="`git push`"' 'f=/tmp/x' 'f="/tmp/x" git push'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
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

@test "a continuation after a forbidden command does not hide it" {
  shell_block "${cand}/router.md" "git push \\" '  origin main'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
}

@test "a gh api write flag fails in its attached form too" {
  for line in 'gh api repos/o/r/issues/7/comments -XPOST' 'gh api repos/o/r/issues/7/comments -fbody=x' 'gh api repos/o/r/issues/7/comments -Fbody=x' \
    'gh api repos/o/r/issues/7/comments --method=POST' 'gh api repos/o/r/issues/7/comments --field body=x'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "the portability check of a given directory leaves skills alone" {
  mkdir -p "${BATS_TEST_TMPDIR}/repo/tests" "${BATS_TEST_TMPDIR}/repo/skills/x"
  cp "${BATS_TEST_DIRNAME}/validate-agent-portability.sh" "${BATS_TEST_TMPDIR}/repo/tests/"
  printf 'see ~/.claude/skills\n' >"${BATS_TEST_TMPDIR}/repo/skills/x/SKILL.md"
  run bash "${BATS_TEST_TMPDIR}/repo/tests/validate-agent-portability.sh" "${cand}/agents"
  [ "${status}" -eq 0 ]
  mkdir -p "${BATS_TEST_TMPDIR}/repo/agents"
  run bash "${BATS_TEST_TMPDIR}/repo/tests/validate-agent-portability.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"~/.claude"* ]]
}

@test "a here-string does not open a heredoc that hides the lines after it" {
  printf '# Router\n' >"${cand}/router.md"
  shell_block "${cand}/router.md" 'oe note post --on 7 --key k <<<text' 'git push origin main'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"router.md:5"* ]]
}

@test "a mktemp assignment cannot carry a substitution" {
  for line in 'x="$(mktemp -p `git push`)"' 'x="$(mktemp -p $HOME)"'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "git fetch may name a plain branch and never a refspec" {
  shell_block "${cand}/router.md" 'git fetch origin main' 'git fetch origin feature/x-1' 'git fetch origin <DEFAULT_BRANCH>'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
  for line in 'git fetch origin main:main' 'git fetch origin +main:other' 'git fetch origin --force main' 'git fetch origin' 'git fetch --all' 'git fetch origin <a:b>' 'git fetch origin <lower>'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "a block labeled bash with more words is still judged" {
  printf '\n```bash title=x\ngit push origin main\n```\n' >>"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
}

@test "a process substitution or a subshell fails" {
  for line in 'oe worker brief --file <(git push)' 'oe worker brief --file >(sh)' 'oe worker brief (git push)' 'oe worker brief {git,push}'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "a gh api write flag fails when it is quoted, clustered, or attached" {
  for line in 'gh api repos/o/r/issues/7/comments "-f" "body=x"' "gh api repos/o/r/issues/7/comments '-f' 'body=x'" \
    'gh api repos/o/r/issues/7/comments -ifbody=x' 'gh api repos/o/r/issues/7/comments -Xpost' 'gh api repos/o/r/issues/7/comments "--method" POST' \
    "gh api repos/o/r/issues/7/comments --jq '.' '-f' x"; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "a quoted or commented heredoc marker does not hide the lines after it" {
  for line in 'oe note post --key "<<EOF"' 'oe note post --key k # <<EOF' "oe note post --key '<<EOF'x"; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}" 'git push origin main'
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
    [[ "${output}" == *"router.md:5"* ]] || {
      echo "git push on line 5 was not reported after: ${line}: ${output}"
      return 1
    }
  done
}

@test "a fence closed by a longer fence ends, so a later shell block is judged" {
  printf '# Router\n\n```text\nx\n````\n\n```bash\ngit push origin main\n```\n' >"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"router.md:8"* ]]
}

@test "a line with a backtick in its info string is not a fence" {
  printf '# Router\n\n```text`invalid\n\n```bash\ngit push origin main\n```\n' >"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"router.md:6"* ]]
}

@test "a tilde fence and a four-backtick fence are tracked and judged like a plain one" {
  for open in '~~~bash' '````bash'; do
    close="${open%%[a-z]*}"
    printf '# Router\n\n%s\ngit push origin main\n%s\n' "${open}" "${close}" >"${cand}/router.md"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${open}"
      return 1
    }
    [[ "${output}" == *"router.md:4"* ]]
    printf '# Router\n\n%s\noe gate --lease-token t\n%s\n' "${open}" "${close}" >"${cand}/router.md"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 0 ] || {
      echo "rejected a clean block: ${open}"
      return 1
    }
  done
}

@test "an oe line may carry only plain words, placeholders, a quoted variable, a quoted redirect, and a quoted literal" {
  shell_block "${cand}/router.md" 'oe lease acquire --pid "$PPID"' 'oe checks derive --base <DEFAULT_BRANCH> >"<CHECKS_FILE>"' \
    "oe round plan --lease-token <TOKEN> --reason 'a b; c'" 'oe worker report --issue 7 --file "$f"'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
  for line in 'oe gate $TOKEN' 'oe gate >/tmp/x' 'oe gate "a b"' 'oe gate "$f$g"' 'oe gate ~/x' 'oe gate *' 'oe gate a\ b' 'oe gate ${HOME}'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "a mktemp assignment holds only plain words inside its substitution" {
  shell_block "${cand}/router.md" 'x="$(mktemp)"' 'y="$(mktemp -p /tmp)"'
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
  for line in 'x="$(mktemp ; git push origin main)"' 'x="$(mktemp && git push)"' 'x="$(mktemp | sh)"' 'x="$(mktemp) ; (git push"' 'x="$(mktemp "a b")"'; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${line}"
      return 1
    }
  done
}

@test "a fence inside a quote or a list item fails, because the guard does not follow containers" {
  for opener in '> ```bash' '>> ```bash' '- ```bash' '* ```bash' '1. ```bash' '2) ```bash' '- > ```bash' '> - ~~~bash'; do
    printf '# Router\n\n%s\ngit push origin main\n```\n' "${opener}" >"${cand}/router.md"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${opener}"
      return 1
    }
    [[ "${output}" == *"router.md:3"* ]] || {
      echo "no location for: ${opener}: ${output}"
      return 1
    }
  done
}

@test "triple backticks in the middle of a sentence are not a container fence" {
  printf '# Router\n\nA fence is three backticks, written ``` like this, in prose.\n\nUse - and > in tables | a | b |\n' >"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
}

@test "a backslash at the end of a line fails, so a command is always one physical line" {
  for line in "oe worker brief --issue 7 \\" "git push \\" "gh api repos/o/r/issues/7/comments --met\\"; do
    printf '# Router\n' >"${cand}/router.md"
    shell_block "${cand}/router.md" "${line}" 'hod POST'
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

@test "a backslash before a blank line does not let the next command pass as an argument" {
  printf '# Router\n\n```bash\noe gate --lease-token t \\\n\ngit push origin main\n```\n' >"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"router.md:6"* ]]
}

@test "a carriage return anywhere fails the file, whether CRLF or a bare CR" {
  printf '# Router\r\n\r\n```bash\r\ngit push origin main\r\n```\r\n' >"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"router.md:1"*"carriage return"* ]]
  printf '# Router\r\r```bash\rgit push origin main\r```\r' >"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"carriage return"* ]]
  printf '# Router\n\n```bash\noe gate --lease-token t\n```\n' >"${cand}/router.md"
  run bash "${target}" "${cand}"
  [ "${status}" -eq 0 ]
}

@test "an indented fence fails wherever it is, so no indentation can open or close a block the guard misses" {
  for body in '    ```text\n\n```bash\ngit push origin main\n```\n' '\t```text\n\n```bash\ngit push origin main\n```\n' \
    '   ```bash\noe gate --lease-token t\n   ```\n' '```text\nx\n   ```\n```bash\ngit push origin main\n```\n' \
    '- item\n\n    ```bash\n    git push origin main\n    ```\n'; do
    printf '# Router\n\n%b' "${body}" >"${cand}/router.md"
    run bash "${target}" "${cand}"
    [ "${status}" -eq 1 ] || {
      echo "accepted: ${body}"
      return 1
    }
    [[ "${output}" == *"indented fence"* ]] || {
      echo "no indented-fence violation: ${body}: ${output}"
      return 1
    }
  done
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
