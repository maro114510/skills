# Refactor

The procedure for writing tests when a task changes structure and the behavior a user or caller observes must stay the same.
It lists steps only. The rules live in [test-policy.md](../test-policy.md), read whole first, and each step names the section it follows.

## Steps

1. List the preserved behavior. Name each behavior the touched code provides through its public interface, as test-policy § Prohibitions says tests observe it, and find the tests that already cover each one.
2. Pin. For each behavior no test covers, write a test of it; a test edited for behavior the code already has, after a green commit, goes through this step too. It passes on the current code, so show that it can fail as the exception in § Process says, using the deliberate break in [evidence.md](../evidence.md) section 2.2, never in the worktree. Record the command and the failure excerpt.
   Set its preconditions as § Preconditions says, and keep it independent as § Independence says.
   Commit the pinning tests as `refactor:`, as § Process says.
3. Replace structure tests, before restructuring. A test that asserts or reaches into the internal structure the refactor changes breaks § Prohibitions. Make sure a public-interface test from step 1 or 2 covers its behavior, then delete it as § Deleting and Changing Tests says, in a `refactor:` commit of its own, handing the commit skill a `Removed-Test: <name> -- <reason>` trailer.
4. Restructure in small steps. After each one the suite stays green, and no test's assertion changes. Commit each green step as `refactor:`.
   A test that fails after a step shows that the step changed behavior: undo that step instead of changing the test, as § Prohibitions says. If the failing test turns out to be a structure test step 3 missed, undo the step, run step 3 for it, and redo the step.
   Leave the fixtures and helpers of step 2's tests untouched, because an edit to them voids its deliberate-break observation. When a step must edit one, repeat that observation afterward.
5. If the task turns out to need a behavior change, stop at a green `refactor:` commit and run [behavior-change.md](behavior-change.md) or [bug-fix.md](bug-fix.md) for that part.

## History Check

Phase 6 runs `scripts/gate-tests.sh`. Its `before-change` check skips `refactor:` commits, because a pinning test passes on the parent by design; step 2's deliberate break is that test's failing observation.
Its `isolation`, `shuffle`, and `removed` lines must still pass.
