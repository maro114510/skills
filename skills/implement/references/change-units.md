# Change Units

implement owns this definition. Other skills reference this file and never restate it.

A unit is a group of commits that a reviewer verifies as one kind of thing, never a single commit. A test and the code it drives are one unit although their playbook commits them separately.

Split into units only for one of these reasons:

1. A structure change from a behavior change or a bug fix
2. A mechanical bulk change, such as a rename or a format run, from hand-written logic
3. Changes in different areas. The areas are documentation that describes the system, such as Design Docs, ADRs, plans, and runbooks; infrastructure, such as Terraform; deploy configuration and feature flags; schemas and contracts, such as DDL and proto; and other code. Tests and generated files belong to the area of the code they come from, and an instruction file that is the product, such as a SKILL.md, is code
4. Changes that do not depend on each other
5. Changes that must be reverted separately

Never split for size alone, a test from the code it drives, or a new function or type from its first usage. A schema or contract change is split from the code that uses it by reason 3. A large change with one reason for change is one unit.

Size is a guide only: a unit changes about 200 to 400 lines of production code, not counting tests, generated files, or diagrams. A unit well above that looks for a seam among the reasons above, and never splits for size alone.

List the units in the order structure change, behavior change, cleanup, and never before a unit they depend on. One line each:

```
<n>. <one sentence: what changes> | depends on: <unit numbers, or none> | separate because: <every reason number that applies, and why>
```

A change with no reason to split is one unit and needs only the sentence.
Decide the split yourself and record it in the decision log. Ask only when a Phase 2 trigger fires.
