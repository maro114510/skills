#!/usr/bin/env bash
# Deterministic scanner for ja-style-check.
#
# Read-only by design. It never edits a file: it emits candidates as JSON and
# the agent applies every change through Edit. An earlier version could join
# wrapped lines itself, and that single write path was the source of the only
# defects that damaged user documents — joining ordinary 26-character lines
# because this awk's length() counts bytes, and replacing the target's mode
# with the temp file's. Neither is worth a fix the agent can make just as well.
#
# Semantic style issues are candidates for agent judgment, not verdicts. The
# scanner does not decide whether a line is Japanese prose or English prose
# quoting Japanese; rubric.md Check #8 is the agent's job.
#
# Uses only shell, awk, and git.

set -euo pipefail

files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
  --fix)
    # Accepted so existing invocations keep working. The scanner no longer
    # writes; fix-policy.md tells the agent to apply the joins itself.
    printf 'scan.sh: --fix is accepted but ignored; the scanner is read-only\n' >&2
    shift
    ;;
  -h | --help)
    cat <<'USAGE'
Usage: scan.sh [file...]

Emits JSON with deterministic Japanese style candidates. Never edits a file.
--fix is accepted and ignored.
USAGE
    exit 0
    ;;
  *)
    files+=("$1")
    shift
    ;;
  esac
done

if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r line; do
    status="${line:0:2}"
    path="${line:3}"
    if [[ "${path}" == *" -> "* ]]; then
      path="${path##* -> }"
    fi
    [[ "${status}" == *D* ]] && continue
    [[ -n "${path}" ]] && files+=("${path}")
  done < <(git status --short -- '*.md' 2>/dev/null || true)
fi

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "${s}"
}

print_issue_json() {
  local issue=$1
  local rule severity path line quote reason suggestion auto
  IFS=$'\t' read -r rule severity path line quote reason suggestion auto <<<"${issue}"
  printf '{'
  printf '"rule":"%s",' "$(json_escape "${rule}")"
  printf '"severity":"%s",' "$(json_escape "${severity}")"
  printf '"path":"%s",' "$(json_escape "${path}")"
  printf '"line":%s,' "${line}"
  printf '"quote":"%s",' "$(json_escape "${quote}")"
  printf '"reason":"%s",' "$(json_escape "${reason}")"
  printf '"suggestion":"%s",' "$(json_escape "${suggestion}")"
  printf '"auto_fixable":%s' "${auto}"
  printf '}'
}

