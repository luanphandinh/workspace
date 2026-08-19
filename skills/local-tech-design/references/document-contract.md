# Technical Design Contract

Start directly at `# 1. Overview & Background`. Use these eight H1 sections in order.

## Section ownership

| Section | Content |
| --- | --- |
| 1. Overview & Background | Problem, trigger, target or expected outcome |
| 2. Links | URLs only |
| 3. Solution Overview | Selected model and end-to-end flow |
| 4. Design Decisions | Unresolved high-impact choices |
| 5. External Technical Design | External contract changes |
| 6. Internal Technical Design | Per-service implementation |
| 7. Rollout Plan | Sequencing and exposure gates |
| 8. Release Checklist | Production actions |

One fact belongs to one section.

## 1. Overview & Background

At most three short bullets: problem, trigger, and `Target` or `Expected outcome`. Never use `Success` as a label. Skip missing items. No system history.

## 2. Links

Links only:

```text
- Tracking ticket:
- Requirement:
- Related changes:
- Monitoring:
- Other:
```

Repository mapping and code evidence stay in `<name>_mapping.md`.

## 3. Solution Overview

Use only the subsections that carry information:

- `## 3.1 Model delta`: current/future table or data example. No prose recap.
- `## 3.2 Architecture flowchart`: Mermaid flowchart. Diagram only.
- `## 3.3 Cross-service sequence`: one Mermaid sequence per non-trivial flow. Use short H3 names only when there are multiple diagrams.

Every arrow names the exact RPC method, HTTP method/path, SQL operation/table, cache command/key, or message topic.

## 4. Design Decisions

Only unresolved choices with at least two viable options and material architectural impact. Zero choices is preferred:

`N/A — no unresolved high-impact architectural choices.`

When needed, use at most four rows:

| **Choice** | **Options / material trade-offs** | **Verdict** |
| --- | --- | --- |
| <choice> | <option A: benefit/cost><br><option B: benefit/cost> | <option or unresolved> |

Use a compact model table or data example above the row only when the data shape itself is the decision. Never add a forced or obvious alternative.

## 5. External Technical Design

If no external contract changes:

`N/A — no external contract change.`

Otherwise, one H2 per changed API with only changed request/response fields, behavior, and schema diff. For a new API, show the complete contract. Do not discuss internal libraries or module versions.

## 6. Internal Technical Design

- One H2 per changed service: `## 6.X Service: <name>`.
- At most three short visible bullets per service.
- Put schema, config, logic, code, and test detail in named `<details>` blocks.
- Add one `Service | Change | Risk` table only when it materially compares at least three services.
- Group tests into at most five behavior categories. Never list individual test cases.

Do not repeat architecture, external contracts, or production actions here.

## 7. Rollout Plan

At most four sequencing, exposure, or decision gates. Use `N/A — direct rollout.` when staging adds no value.

## 8. Release Checklist

Production actions only, written as `verb + target`:

```text
- [ ] Deploy <service-a>
- [ ] Apply migration <migration-a>
- [ ] Update <namespace>/<key> = <value> (prod)
- [ ] Enable <flag> (prod, <percent>)
```

No implementation requirements, tests, reviews, or ordinary CI/CD steps.

## Code artifacts

Wrap diffs and code longer than about ten lines in a named `<details>` block.

- Existing parent: show its signature, only context needed to locate the change, `-`/`+` lines, and `...` for omitted regions.
- Substantial new function: show the complete function in its language, plus a separate small diff for the existing caller.
- New schema/type/table: show the complete definition.
- Names: `Code change — <symbol> (<path>)`, `IDL — <symbol> (<path>)`, `SQL — <name> (<path>)`, or `Config — <key> (<source>)`.

Do not explain code already visible in the block.

## Compactness gate

Before every presentation or sync:

- Remove facts already shown by diagrams, data examples, code, field names, requirements, or another section.
- Remove optional headings, tables, alternatives, and examples that add no decision value.
- Keep visible non-code prose below 200 source lines.
- Replace every visible paragraph over three lines with a shorter artifact or bullet.
- Check that sections own distinct facts and that every proposed new symbol passes the `local-coding` minimum-solution gate.
