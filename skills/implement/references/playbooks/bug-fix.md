# Bug Fix

The procedure for writing tests when a task corrects behavior that differs from what was specified or intended.
It lists steps only. The rules live in [test-policy.md](../test-policy.md), read whole first, and each step names the section it follows.

## Steps

1. Find the condition. Establish the state, configuration, data, and ordering under which the defect occurs, as the regression rule in test-policy § Preconditions says, not only the input that showed it.
2. Red. Write one test that sets that condition inside the test, as § Preconditions says, names it, as § Writing says, and asserts the correct outcome. Run it on the current code.
   It fails at its assertion with the reported symptom, never with a build, import, or setup error, as § Process says. If it passes, the defect does not reproduce: Phase 2 trigger 2.
   Record the command, exit code, and failure excerpt. This run is the observation of the test failing without the fix that [evidence.md](../evidence.md) section 2.2 asks for.
   Commit the test alone as `test:`, naming the defect it pins.
3. Fix. Change only production code until the suite passes. Never edit the step 2 test, as § Prohibitions says. A test that has to change did not reproduce the condition: return to step 1, and the new test goes through step 2 again.
   Commit as `fix:`.
4. Refactor. Clean up while the suite stays green, without changing any test's assertion, and commit as `refactor:`. Skip the step when nothing needs cleaning.

If the commit skill reports that a hook rejected the `test:` commit and left the test staged, run step 3 and commit both as one `fix:`. The history check below still runs that test against the commit's parent.

When no test can reproduce the defect, follow the same steps with a script or manual steps, record why in the decision log, and record each run as step 2 says. The history check then has nothing to check.

## History Check

Phase 6 runs `scripts/gate-tests.sh`, whose `before-change` check runs each new or changed test of a commit against that commit's parent.
It is the one step that shows the committed step 2 test guards the defect; no other step reruns the test without the fix.

| `before-change` reports the step 2 test | Action |
|---|---|
| Failed on the parent | Proceed |
| Passed on the parent | It does not guard the defect: Phase 2 trigger 2, because the defect cannot be shown with this test |
| Failed with a build error on the parent | The test needs something its parent lacks. The check applies only test files to the parent, so put that, such as a minimal stub, in a `refactor:` commit of its own before the `test:` commit, and run the check again |
| `not-run` | Report the line. The step 2 observation stands alone |

A passing check is never evidence, as evidence.md section 2.2 says. The step 2 observation is.
