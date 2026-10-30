# Who counts on GitHub, shared by every oe subcommand that reads Issue comments.
# A subcommand puts this file in front of its own jq program.
# Each comment or review is read as an object with authorAssociation and body.
#
# | Signal | Rule |
# |---|---|
# | Trusted author | The author association is OWNER, MEMBER, or COLLABORATOR |
# | Record | A comment by a trusted author whose body starts with the record's marker |
# | Engineer input | A comment or review by a trusted author whose body does not start with the oe marker prefix |
#
# | Record on GitHub | Marker | Written by |
# |---|---|---|
# | Question | `<!-- oe:question -->` | oe question |
#
# Claim, attempt, and verdict records stay on this host, as oe-store.sh describes.
# A marked comment from an older oe is no record, and its marker still keeps it from counting as engineer input.
def trusted: (.authorAssociation // "") as $a | $a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR";
def marker($kind): "<!-- oe:\($kind) -->";
def record($kind): trusted and ((.body // "") | startswith(marker($kind)));
def engineer_input: trusted and ((.body // "") | startswith("<!-- oe:") | not);
