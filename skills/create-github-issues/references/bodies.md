# Step 4 and Step 4.6: Body Rules and Pre-Creation Checks

SKILL.md Step 4 reads this file in full before it writes any body, and Step 4.6 runs every check under Pre-Creation Checks.

## Leaf Issues

Every non-container `Tn`, and every `Tn.m`:

- Requirements section: the approved requirement bullets, verbatim in substance (may be copy-edited for clarity, not expanded).
- Specs section: the approved spec bullets. Omit this section entirely if no technical decision was actually settled in the conversation — do not fill it with invented detail.
- Dependencies section: one line referencing the sibling it depends on, or the template's "none" phrasing. Which parent it points to differs by level:
  - `Tn`: points to the Epic for the full dependency picture.
  - `Tn.m`: points to its parent `Tn`'s body instead — the Epic never shows grandchildren, per the dependency-scope rule in `references/structure.md`.
  Don't restate the full dependency chain here; that lives only in the parent.
- Acceptance Criteria section: concrete, verifiable statements equivalent to "Given X, When Y, Then Z", not vague phrases like "works correctly". Cap the Verification subsection at 5 items. If the real scenarios don't fit in 5, the Step 2 options apply. **Split** (the default): go back to Step 2, split this task into more siblings or grandchildren, and re-run Step 3 approval before writing bodies again. **Compress**: rejected — never silently drop or squeeze items to fit the cap, since that discards the plan's analysis. **Point** (only when an upstream authoritative document — typically a merged, already-reviewed implementation plan — owns the full list): keep 5 items chosen by failure mode rather than happy path, one per distinct kind of failure before a second of the same kind, and write a single prose line after the bullets — never as a sixth bullet — pointing to that document as the authoritative full list, consistent with the existing rule to add a single line linking to an existing design doc and never restate the doc inline. Without such a document, point is unavailable and split remains the default.
- Verification is one list under the template's heading, with no subheading, and every item is observable from a checkout of the repository or CI without a human's credentials. The cap counts it.
  - A check that needs a person, another machine, a real device, or an environment, such as staging that needs a login or a dashboard, or one that names an environment whose access the conversation never described, does not belong in any `Tn`. Step 2 moved it into a person Issue, and Step 3 shows that move, so approving the summary settles it.
  - When a task ends with no check an agent can observe, say so under it in Step 3, since pr-verify would then have nothing to judge.

## Person Issue

Only when Step 2 made one. It is not a `Tn`: no Requirements, Specs, Acceptance Criteria, or Verification section, no token, and no `Tn.m` children.

- Background section: why the work exists and which `Tn` it waits for, named by title, never by `Tn` id.
- What to do section: the source's steps for the person, one line each, from the source's own wording.
- Dependencies section: "Can start after <title> is done." for each `Tn` it waits for, named by title.
- Its blocked-by relation is set at creation by `--blocked-by`, and the Epic's diagram and table do not show it.

## Container `Tn` body

Only when Step 2 promoted it:

- No Requirements, Specs, or Acceptance Criteria section — those live only on its `Tn.m` leaves.
- Background and Scope sections, same shape as the Epic's but scoped to this one theme: what the grouped `Tn.m` children cover.
- The template's dependency section: a small Mermaid `flowchart` grouping its own `Tn.m` children by wave, using `{{Tn.m}}` tokens. Past 12 grandchildren, use the wave table instead — same threshold as the Epic, rarely reached in practice. Scoped to this container only: never another `Tn`'s children, and the Epic's own diagram still shows this `Tn` as a single node, exactly like a leaf.

## Epic

- Dependencies & Parallel Execution Plan section: a Mermaid `flowchart` grouping child Issues into `subgraph` blocks per wave, using `{{Tn}}` tokens (double curly braces) everywhere a real Issue number will later be substituted — both in node labels and in any prose. **If there are more than 12 child Issues, replace the flowchart with the compact wave table** in `references/templates.<LANG>.md` instead — a graph that large stops being readable.
  - **Escaping in node labels:** if a title contains a double quote, write it as the entity code `#quot;` inside the `["..."]` label — never a raw `"` (it terminates the label) and never a backslash-escaped `\"` (Mermaid does not support backslash escaping and the diagram fails to render). Same rule applies to the Step 3 dependency preview.
- The Epic's Verification may hold checks of the whole Epic that a person runs, when the source names them.
- This diagram is a rendering of the same `depends_on`/wave data that Step 5 also uses to set native GitHub blocked-by/blocking relations on each child Issue. Both are generated once, from the same approved data, in the same run — the diagram is a human-readable view, not a hand-maintained duplicate that can drift from the real relations after creation.

## Tokens

Do not use any `{{Tn}}` or `{{Tn.m}}` token in a leaf body (a non-container `Tn`, or any `Tn.m`) — leaves name a dependency by its title, never `{{T1}}` or `T1`, and are never rewritten after creation. Only the Epic body (`{{Tn}}` tokens) and a container `Tn`'s own body (`{{Tn.m}}` tokens for its own children only) get a substitution pass, both in Step 5.

## Pre-Creation Checks

Check the generated bodies mechanically, by re-reading each one against every check below, since no tool but `gh` is allowed; there is no need to show them to the user unless a check fails:

- Every leaf Issue's (non-container `Tn`, or any `Tn.m`) Requirements / Specs / Verification bullet lists stay within the 5-item cap. The three Step 2 options — split (default), compress (rejected), point (doc-owned) — agree here: an Issue using point still passes this check, because the pointer is a prose line after the bullets, not a bullet, so the Verification list stays at 5 items.
- Every leaf Issue's Verification is one list with no subheading, and no item of it needs a person, another machine, a real device, or an environment.
- Every person Issue has the template's Background, What to do, and Dependencies sections only, no `{{...}}` token, and names each `Tn` it waits for by title.
- No Mermaid node label (Step 3 preview, Epic body, or a container `Tn` body) contains a raw `"` — a title with a quote must use `#quot;` instead.
- Leaf bodies and person Issue bodies never contain a `{{Tn}}` or `{{Tn.m}}` token — that substitution syntax is container-body-only (the Epic for its `Tn` tokens, a container `Tn` for its own `Tn.m` tokens).
- Collect every `{{Tn}}` token appearing anywhere in the Epic body (diagram/table node labels, dependency-column references, prose) and confirm that set of ids exactly matches the set of `Tn` (leaf and container alike) about to be created — none missing, none referring to a `Tn` that doesn't exist. Separately, for each container `Tn`, collect every `{{Tn.m}}` token in its own body and confirm that set exactly matches the set of its own `Tn.m` grandchildren — none missing, none referring to a different container's child. A given id may legitimately appear more than once within its own scope (e.g. once as its own row, again in another row's dependency column), so check set membership, not occurrence count.
