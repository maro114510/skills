# Test Policy

Rules for writing, changing, and deleting tests.
implement's playbooks and the reviewer cite them as Citing This Policy says, instead of restating them.
Each rule names the public source it rests on, listed in Sources.
Sources in Japanese are paraphrased in English.

## Sources

Each rule names its source by the label below. A slide is addressed as `?slide=N` on the deck URL.

| Label | Source | Author | URL |
|---|---|---|---|
| Canon TDD | Canon TDD, Japanese translation with translator's notes | Kent Beck, translated by Takuto Wada | https://t-wada.hatenablog.jp/entry/canon-tdd-by-kent-beck |
| Fighting defects | Fighting defects by writing tests | Takuto Wada | https://t-wada.hatenablog.jp/entry/debugging-tests |
| Testing and TDD | Automated testing and TDD, an overview | Takuto Wada | https://gihyo.jp/article/2024/01/automated-test-and-tdd |
| Savanna 2 | Savanna Letter, part 2: false negatives | Takuto Wada | https://gihyo.jp/dev/serial/01/savanna-letter/0002 |
| Savanna 4 | Savanna Letter, part 4: test doubles | Takuto Wada | https://gihyo.jp/dev/serial/01/savanna-letter/0004 |
| Savanna 7 | Savanna Letter, part 7: readable tests | Takuto Wada | https://gihyo.jp/dev/serial/01/savanna-letter/0007 |
| Savanna 8 | Savanna Letter, part 8: tests resistant to refactoring | Takuto Wada | https://gihyo.jp/dev/serial/01/savanna-letter/0008 |
| TDD in AI era | TDD in the AI era, 2026-04 edition (slides) | Takuto Wada | https://speakerdeck.com/twada/tdd-in-ai-era-202604-edition |
| Test result objectives | Organizing the objectives of automated test results (slides) | Takuto Wada | https://speakerdeck.com/twada/organizing-objectives-of-automated-test-results |

Rules from Canon TDD are Kent Beck's words in Takuto Wada's translation.

## Citing This Policy

- Cite a rule by its number together with its gist, such as "test-policy 5.2 (a regression test reproduces the condition the old behavior needed)". A number alone is never enough.
- In a finding or a report to a person, state the concrete problem first, and add the rule as its reference.
- Never renumber a rule. Add a new rule at the end of its section. Mark a withdrawn rule `Withdrawn` and keep its number, so that earlier citations never point to a different rule.

## 1. Process

| # | Rule | Source |
|---|---|---|
| 1.1 | Before writing test code, list the scenarios the change must cover as a test list. Keep implementation design out of the list, and add anything noticed later to it | Canon TDD |
| 1.2 | Turn exactly one item of the list into a concrete, runnable test at a time. Never translate the whole list into tests before making the first one pass | Canon TDD |
| 1.3 | Run each new or changed test and see it fail at its assertion before changing production code. A test that passes before the change means the test is wrong or the cause is misunderstood: stop and reexamine it. Rule 1.8 is the only exception | Fighting defects |
| 1.4 | Make the failing test pass by changing production code, keeping every earlier test passing. Do not refactor in this step: make it run, then make it right | Canon TDD |
| 1.5 | Refactor only while every test passes, and keep what the tests assert unchanged | Testing and TDD |
| 1.6 | Commit each step on its own: the failing test as `test:`, the change that makes it pass as `feat:`, or `fix:` for a bug, and each refactoring as `refactor:` | TDD in AI era, slide 22 |
| 1.7 | For a bug, write an automated test that reproduces it at the smallest level before fixing it, see the test fail, fix the code, see the test pass, then run the whole suite | Fighting defects |
| 1.8 | The one exception to rule 1.3: a test that pins behavior the change must preserve, such as one written before a refactoring, passes on the pre-change code by design. Show instead that it can fail, by inserting an obvious defect into that behavior in a temporary copy and seeing the test fail. Commit it as `refactor:`, the only type whose commits the before-change check skips | Savanna 2 |

## 2. Prohibitions

| # | Rule | Source |
|---|---|---|
| 2.1 | Never delete or loosen an assertion to make a test pass. Make it pass for real | Canon TDD |
| 2.2 | Never copy a value the code under test computed into the test as its expected value. It removes the double check | Canon TDD |
| 2.3 | Never compute an expected value with the same logic as the code under test. The test then shares the code's bug and passes anyway | Savanna 2 |
| 2.4 | Never write a test without an assertion, for example to raise coverage | Canon TDD |
| 2.5 | Never test through internal structure. Test through the public interface, per behavior rather than per structural unit, and assert the resulting state rather than the interactions | Savanna 8 |
| 2.6 | Do not write a test for code that holds almost no responsibility of its own and is already covered by other tests | Savanna 8 |

## 3. Writing

