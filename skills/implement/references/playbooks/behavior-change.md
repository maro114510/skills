# Behavior Change

Tests for a task that adds, changes, or removes behavior a user or caller can observe.
Steps only: the rules are in [test-policy.md](../test-policy.md), cited by section.

1. Test list, as § Process and § Writing say. For a removal, an item is what a caller sees once the behavior is gone: the input rejected, the option unknown, or the output absent.
2. Red. Write or change one test and run it on the current code. It fails at its assertion, as § Process says:

   | Kind | Test | Fails because |
   |---|---|---|
   | Added | A new test | The behavior does not exist yet |
   | Changed | The existing test, with the new expected value | The code still behaves the old way |
   | Removed | A new test asserting the outcome from step 1 | The code still has the behavior |

   If a removal's first test passes, the behavior is already gone: Phase 2 trigger 2.
   When the interface does not exist yet, first commit a minimal stub alone as `refactor:`, so the test fails at its assertion rather than at the missing interface.
   Record the command and failure excerpt, as [evidence.md](../evidence.md) section 2.2 says, and commit the test as `test:`.
3. Green. Make the smallest production change that passes, without editing the step 2 test, as § Prohibitions says. In the same commit, delete the tests of removed behavior as § Deleting and Changing Tests says, each with a `Removed-Test` trailer. Commit as `feat:`, marked breaking when a public interface breaks.
4. Refactor while green, without changing an assertion, and commit as `refactor:`. Skip it when nothing needs it.
5. Repeat steps 2 to 4 until the list is empty.
