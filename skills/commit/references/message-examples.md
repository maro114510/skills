# Commit Body Examples

Examples for SKILL.md Step 4's body rules and Step 5's Compact Pass.

Good (why facts, one per bullet):
```
- Case 09 was a false positive: its integrity_concern justification restated "overextended" and "not_established."
- decision-rubric.md already treats both conditions as insufficient on their own.
```

Bad (what/how — cut this, the diff already shows it):
```
- Add a restatement check to integrity_concern: strip the judgment-name words from the stated reason before setting true.
```

Bad (verification narration — belongs in the PR's Test Plan, not here):
```
- Re-verified all 12 eval cases against the fixed SKILL.md; the 9/9 overextension detection rate is preserved.
- The new test fails as expected.
```

Bad (file enumeration — "what" wearing structure, not why):
```
- commit/SKILL.md: Step 4 body rules rewritten as bullets.
- create-pr/SKILL.md: cross-reference updated to match.
```