| # | Rule | Source |
|---|---|---|
| 3.1 | Name each test for its precondition, its action, and its expected outcome, so the test report reads as a list of specifications. Never name it "works correctly" or "returns the correct result": the name says what correct means | Savanna 7 |
| 3.2 | Setup that does not convey the test's intent may move into a fixture or helper. Setup the expected outcome depends on stays visible in the test body: keep it inline, or name the fixture or helper for the precondition it establishes, such as `expiredSubscription` rather than `subscription2` | Savanna 7 |
| 3.3 | Write expected values as literals. When a literal's meaning is not obvious, bind it to an explaining variable whose name says what it is or how it is derived, instead of a comment. Part 7 annotates the derivation with a comment; this policy uses part 2's explaining variable, so that the derivation stays visible in code | Savanna 2 |
| 3.4 | Lay out each test body as arrange, act, and assert, in that order | Savanna 7 |
| 3.5 | Assert with a comparison that reports the expected and actual values, such as an equality assertion, rather than a boolean expression that reports only true or false | Test result objectives, slide 8 |
| 3.6 | Write one test per behavior. A function that does three jobs gets three tests | Savanna 8 |

## 4. Independence

| # | Rule | Source |
|---|---|---|
| 4.1 | A test never affects another test. It never reads state another test wrote, such as a file, a record, or a module-level variable, so its result never depends on execution order | Testing and TDD |
| 4.2 | Never share a mutable fixture between tests. Each test builds the state it changes | Testing and TDD |
| 4.3 | A test is repeatable: it runs the same anywhere at any time, and it never needs data reset or files removed by hand after it runs | Testing and TDD |
| 4.4 | Every new or changed test passes both when run alone and when the changed test files run in shuffled order | Testing and TDD |

## 5. Preconditions

| # | Rule | Source |
|---|---|---|
| 5.1 | Establish every precondition the expected outcome depends on inside the test, or through a fixture named for it as rule 3.2 says. Never rely on a default, leftover state, or the environment to supply it, because setup done out of sight hides the cause of the outcome | Savanna 7 |
| 5.2 | A regression test reproduces the condition under which the old behavior occurred, not only the input that showed it: the state, configuration, data, and ordering in which it appeared, reduced to the smallest set that still reproduces it. It must fail on the pre-change code for that reason, as rule 1.3 says | Fighting defects |
| 5.3 | Control time, randomness, and external services from the test so it is reproducible. A dependency that runs deterministically in the same process or on the same machine stays real | Savanna 4 |

## 6. Deleting and Changing Tests

| # | Rule | Source |
|---|---|---|
| 6.1 | Delete a test only when the behavior it specifies is removed, or when another test covers the same behavior. Never delete a test because it fails | Savanna 8, Canon TDD |
| 6.2 | Record what each deleted test covered, and where that coverage now lives or why it is no longer needed, as a `Removed-Test: <name> -- <reason>` trailer on the deleting commit, the format `scripts/gate-tests.sh` reads. An unrecorded deletion cannot be told apart from removing an assertion to make a test pass | Canon TDD |
| 6.3 | Changing an existing test's expected outcome or preconditions is a behavior change. Make it in a `test:` commit before the production change, and see the changed test fail on the pre-change code. When the change removes behavior, its first commit is a `test:` commit with a test asserting the behavior is gone, which fails on the pre-change code because the behavior is still there | TDD in AI era, slide 22, Fighting defects |
| 6.4 | A refactoring of production code never changes what a test asserts. A test that breaks under a purely structural change is coupled to structure: rewrite it to test behavior, as rule 2.5 says, in a commit of its own that follows rule 1.8, before the refactoring | Testing and TDD |

## 7. Evidence

| # | Rule | Source |
|---|---|---|
| 7.1 | What counts as evidence that a test, run, or file satisfies an acceptance criterion is defined in [evidence.md](evidence.md). This policy does not redefine it | Fighting defects |

## Failure Patterns

| Pattern | What goes wrong | Rules |
|---|---|---|
| Missing precondition | A regression test omits the state the bug needed, so it passes on the pre-change code and guards nothing | 1.3, 5.1, 5.2 |
| Shared fixture and order | Tests pass only in one order, because one test changes a fixture another reads | 4.1, 4.2, 4.4 |
| Leaked logic | The expected value is computed by the code under test or a copy of its logic, so the test shares the bug | 2.2, 2.3 |
| Weakened test | An assertion is removed or loosened, or a failing test deleted, to reach green | 2.1, 6.1, 6.2 |
| Structure-coupled test | A test asserts internals, breaks under refactoring, and gets rewritten to match the new code | 2.5, 6.4 |
| Opaque test | The name says "works correctly", setup hides in an unnamed fixture, or a magic literal is explained only by a comment | 3.1, 3.2, 3.3 |

## Mechanical Checks

`scripts/gate-tests.sh` checks part of some rules over a commit range. A rule, or the part of a rule, it does not check still applies, and a passing check is not evidence, as [evidence.md](evidence.md) section 2.2 says.

| Check | Covers part of |
|---|---|
| before-change | 1.3, 5.2, 6.3: the test fails on the parent, but any failure its `build_failure` pattern does not match passes the check, so failing for the right reason stays unchecked |
| isolation | 4.4 |
| shuffle | 4.1, 4.2, 4.4 |
| removed | 6.2 |
