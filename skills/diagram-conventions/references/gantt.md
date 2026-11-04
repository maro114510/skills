# Gantt Chart

No standard defines Gantt chart notation, so every rule ends with `[Convention]`: common practice adopted here.
A review finding's principle is the heading of the section that holds the rule it breaks, and the finding quotes that rule and the source. Correctness is judged against the source, Conformance against the diagram as drawn. A defect no rule here covers is filed under the SKILL.md principle it breaks.

## Purpose

A Gantt chart shows one schedule: each task as a bar on a calendar axis from its start to its end, and each milestone as an instant.
Choose it when the reader must see when each task happens, how long it lasts, and which tasks overlap.
It does not show the steps inside a task, the conditions a plan branches on, or why one task waits for another.

Choose another type when the reader must understand something else:

- The steps, branches, and loops of one procedure, or tasks with an order but no dates or durations: flowchart
- Dated events or periods in order, with no durations to compare: timeline
- Messages between participants over time: sequence diagram
- The states of one thing and the events between them: state diagram

## Correctness

- Draw a task or milestone only for one the source names. A phase or team the source uses only to group tasks is a section, never a task. When the source also states a phase's own start and end or duration, draw the phase as a section and as a task at the top of it, because a section carries no dates. `[Convention]`
- Take every start, end, and duration from the source. Never derive one from a typical length, from today's date, or from the order the source lists tasks in. `[Convention]`
- Give every task an explicit start: a date the source states, or `after <id>` for a predecessor the source states. A task written with only an end or a duration starts where the line above it ends, which states a sequence the source may not. `[Convention]`
- When the source states a task but not its start, or not its end or duration, ask for the missing value before drawing; Mermaid has no bar without both. Never draw the task as a milestone and never drop it. The same holds when the source gives the plan no calendar date at all. `[Convention]`
- Use `after` only for a dependency the source states as finish-to-start, such as "after X" or "once X is done". For another kind, such as "starts with X", draw the dates the source states and list the dependency as not drawn. `[Convention]`
- Draw a milestone only for an instant the source names, such as a deadline or a release. `[Convention]`
- Tag `done` or `active` only for progress the source states, and `crit` only for a task the source calls critical; never compute a critical path. `[Convention]`
- Use `excludes` only for non-working days the source states, such as "business days" or a named holiday. When the source does not say whether a duration counts working or calendar days, count calendar days and list that as an assumption. `excludes` skips its days in every duration in the chart, so when some durations count working days and others calendar days, ask how to draw them before drawing; never convert one kind into the other. `[Convention]`
- Declare `todayMarker off` unless the source asks for progress as of today, because the marker is a date the source does not state and it moves with each render. `[Convention]`

## Conformance

| Element | Meaning | Mermaid |
|---|---|---|
| Task | Work over a span, one bar from its start to its end | `<name> :<id>, <start>, <end or duration>` |
| Milestone | An instant, with no duration | `<name> :milestone, <id>, <date>, 0d` |
| Section | A group of tasks the source names | `section <name>` |
| Finish-to-start dependency | The task starts when every listed task ends | `after <id> [<id>...]` as the start |
| Run until | The task ends when another task starts | `until <id>` as the end |
| Status | Finished or in progress | `done` or `active`, first in the metadata |
| Critical | A task the source calls critical | `crit`, first in the metadata |
| Non-working days | Days a duration skips | `excludes weekends` or `excludes <date>` |

- Use each element only for its meaning. A milestone takes `0d`, because Mermaid centers a milestone in its duration. `[Convention]`
- Declare `dateFormat YYYY-MM-DD` and write each date the source states in that form, keeping its value. A chart takes one date form, and Mermaid separates task metadata with commas, so a source form such as `March 2, 2026` does not parse. `[Convention]`
- Mermaid draws no dependency line: `after` and `until` only place a bar against another. Name this substitute in the output and claim no conformance for the dependency. `until` needs Mermaid 10.9 or later; say so when used. `[Convention]`

## Clarity

- Order sections and the tasks in each as the source lists them. `[Convention]`
- Label each task with the source's term, as briefly as possible. `[Convention]`
- Set `axisFormat`, and `tickInterval` when the default is denser, to the unit the source plans in, such as days, weeks, or months. `[Convention]`

## Validation

- Every task, milestone, and section maps to the source, and every start, end, and duration is stated in it
- Every task has an explicit start, and every `after` is a finish-to-start dependency the source states
- Every phase with stated dates is drawn as a task as well as a section
- Every `done`, `active`, `crit`, and `excludes` is stated, no `excludes` appears when durations mix working and calendar days, `todayMarker` is `off` unless progress as of today was asked, and every milestone is `0d`
- `dateFormat` is `YYYY-MM-DD`, and every date keeps the value the source states
- The output names dependencies as bar positions only and claims no conformance for them
