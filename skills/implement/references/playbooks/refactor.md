# Refactor

Tests for a task that changes structure while the behavior a user or caller observes stays the same.
Steps only: the rules are in [test-policy.md](../test-policy.md), cited by section.

1. List the behavior the touched code provides through its public interface, as § Prohibitions says tests observe it, and the tests that cover each.
2. Pin. Write a test for each behavior no test covers, or strengthen an existing one. It passes on the current code, so show it can fail with a deliberate break in a temporary copy, as § Process and [evidence.md](../evidence.md) section 2.2 say. Commit it as `refactor:`.
3. Before restructuring, delete each test that asserts the structure being changed, once a step 1 or 2 test covers its behavior, with a `Removed-Test` trailer, as § Deleting and Changing Tests says. Commit as `refactor:`.
4. Restructure in small steps, each green and committed as `refactor:`, with no assertion changed. A test that fails means the step changed behavior: undo the step, as § Prohibitions says.
5. A behavior change the task turns out to need goes through [behavior-change.md](behavior-change.md) or [bug-fix.md](bug-fix.md).

History check: `before-change` skips `refactor:` commits, so step 2's deliberate break is the pin's failing observation.