scan_file() {
  local file=$1
  local issues_file=$2

  awk -v path="${file}" -v issues="${issues_file}" '
    function has_japanese(s) {
      return s ~ /[ぁ-んァ-ヶ一-龠]/
    }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function is_structural(s, in_code, stripped) {
      stripped = trim(s)
      if (in_code || stripped == "") return 1
      if (stripped ~ /^```/) return 1
      if (stripped ~ /^(#|\||- |\* |> )/) return 1
      if (stripped ~ /^[0-9]+\.[[:space:]]/) return 1
      if (stripped ~ /https?:\/\//) return 1
      return 0
    }
    # Kept as two tests on purpose. A character class holding multibyte
    # characters is read as a set of BYTES by a byte-oriented awk such as
    # mawk, so an anchored [。] also matches any character whose final byte
    # happens to be 0x82 — every Japanese line ending in あ, for one. An
    # alternation of whole literals means the same thing to both awks.
    function ends_sentence(s) {
      if (s ~ /[!?)\]`.;:]$/) return 1
      if (s ~ /(。|！|？|」|』|）|；)$/) return 1
      return 0
    }
    # Character count for the 78-82 threshold rubric.md Check #5 documents.
    # Three awks are in play and they disagree: macOS onetrue awk and mawk
    # count bytes, so length() reports 3 for one Japanese character, while
    # gawk in a UTF-8 locale counts characters. Assuming either one alone
    # puts the threshold off by a factor of three, so detect which it is.
    function char_len(s,   copy, ascii) {
      if (counts_chars) return length(s)
      copy = s
      ascii = gsub(/[ -~]/, "", copy)
      return ascii + (length(s) - ascii) / 3
    }
    function emit(rule, severity, line, quote, reason, suggestion, auto) {
      # The record is tab separated, and both quote and path carry outside
      # data, so a tab in either would shift every later field and break the
      # JSON.
      gsub(/\t/, " ", quote)
      gsub(/\t/, " ", path)
      printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", rule, severity, path, line, quote, reason, suggestion, auto >> issues
    }
    function weak_term(s) {
      return s ~ /(適切に|適切な|必要に応じて|十分に|基本的に|可能なら|考慮する|担保する|いい感じに|ある程度|なるべく)/
    }
    function meta_phrase(s) {
      return s ~ /(まず|以下に|本節では|このドキュメントでは|説明します|示します|述べます|以上を踏まえると|これをまとめると|つまり|前述した通り|後述するように)/
    }
    function passive_phrase(s) {
      return s ~ /(される|されます|られる|行われる|行われます|求められます|必要です|判断される)/
    }
    function implementation_term(s) {
      return s ~ /(処理|実行|取得|更新|削除|登録|設定|呼び出|返す|戻り値|引数|変数|関数|配列|ループ|分岐|条件|判定|例外|エラー|フラグ|ステータス|true|false|null|nil|undefined|if|else|for|while|switch|case|かつ)/
    }
    function identifier(s) {
      return s ~ /`[^`]+`|[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*|[a-z]+[A-Z][A-Za-z0-9]*|[a-z]+_[a-z0-9_]+|[A-Z]{1,4}-[0-9]+|§[[:space:]]*[0-9]+(\.[0-9]+)*/
    }
    function raw_reference(s) {
      if (s ~ /(PR|Issue|issue)[[:space:]]*#?[0-9]+/) return 1
      if (s ~ /#[0-9]+/) return 1
      if (s ~ /[A-Z][A-Z0-9]+-[0-9]+/) return 1
      if (s ~ /`[0-9a-f]{7,40}`/) return 1
      return 0
    }
    function assignment_notation(s) {
      if (s ~ /[A-Za-z_][A-Za-z0-9_]* *= *[A-Za-z][A-Za-z0-9_]*/) return 1
      if (s ~ /`[^`]+`[[:space:]]*(が|を|は|に)[[:space:]]*(true|false|active|inactive|enabled|disabled|null|nil)/) return 1
      return 0
    }
    function notation_issue(s) {
      return s ~ /(——|──|―|—|非常に|極めて|不可欠|核心的|多角的|包括的|深掘り|掘り下げ|正面から)/
    }
    function sentence_count(s, copy) {
      copy = s
      return gsub(/。/, "", copy)
    }
    BEGIN {
      counts_chars = (length("あ") == 1)
    }
    {
      line[NR] = $0
    }
    END {
      frontmatter_end = 0
      if (NR >= 1 && trim(line[1]) == "---") {
        for (i = 2; i <= NR; i++) {
          if (trim(line[i]) == "---") {
            frontmatter_end = i
            break
          }
        }
      }

      # Line joins are candidates only. The agent applies them, and can add
      # the separator that a Latin-to-Latin join needs and a Japanese one
      # must not have.
      fenced = 0
      for (i = 1; i < NR; i++) {
        if (i <= frontmatter_end || i + 1 <= frontmatter_end) continue
        current = trim(line[i])
        next_line = trim(line[i + 1])
        if (current ~ /^```/) {
          fenced = !fenced
          continue
        }
        if (is_structural(line[i], fenced) || is_structural(line[i + 1], fenced)) continue
        if (!has_japanese(current next_line)) continue
        cur_len = char_len(current)
        mechanical = (cur_len >= 78 && cur_len <= 82 && !ends_sentence(current))
        mid_sentence = !ends_sentence(current)
        if (!(mechanical || mid_sentence)) continue
        if (cur_len + char_len(next_line) > 200) continue
        rule = mechanical ? "mechanical-wrap" : "line-break"
        emit(rule, "low", i, current, "Sentence appears to continue across a line break.", "Join this line with the following line. Insert a space only if both sides end and begin with Latin script.", mechanical ? "true" : "false")
      }

      in_code = 0
      paragraph_parens = 0
      paragraph_start = frontmatter_end + 1
      paragraph_text = ""
      for (i = 1; i <= NR; i++) {
        if (i <= frontmatter_end) continue
        current = trim(line[i])
        if (current ~ /^```/) {
          in_code = !in_code
          continue
        }
        if (is_structural(line[i], in_code)) {
          if (paragraph_parens >= 2) {
            emit("brackets", "high", paragraph_start, "paragraph", "Parenthetical supplements appear repeatedly in one paragraph.", "Keep only a first-use definition; rewrite every other supplement into the sentence or remove it.", "false")
          }
          if (sentence_count(paragraph_text) >= 6) {
            emit("paragraph-rhythm", "medium", paragraph_start, "paragraph", "A paragraph contains many Japanese sentence endings without a blank-line break.", "Judge whether to split the paragraph or use bullets for conditions, steps, criteria, scope, or consequences.", "false")
          }
          paragraph_parens = 0
          paragraph_start = i + 1
          paragraph_text = ""
          continue
        }
        if (!has_japanese(current)) continue

        paragraph_text = paragraph_text current
        paren_source = current
        parens = gsub(/（|\(/, "", paren_source)
        paragraph_parens += parens
        if (parens > 0) {
          emit("brackets", "high", i, trim(line[i]), "A parenthetical supplement holds information that belongs in the sentence.", "Keep it only if the bracket is a first-use definition; otherwise rewrite it into the sentence or remove it. Clear it when the parenthesis is Markdown syntax such as a link target.", "false")
        }
        if (raw_reference(current)) {
          emit("first-use-definition", "medium", i, trim(line[i]), "A PR number, issue number, ticket ID, commit hash, or similar reference may be unclear on first read.", "Allow it only when nearby prose explains what the reference means without opening it.", "false")
        }
        if (weak_term(current)) {
          emit("vague-claim", "medium", i, trim(line[i]), "A vague term lacks a concrete condition or threshold.", "State the condition, scope, threshold, or effect.", "false")
        }
        if (meta_phrase(current)) {
          emit("meta-prose", "low", i, trim(line[i]), "Meta prose may announce the text instead of adding content.", "Delete it if the next sentence already carries the content.", "false")
        }
        if (passive_phrase(current)) {
          emit("reader-facing-japanese", "medium", i, trim(line[i]), "The sentence may hide the actor.", "Name who acts, decides, or requires the action.", "false")
        }
        if (assignment_notation(current)) {
          emit("assignment-notation", "high", i, trim(line[i]), "Implementation identifier appears as a prose actor, condition, or value assignment.", "Rewrite as reader-visible behavior without code identifiers.", "false")
        } else if (identifier(current)) {
          emit("reader-facing-japanese", "medium", i, trim(line[i]), "Code identifiers or internal references appear in prose.", "Explain reader-facing behavior and move raw references to evidence when needed.", "false")
        }
        if (implementation_term(current)) {
          emit("implementation-transcription", "medium", i, trim(line[i]), "The sentence may describe implementation mechanics.", "Rewrite as user-visible behavior without control-flow terms.", "false")
        }
        if (notation_issue(current)) {
          emit("notation-emphasis", "low", i, trim(line[i]), "Decorative notation or empty emphasis may be carrying the prose.", "Use sentence order, concrete wording, or plain punctuation instead.", "false")
        }
      }
      if (paragraph_parens >= 2) {
        emit("brackets", "high", paragraph_start, "paragraph", "Parenthetical supplements appear repeatedly in one paragraph.", "Keep only a first-use definition; rewrite every other supplement into the sentence or remove it.", "false")
      }
      if (sentence_count(paragraph_text) >= 6) {
        emit("paragraph-rhythm", "medium", paragraph_start, "paragraph", "A paragraph contains many Japanese sentence endings without a blank-line break.", "Judge whether to split the paragraph or use bullets for conditions, steps, criteria, scope, or consequences.", "false")
      }
    }
  ' "${file}"
}

