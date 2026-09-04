# Default PR Description Structure

Used in Step 3.3 when no repository template exists.

```markdown
## Background

<!-- Explain why this change is needed. Include the root problem, relevant context, constraints, and why this matters now. -->

## Summary

<!-- Explain what changed and how it solves the problem in 1-3 sentences. -->

## Implementation Details

<!-- Explain why this implementation approach was chosen, and tradeoffs or rejected alternatives. Do not restate what each file/group does here — that belongs only in Changes. -->

## Changes

<!-- Group meaningful changes by behavior or area, not by low-level code edits. -->

### [Group name]
- Explain the user-facing or reviewer-relevant meaning of the change.

## Impact

<!-- List affected pages, features, APIs, data formats, configuration, or workflows. Call out breaking changes explicitly. -->

## Concerns

<!-- Note review focus areas, known risks, tradeoffs, uncertainty, and future implications. -->

## Future Considerations

<!-- Describe follow-up work that is intentionally out of scope for this PR. Be specific about what, why, and how it could improve. -->

## Test Plan

<!-- Describe the verification performed and the result. For UI changes, consider before/after screenshots. -->
```
