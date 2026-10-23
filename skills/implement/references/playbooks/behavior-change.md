# Behavior Change

The procedure for writing tests when a task adds, changes, or removes behavior that a user or caller can observe.
It lists steps only. The rules live in [test-policy.md](../test-policy.md), read whole first, and each step names the section it follows.

## Steps

1. Test list. List the scenarios before any test code, as test-policy § Process says. Name each by precondition, action, and outcome, as § Writing says. For a removal, the item is the outcome a caller sees once the behavior is gone: the input rejected, the option unknown, or the output absent.
2. Red. Take the next item, write or change one test for it, and run it on the current code. It fails at its assertion, as § Process says, for the reason its kind gives:

   | Kind | The test | Fails on the current code because |
   |---|---|---|
   | Added | A new test of the new behavior; add a minimal stub first when the interface does not exist | The behavior does not exist yet |
   | Changed | The existing test, with its expected value changed to the new one | The code still behaves the old way |
   | Removed | A new test asserting the removed outcome, as step 1 names it | The code still has the behavior |

   Commit a stub alone as `refactor:`, before the test, because it adds no behavior and the history check applies only test files to the parent.
   The first test of a removal must fail on the pre-change code. If it passes, the behavior is already gone: Phase 2 trigger 2.
   Set its preconditions as § Preconditions says, and keep it independent as § Independence says.
   Record the command and the failure excerpt for Phase 6.9, as [evidence.md](../evidence.md) section 2.2 says.
   Commit the test alone as `test:`.
3. Green. Make the smallest production change that passes the step 2 test and keeps the suite green. Never edit the step 2 test to get there, as § Prohibitions says.
   A test that pinned the removed or replaced behavior now fails. Delete it only as § Deleting and Changing Tests allows, in this commit, and hand the commit skill one `Removed-Test: <name> -- <reason>` trailer per deleted test.
   Commit as `feat:`, marked breaking when it breaks a public interface, as the commit skill's Step 4 says.
4. Refactor. Clean up while the suite stays green, without changing any test's assertion, and commit as `refactor:`. Skip the step when nothing needs cleaning.
5. Repeat steps 2 to 4 until the list is empty. Add a scenario found along the way to the list instead of folding it into the current cycle.

If the commit skill reports that a hook rejected the `test:` commit and left the test staged, run step 3 and commit both as one `feat:`. The history check below still runs that test against the commit's parent.

## History Check

Phase 6 runs `scripts/gate-tests.sh`. Its `before-change` line must report each test of the `test:` and `feat:` commits as failed on the parent, never passed or failed with a build error, and its `removed` line must pass.
A `fail` means a step above was skipped: redo that cycle from step 2.