all_issues="$(mktemp)"
# The trap must not become the script's exit status. A bare `trap 'rm -f x'
# EXIT` makes the successful rm the status, so an abort earlier in the script
# reports success and the agent reads an empty scan as a clean document.
# shellcheck disable=SC2154  # rc is assigned inside the trap body itself
trap 'rc=$?; rm -f "${all_issues}"; exit "${rc}"' EXIT

for file in ${files[@]+"${files[@]}"}; do
  [[ -f "${file}" ]] || continue
  # A file the process cannot read must not discard the findings already
  # collected for the files before it.
  if [[ ! -r "${file}" ]]; then
    printf 'scan.sh: cannot read %s; skipped\n' "${file}" >&2
    continue
  fi
  scan_file "${file}" "${all_issues}"
done

issue_count=0
auto_count=0
manual_count=0
while IFS=$'\t' read -r _rule _severity _path _line _quote _reason _suggestion auto; do
  [[ -z "${_rule:-}" ]] && continue
  issue_count=$((issue_count + 1))
  if [[ "${auto}" == "true" ]]; then
    auto_count=$((auto_count + 1))
  else
    manual_count=$((manual_count + 1))
  fi
done <"${all_issues}"

printf '{\n'
printf '  "mode": "report",\n'
printf '  "files": ['
printed=0
for file in ${files[@]+"${files[@]}"}; do
  [[ -f "${file}" && -r "${file}" ]] || continue
  if [[ ${printed} -gt 0 ]]; then printf ', '; fi
  printf '"%s"' "$(json_escape "${file}")"
  printed=$((printed + 1))
done
printf '],\n'
printf '  "applied_fixes": 0,\n'
printf '  "issues": [\n'
printed=0
while IFS= read -r issue; do
  [[ -z "${issue}" ]] && continue
  if [[ ${printed} -gt 0 ]]; then printf ',\n'; fi
  printf '    '
  print_issue_json "${issue}"
  printed=$((printed + 1))
done <"${all_issues}"
printf '\n  ],\n'
printf '  "summary": {\n'
printf '    "issue_count": %d,\n' "${issue_count}"
printf '    "auto_fixable_count": %d,\n' "${auto_count}"
printf '    "manual_count": %d\n' "${manual_count}"
printf '  }\n'
printf '}\n'
