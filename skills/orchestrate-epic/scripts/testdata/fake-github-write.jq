# Applies one oe write to a test's GitHub state, as GitHub would.
# fake-gh.sh runs it with $state, $call, $arg, and $fields, the -f and -F fields of the call.
# It prints {state, response} on success, and {error} when GitHub would refuse the write.
# fake-github.jq lists every field of the state.
#
# | $call | $arg | Write | Refused when |
# |---|---|---|---|
# | create_ref | none | Creates refs/heads/feat/issue-N at $fields.sha | The branch already exists |
# | assign | Issue number | Adds $fields["assignees[]"] to the Issue's assignees | The Issue does not exist |
# | comment | Issue or pull request number | Appends a comment by the OWNER at 08:00 | Neither exists |
# | status | Commit SHA | Puts a commit status on that SHA, newest first in written_statuses | Never |
# | update_branch | Pull request number | Merges the base into its branch: a new head pushed at 08:00, named by f's and the number, with no checks, verdicts, or missing merges | It is not open, its head is not $fields.expected_head_sha, or it sets update_refusal |
#
# An update of a pull request that sets update_stalls is accepted and changes nothing.

def create_ref:
  ($fields.ref | capture("^refs/heads/feat/issue-(?<n>[1-9][0-9]*)$") // error("unexpected ref \($fields.ref)"))
  | (.n | tonumber) as $n
  | $state
  | if ([.issues[] | select(.number == $n)] | length) == 0 then error("no Issue #\($n) in the state")
    elif (.issues[] | select(.number == $n) | .branch) then {error: "Reference already exists (HTTP 422)"}
    else {state: (.issues |= map(if .number == $n then . + {branch: true, branch_sha: $fields.sha} else . end)),
      response: {ref: $fields.ref, object: {sha: $fields.sha}}}
    end;

def assign($n):
  $state
  | if ([.issues[] | select(.number == $n)] | length) == 0 then {error: "Not Found (HTTP 404)"}
    else {state: (.issues |= map(if .number == $n then .assignees += [$fields["assignees[]"]] else . end)),
      response: {number: $n}}
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

def pr_sha: .head_sha // ("\(.number)" as $n | ("b" * (40 - ($n | length))) + $n);

def update_branch($n):
  ([$state.issues[].pull_requests[]? | select(.number == $n)] | first) as $pr
  | ("\($n)" as $s | ("f" * (40 - ($s | length))) + $s) as $new
  | if $pr == null or ($pr.state // "open") != "open" then {error: "Not Found (HTTP 404)"}
    elif ($pr | pr_sha) != $fields.expected_head_sha then {error: "expected head sha didn't match current head ref. (HTTP 422)"}
    elif $pr.update_refusal then {error: $pr.update_refusal}
    elif $pr.update_stalls then {state: $state, response: {message: "Updating pull request branch."}}
    else {state: ($state | .issues |= map(.pull_requests |= (if . == null then . else map(
        if .number == $n then . + {head_sha: $new, pushed: "08:00", checks: null, check_runs: null, verdicts: null, missing_merges: null}
        else . end) end))),
      response: {message: "Updating pull request branch."}}
    end;

if $call == "create_ref" then create_ref
elif $call == "update_branch" then update_branch($arg | tonumber)
elif $call == "assign" then assign($arg | tonumber)
elif $call == "comment" then comment($arg | tonumber)
elif $call == "status" then status($arg)
else error("unknown write \($call)") end
