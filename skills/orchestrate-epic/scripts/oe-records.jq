# Who counts, shared by every oe subcommand that reads Issue comments.
# A subcommand puts this file in front of its own jq program.
# Each comment or review is read as an object with authorAssociation and body.
#
# | Signal | Rule |
# |---|---|
# | Trusted author | The author association is OWNER, MEMBER, or COLLABORATOR |
# | Record | A comment by a trusted author whose body starts with the record's marker |
# | Engineer input | A comment or review by a trusted author whose body does not start with the oe marker prefix |
#
# | Record | Marker | Written by |
# |---|---|---|
# | Claim | `<!-- oe:claim -->` | oe claim |
# | Attempt | `<!-- oe:attempt -->` | oe attempt |
# | Question | `<!-- oe:question -->` | oe question |
def trusted: (.authorAssociation // "") as $a | $a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR";
def marker($kind): "<!-- oe:\($kind) -->";
def record($kind): trusted and ((.body // "") | startswith(marker($kind)));
def engineer_input: trusted and ((.body // "") | startswith("<!-- oe:") | not);
