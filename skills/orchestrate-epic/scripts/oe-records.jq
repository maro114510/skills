# Who counts on GitHub, shared by every oe subcommand that reads Issue comments.
# A subcommand puts this file in front of its own jq program, after the oe_bot definition that bot_def in oe-config.sh prints.
# Each comment or review is read as an object with authorAssociation, body, and, for a comment, author with login and __typename.
#
# | Signal | Rule |
# |---|---|
# | Trusted author | The author association is OWNER, MEMBER, or COLLABORATOR |
# | Agents' bot | A Bot author whose login is oe_bot, the login git config skills.bot names |
# | Record | A comment by a trusted author or the agents' bot whose body starts with the record's marker |
# | Engineer input | A comment or review by a trusted author, never the agents' bot, whose body does not start with the oe marker prefix |
# | Answer | Engineer input, or an answer record, which the session writes from the person's reply even under the agents' bot |
#
# | Record on GitHub | Marker | Written by |
# |---|---|---|
# | Question | `<!-- oe:question -->` | oe question |
# | Answer | `<!-- oe:answer -->` | oe question --answer, run only by the session |
#
# Claim, attempt, and verdict records stay on this host, as oe-store.sh describes.
# A marked comment from an older oe is no record, and its marker still keeps it from counting as engineer input.
# GitHub gives the agents' bot no association, so it counts only for records; a user who takes its login is no Bot.
def trusted: (.authorAssociation // "") as $a | $a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR";
def agents_bot: oe_bot != "" and (.author.__typename // "") == "Bot"
  and ((.author.login // "") | ascii_downcase) == (oe_bot | ascii_downcase);
def marker($kind): "<!-- oe:\($kind) -->";
def record($kind): (trusted or agents_bot) and ((.body // "") | startswith(marker($kind)));
def engineer_input: trusted and (agents_bot | not) and ((.body // "") | startswith("<!-- oe:") | not);
def answer: engineer_input or record("answer");
