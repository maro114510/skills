# Applies one oe write to a test's GitHub state, as GitHub would.
# fake-gh.sh runs it with $state, $call, $arg, and $fields, the -f and -F fields of the call.
# It prints {state, response} on success, and {error} when GitHub would refuse the write.
# fake-github.jq lists every field of the state.
#
# | $call | $arg | Write | Refused when |
# |---|---|---|---|
# | create_ref | none | Creates refs/heads/feat/issue-N at $fields.sha | The branch already exists |
# | comment | Issue number | Appends a comment by the OWNER at 08:00 | The Issue does not exist |

def create_ref:
  ($fields.ref | capture("^refs/heads/feat/issue-(?<n>[1-9][0-9]*)$") // error("unexpected ref \($fields.ref)"))
  | (.n | tonumber) as $n
  | $state
  | if ([.issues[] | select(.number == $n)] | length) == 0 then error("no Issue #\($n) in the state")
    elif (.issues[] | select(.number == $n) | .branch) then {error: "Reference already exists (HTTP 422)"}
    else {state: (.issues |= map(if .number == $n then . + {branch: true, branch_sha: $fields.sha} else . end)),
      response: {ref: $fields.ref, object: {sha: $fields.sha}}}
    end;

def comment($n):
  $state
  | if ([.issues[] | select(.number == $n)] | length) == 0 then {error: "Not Found (HTTP 404)"}
    else {state: (.issues |= map(if .number == $n then .comments += [{by: "OWNER", at: "08:00", body: $fields.body}] else . end)),
      response: {html_url: "https://github.com/o/r/issues/\($n)#issuecomment-1", body: $fields.body}}
    end;

if $call == "create_ref" then create_ref
elif $call == "comment" then comment($arg | tonumber)
else error("unknown write \($call)") end
