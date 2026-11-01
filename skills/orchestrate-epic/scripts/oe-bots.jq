# The review bots that start a repair Owner, and how one of their findings is read.
# oe-ready.sh and oe attempt put this file in front of their own jq program, next to oe-records.jq,
# so the two never disagree on which bot counts or on what asks it to review again.
#
# | Bot | Login | Asks again with |
# |---|---|---|
# | CodeRabbit | coderabbitai | @coderabbitai review |
# | Codex | chatgpt-codex-connector | @codex review |
#
# - The login is the GraphQL one a Bot author carries, without the [bot] suffix REST shows.
# - A finding counts when its first line holds one repair_levels word, whoever wrote it.
#   - The set is shared by every listed bot, because a per-bot list goes stale the moment a bot relabels its findings.
#   - A word ends where a letter or a digit starts or ends, so "majority" never counts.
# - A bot's round is one repair per claim: once an attempt record holds the bot, its later findings go to the engineer.
def bots: {
  "coderabbitai": {mention: "@coderabbitai review"},
  "chatgpt-codex-connector": {mention: "@codex review"}
};

# The level words that mark a repair. CodeRabbit writes Critical and Major, Codex P0 and P1;
# Minor, Trivial, P2, and P3 stay out, so the Owner never chases style.
def repair_levels: ["critical", "major", "p0", "p1"];

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
  | select(bots[$login] != null)
  | select(($used | index($login)) == null)
  | select($since == null or $comment.createdAt > $since)
  | (($comment.body // "") | split("\n") | first) as $line
  | ([repair_levels[] | . as $level | select($line | test("(^|[^[:alnum:]])" + $level + "([^[:alnum:]]|$)"; "i"))] | first) as $level
  | select($level != null)
  | {login: $login, level: $level, at: $comment.createdAt};
