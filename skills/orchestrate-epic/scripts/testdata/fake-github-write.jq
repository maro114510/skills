# Applies one oe write to a test's GitHub state, as GitHub would.
# fake-gh.sh runs it with $state, $call, $arg, and $fields, the -f and -F fields of the call.
# It prints {state, response} on success, and {error} when GitHub would refuse the write.
# fake-github.jq lists every field of the state.
#
# | $call | $arg | Write | Refused when |
# |---|---|---|---|
# | create_ref | none | Creates refs/heads/feat/issue-N at $fields.sha | The branch already exists |
# | comment | Issue or pull request number | Appends a comment by the OWNER at 08:00 | Neither exists |
# | status | Commit SHA | Puts a commit status on that SHA, newest first in written_statuses | Never |

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
  {by: "OWNER", at: "08:00", body: $fields.body} as $new
  | $state
  | if ([.issues[] | select(.number == $n)] | length) > 0 then
      {state: (.issues |= map(if .number == $n then .comments += [$new] else . end)),
        response: {html_url: "https://github.com/o/r/issues/\($n)#issuecomment-1", body: $fields.body}}
    elif ([.issues[].pull_requests[]? | select(.number == $n)] | length) > 0 then
      {state: (.issues |= map(.pull_requests |= (if . == null then . else map(if .number == $n then .comments += [$new] else . end) end))),
        response: {html_url: "https://github.com/o/r/pull/\($n)#issuecomment-1", body: $fields.body}}
    else {error: "Not Found (HTTP 404)"} end;

def status($sha):
  ($fields | {sha: $sha, context, state, description, target_url}) as $new
  | {state: ($state | .written_statuses = [$new] + (.written_statuses // [])), response: $new};

if $call == "create_ref" then create_ref
elif $call == "comment" then comment($arg | tonumber)
elif $call == "status" then status($arg)
else error("unknown write \($call)") end
