# Who counts on GitHub, shared by every oe subcommand that reads Issue comments.
# A subcommand puts this file in front of its own jq program.
# Each comment or review is read as an object with authorAssociation and body.
#
# | Signal | Rule |
# |---|---|
# | Trusted author | The author association is OWNER, MEMBER, or COLLABORATOR, and the author is not the agents' own bot |
# | Own bot | A Bot author whose login is the one in git config skills.bot, which the caller defines as own_login |
# | Record | A comment by a trusted author or the own bot whose body starts with the record's marker |
# | Engineer input | A comment or review by a trusted author whose body does not start with the oe marker prefix |
#
# An App's bot has the association NONE, so only the own bot rule lets its records count.
# The own bot never counts as a trusted author, an engineer's answer, or an approval, whatever association GitHub reports.
# Any other bot, and a User with the same login, stays untrusted.
#
# | Record on GitHub | Marker | Written by |
# |---|---|---|
# | Question | `<!-- oe:question -->` | oe question |
#
# Claim, attempt, and verdict records stay on this host, as oe-store.sh describes.
# A marked comment from an older oe is no record, and its marker still keeps it from counting as engineer input.
def own_bot: own_login != "" and (.author.__typename // "") == "Bot" and (.author.login // "") == own_login;
def trusted: ((.authorAssociation // "") as $a | $a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR") and (own_bot | not);
def marker($kind): "<!-- oe:\($kind) -->";
def record($kind): (trusted or own_bot) and ((.body // "") | startswith(marker($kind)));
def engineer_input: trusted and ((.body // "") | startswith("<!-- oe:") | not);
