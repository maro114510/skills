# The review bots that start a repair Owner, and how one of their findings is read.
# oe-ready.sh and oe attempt put this file in front of their own jq program, next to oe-records.jq,
# so the two never disagree on which bot counts or on what asks it to review again.
#
# | Bot | Login | Repairs | Asks again with |
# |---|---|---|---|
# | CodeRabbit | coderabbitai | Critical, Major | @coderabbitai review |
# | Codex | chatgpt-codex-connector | P0, P1 | @codex review |
#
# - The login is the GraphQL one a Bot author carries, without the [bot] suffix REST shows.
# - The level is a word anywhere in the finding's first line, because the bots change their formats.
#   - A word ends at a character that is not a letter or a digit, so `_Major_` and `**P1**` count but `majority` does not.
# - A bot's round is one repair per claim: once an attempt record holds the bot, its later findings go to the engineer.
def bots: {
  "coderabbitai": {levels: ["critical", "major"], mention: "@coderabbitai review"},
  "chatgpt-codex-connector": {levels: ["p0", "p1"], mention: "@codex review"}
};

# Prints the levels bot $1 repairs, or null for a bot that is not listed.
def bot_levels($login): (bots[$login] // {}).levels;

# Prints what asks bot $1 to review again, or null for a bot that is not listed.
def bot_mention($login): (bots[$login] // {}).mention;

# Succeeds when a trusted user approved the head $2 in the review nodes $1.
def bot_approved($reviews; $head): any($reviews[]?; trusted and ((.commit.oid // "") == $head));

# Prints the finding of one review thread that starts a repair, and nothing for any other thread.
#
# | Name | Holds |
# |---|---|
# | $since | The latest attempt record or claim of the Issue, or null when it has neither |
# | $used | The bots whose round the claim already used |
# | $approved | Whether a trusted user approved the pull request head |
def bot_finding($since; $used; $approved):
  select($approved | not)
  | select(.isResolved != true and .isOutdated != true)
  | ((.root.nodes // []) | first) as $comment
  | select($comment != null)
  | (($comment.author // {})) as $author
  | ($author.login // "") as $login
  | select(($author.__typename // "") == "Bot")
  | select(($used | index($login)) == null)
  | select($since == null or $comment.createdAt > $since)
  | (bot_levels($login)) as $levels
  | select($levels != null)
  | (($comment.body // "") | split("\n") | first) as $line
  | ([$levels[] | . as $level | select($line | test("(^|[^[:alnum:]])" + $level + "([^[:alnum:]]|$)"; "i"))] | first) as $level
  | select($level != null)
  | {login: $login, level: $level, at: $comment.createdAt};
