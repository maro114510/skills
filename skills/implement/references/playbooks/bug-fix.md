# Bug Fix

Tests for a task that corrects behavior that differs from what was specified or intended.
Steps only: the rules are in [test-policy.md](../test-policy.md), cited by section.

1. Find the condition that makes the defect occur, as the regression rule in § Preconditions asks.
2. Red. Write one test that sets that condition inside the test and asserts the correct outcome. On the current code it fails at its assertion with the reported symptom, as § Process says; if it passes, the defect does not reproduce: Phase 2 trigger 2.
   Record the command, exit code, and failure excerpt. This run is the evidence that the test fails without the fix, as [evidence.md](../evidence.md) section 2.2 says. Commit the test as `test:`.
3. Fix production code only, never the step 2 test, as § Prohibitions says, and commit as `fix:`.
4. Refactor while green, without changing an assertion, and commit as `refactor:`. Skip it when nothing needs it.

When no test can reproduce the defect, follow the same steps with a script or manual steps, record why in the decision log, and record each run.

History check: instead of rerunning the test without the fix, rely on `before-change`, which runs the committed step 2 test against its parent and must report it failed there. Passing there means the test relied on something its commit lacks, such as local state: return to step 1. A passing check is never evidence.
