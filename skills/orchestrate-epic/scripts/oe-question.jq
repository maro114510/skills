# How oe question reads a question: the shape skills/shared/question.md sets, and the letters on its options.
# oe-question.sh puts `def lang: "en";` or `def lang: "ja";` in front of this file, from create-pr's lang.sh.
#
# | Part | Label in en | Label in ja | Holds |
# |---|---|---|---|
# | 1 | Decision | 判断 | One line of text after the label |
# | 2 | Context | 背景 | The label alone, then 3 or 4 bullets |
# | 3 | Criteria | 基準 | The label alone, then 1 or 2 bullets |
# | 4 | Options | 選択肢 | The label alone, then 2 to 4 options |
# | 5 | Recommendation | 推奨 | One line of text after the label |
# | 6 | Agreement | 合意 | One line of text after the label |
#
# - Parts come in this order, separated by blank lines, and a label ends with a colon, or a full-width one in ja.
# - An option is a bullet `- A. <label>`, lettered A, B, C, D in order, with one indented bullet under it saying how it fares.
#   The letter is what the person answers with, in the session's conversation or on the Issue.
# - The language check is coarse on purpose: an en question holds no Japanese letter, and a ja Decision holds one.
#
# Neither the template's line-length caps nor its rules for the reader are checked, because no rule tells them apart from good text.

def labels:
  if lang == "ja" then ["判断", "背景", "基準", "選択肢", "推奨", "合意"]
  else ["Decision", "Context", "Criteria", "Options", "Recommendation", "Agreement"] end;
def japanese: test("[\\p{Hiragana}\\p{Katakana}\\p{Han}]");
def label_pattern($label): "^" + $label + "[:：][ 　]*";
def labelled($label): test(label_pattern($label));
def after($label): sub(label_pattern($label); "");
def bullet: test("^- \\S");
def sub_bullet: test("^[ \t]+- \\S");
def letters: ["A", "B", "C", "D"];

# The text's lines without carriage returns or trailing blanks, grouped into parts at blank lines.
def parts:
  gsub("\r"; "") | split("\n") | map(sub("[ \t]+$"; ""))
  | reduce .[] as $line ([[]];
      if $line == "" then (if (last | length) > 0 then . + [[]] else . end)
      else .[:-1] + [last + [$line]] end)
  | map(select(length > 0));

# Prints why an options part is malformed, one reason per output, and nothing when it is well formed.
def option_problems($label):
  .[1:] as $lines
  | if (.[0] | after($label)) != "" then "\($label) holds its options on the lines under its label"
    elif ($lines | length) % 2 != 0 then "each option under \($label) needs exactly one indented line on how it fares"
    elif ($lines | length) < 4 or ($lines | length) > 8 then "\($label) needs 2 to 4 options"
    else
      range(0; $lines | length; 2) as $i
      | letters[$i / 2] as $letter
      | if ($lines[$i] | startswith("- \($letter). ") | not) then "option \($i / 2 + 1) must start with \"- \($letter). \""
        elif ($lines[$i + 1] | sub_bullet | not) then "option \($letter) needs one indented line on how it fares"
        else empty end
    end;

# Prints why the question, a string, breaks the template, one reason per output, and nothing when it follows it.
def problems:
  labels as $l
  | parts as $parts
  | if ([$parts[] | select(.[0] | labelled($l[0]))] | length) > 1 then
      "it holds more than one \($l[0]); ask one decision per question, the one blocking the work first"
    elif ($parts | length) != 6 then
      "it has \($parts | length) parts separated by blank lines; the template has 6: \($l | join(", "))"
    else
      (range(0; 6) as $i | $parts[$i] as $p | $l[$i] as $label
        | if ($p[0] | labelled($label) | not) then "part \($i + 1) must start with \"\($label):\""
          elif $i == 0 or $i == 4 or $i == 5 then
            if ($p | length) != 1 or ($p[0] | after($label)) == "" then "\($label) must be one line of text after its label"
            else empty end
          elif $i == 1 or $i == 2 then
            (if $i == 1 then [3, 4] else [1, 2] end) as [$min, $max]
            | if ($p[0] | after($label)) != "" or ($p | length) - 1 < $min or ($p | length) - 1 > $max
                or any($p[1:][]; bullet | not)
              then "\($label) must be its label alone, then \($min) to \($max) bullets"
              else empty end
          else $p | option_problems($label) end),
      (if lang == "en" and japanese then "it is not in English, the reader's language"
       elif lang == "ja" and ($parts[0][0] | after($l[0]) | japanese | not) then "it is not in Japanese, the reader's language"
       else empty end)
    end;

# The options of a question written on an Issue, as {letter, label}, from its body as a string.
def options:
  [gsub("\r"; "") | split("\n")[] | capture("^- (?<letter>[A-D])\\. (?<label>.+)$")];

# The Decision line of a question written on an Issue, in either language, from its body as a string, or null when it has none.
def decision_line:
  [gsub("\r"; "") | split("\n")[] | select(test("^(Decision|判断)[:：]"))] | first;

# One decision as the decisions section holds it: the question's Decision line, the answer under it, and the question's URL.
# A question without a Decision line, written before the template was enforced, is named by its URL alone.
def decision_entry($decision; $answer; $url):
  [(if $decision then "- " + $decision else "- " + $url end),
    ($answer | gsub("\r"; "") | split("\n") | to_entries[]
      | if .key == 0 then "  - " + .value elif .value == "" then "" else "    " + .value end),
    (if $decision then "  - " + $url else empty end)]
  | join("\n");

# The Issue body, a string, with $entry appended at the end of its section headed `## $heading`.
# A body without that section gets it at its end, with $note under the heading.
# Every other line stays as it was, and the body's own line ending joins the new lines.
def add_decision($heading; $note; $entry):
  (if test("\r\n") then "\r\n" else "\n" end) as $nl
  | split($nl) as $lines
  | ($entry | split("\n")) as $new
  | ([$lines | to_entries[] | select(.value | sub("[ \t]+$"; "") == "## " + $heading) | .key] | first) as $h
  | if $h == null then
      sub("\\s+$"; "") as $kept
      | (if $kept == "" then "" else $kept + $nl + $nl end) + (["## " + $heading, "", $note, ""] + $new | join($nl))
    else
      ([range($h + 1; $lines | length) | select($lines[.] | test("^#{1,2} "))] | first // ($lines | length)) as $end
      | ([range($h + 1; $end) | select($lines[.] | test("\\S"))] | last // $h) as $last
      | $lines[:$last + 1] + (if $last == $h then [""] else [] end) + $new
        + (if $last + 1 == $end and $end < ($lines | length) then [""] else [] end) + $lines[$last + 1:]
      | join($nl)
    end;
