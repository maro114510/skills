# Test Policy

Rules for writing, changing, and deleting tests.
The file is short so that it is read whole. Other files point to it, or to one of its sections, and never restate a rule.
Each rule ends with its source, listed at the bottom. Japanese sources are paraphrased.

## Process

- Before writing test code, list the scenarios to cover, then turn one item at a time into a runnable test. Source: Canon TDD
- See each new or changed test fail at its assertion before changing production code. A test that passes first is wrong, or its cause is misunderstood. Source: Fighting defects
- The one exception is a test that pins behavior the change must preserve, such as one written before a refactoring. Show it can fail by inserting an obvious defect into that behavior in a temporary copy. Source: Savanna 2
- Commit each step on its own: the failing test as `test:`, the change that makes it pass as `feat:` or `fix:`, and refactoring as `refactor:`, never mixed into the passing step. A test that pins preserved behavior goes in a `refactor:` commit. Source: TDD in AI era, slide 22

## Prohibitions

- Never delete or loosen an assertion, or delete a failing test, to reach green. Source: Canon TDD
- Never take an expected value from the code under test, either by pasting its output or by recomputing it with the same logic. Source: Canon TDD, Savanna 2
- Test through the public interface and assert behavior, never internal structure or call sequences. Source: Savanna 8
- Do not write a test for code that holds almost no responsibility of its own and is already covered by other tests. Source: Savanna 8

## Writing

- Name each test for its precondition, action, and expected outcome. Never name it "works correctly": say what correct means. Source: Savanna 7
- Setup the outcome depends on stays visible in the test: inline, or in a fixture or helper named for the precondition it sets, such as `expiredSubscription`, never `subscription2`. Source: Savanna 7
- Write expected values as literals. Bind a literal whose meaning is not obvious to an explaining variable that names it, not to a comment. Source: Savanna 2

## Independence

- A test never reads state another test wrote and never shares a mutable fixture. Every new or changed test passes both alone and with the changed test files in shuffled order. Source: Testing and TDD

## Preconditions

- Set every precondition the outcome depends on inside the test, never through a default, leftover state, or the environment. Control time and randomness from the test. Source: Savanna 7, Savanna 4
- A regression test reproduces the condition under which the old behavior occurred, not only the input that showed it: the state, configuration, data, and ordering it needed, reduced to the smallest set. It fails on the pre-change code for that reason. Source: Fighting defects

## Deleting and Changing Tests

- Delete a test only when its behavior is removed or another test covers it. Record what it covered and where that coverage now lives as `Removed-Test: <name> -- <reason>` on the deleting commit. Source: Savanna 8, Canon TDD

## Evidence

- What shows that a test satisfies a criterion is defined in [evidence.md](evidence.md). `scripts/gate-tests.sh` checks part of this policy mechanically, and a passing check is not evidence. Source: Fighting defects

## Sources

| Label | URL |
|---|---|
| Canon TDD | https://t-wada.hatenablog.jp/entry/canon-tdd-by-kent-beck (Kent Beck, translated by Takuto Wada) |
| Fighting defects | https://t-wada.hatenablog.jp/entry/debugging-tests |
| Testing and TDD | https://gihyo.jp/article/2024/01/automated-test-and-tdd |
| Savanna 2 | https://gihyo.jp/dev/serial/01/savanna-letter/0002 |
| Savanna 4 | https://gihyo.jp/dev/serial/01/savanna-letter/0004 |
| Savanna 7 | https://gihyo.jp/dev/serial/01/savanna-letter/0007 |
| Savanna 8 | https://gihyo.jp/dev/serial/01/savanna-letter/0008 |
| TDD in AI era | https://speakerdeck.com/twada/tdd-in-ai-era-202604-edition |

Every source except Canon TDD is by Takuto Wada.
