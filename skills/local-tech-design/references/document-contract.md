# Technical Design Contract

Use a user-supplied tech doc, template, or example as the primary style reference. Preserve its useful structure, ordering, density, and artifact style. This contract fills gaps in correctness, clarity, and safe synchronization; it does not override an explicit user example merely to impose the default layout.

Start with a standalone `[toc]` line followed by a blank line. The marker drives local preview navigation. When no user reference exists, use relevant numbered H1 sections below in standard order. Omit empty sections; retain standard numbers for included sections.

When no user reference exists, use the complete [small-change example](examples/hide-address.md) or [multi-step example](examples/shared-collections.md) as the writing reference. Keep the same directness as complexity grows; grow only the contracts, affected services, failure handling, and rollout dependencies that actually change. Their domains and code paths are fictional, not implementation defaults.

## Section ownership

| Section | Content |
| --- | --- |
| 1. Overview & Background | Problem, trigger, target or expected outcome |
| 2. Links | URLs only |
| 3. Solution Overview | Selected model and end-to-end flow |
| 4. Design Decisions | Critical chosen decisions and unresolved high-impact choices |
| 5. External Technical Design | External contract changes |
| 6. Internal Technical Design | Per-service implementation |
| 7. Rollout Plan | Sequencing and exposure gates |
| 8. Release Checklist | Production actions |

One fact belongs to one section. Initial draft contains minimum facts needed to implement, release, and verify requested change.

## Bullet-point prose

- All explanatory prose uses bullets, including rationale and notes inside `<details>` blocks. No standalone paragraphs.
- Group related logic in 2–4 levels as needed: component → method → condition → outcome. Each level names a real grouping.
- Keep independent facts as flat bullets. Keep headings, tables, Mermaid diagrams, and code outside lists. Use numbered lists only for ordered rollout or migration steps.
- Use natural sentence order for descriptive bullets. Ordered actions and checklists start with imperative verbs.
- Remove filler articles and connectives when meaning stays clear.
- Never write `The config ... below`, `This section describes`, `we will`, `in order to`, `after that`, or `then`. Use heading, identifier, direct action, or numbered step.

## Cross-service call naming

- Across prose, logic, tables, diagrams, sequences, and call chains, write every cross-service call as `<target-service>.<MethodName>`.
- Resolve `<target-service>` from verified service-to-repository mapping or service identity. Use one established abbreviation throughout; an unambiguous repository-folder name is acceptable. Never use a bare method or generated service-interface name when an established short name exists.
- Keep local calls as their exact unprefixed symbols. Write asynchronous edges as `PRODUCE <message-name>` or `CONSUME <message-name>`.
- Preserve source identifiers inside code and diff blocks, including generated client package names.
- Before finalizing, audit every cross-service call for a verified, consistent target-service prefix.

## 1. Overview & Background

At most three short bullets: problem, trigger, target. Skip missing items. No system history.

## 2. Links

Include available URLs only. Omit empty labels and omit section when no URL exists.

```text
- Requirement: <url>
- Monitoring: <url>
```

Repository mapping and code evidence stay in `<name>_mapping.md`.

## 3. Solution Overview

Use only the subsections that carry information:

- `## 3.1 Main changes`: required when multiple components or user-visible results are affected.
- `## 3.2 Model delta`: current/future table or data example. No prose recap.
- `## 3.3 Architecture flowchart`: Mermaid flowchart. Diagram only.
- `## 3.4 Cross-service sequence`: one Mermaid sequence per non-trivial flow. Use short H3 names only when there are multiple diagrams.

In `Main changes`:

- Use one short bold parent bullet per component or user-visible result: `- **<name>:**`.
- Put shared condition in parent bullet and related operations beneath it. Use deeper grouping when several methods or conditions share one parent.
- Name exact fields, handlers, statuses, templates, tables, and messages. Do not add a prose recap.

Every arrow names the exact RPC method, HTTP method/path, SQL operation/table, cache command/key, or message topic.

## 4. Design Decisions

- Include only choices affecting architecture, contracts, ownership, reliability, or rollout risk.
- Use choice as parent bullet; include at most one reason and one material trade-off.
- Omit section when no consequential choice exists.

## 5. External Technical Design

Omit section when no external contract changes.

Use one H2 per changed API with only changed request/response fields, behavior, and schema diff. For a new API, show complete contract. Do not discuss internal libraries or module versions.

Existing fields without an IDL or schema change are not external design. Do not add request/response tables or per-API `N/A` statements; put changed handling in `Logic change` and implementation in `Code changes`.

## 6. Internal Technical Design

- One H2 per changed service: `## 6.X Service: <name>`.
- Use `### Logic change`, `### Code changes`, and `### Config changes` exactly when applicable. Never nest them under an API section or rename them after an implementation technology.
- Do not add default sections for reliability, behavior coverage, or tests. Do not add mapping or input/output tables that repeat another artifact.
- Add a test section only when the testing method adds information; group by at most five behavior categories and never list individual cases.

Do not repeat architecture, external contracts, or production actions here.

### Logic change

- This is the home for service-level runtime conditions and operations. Use exact events, messages, handlers, fields, statuses, constants, tables, and RPC methods.
- Include replay, retry, duplicate, and failure behavior only when it changes the design.
- Keep unique reliability behavior here, never in a separate section. Never repeat behavior already shown here.

### Code changes

- Include an implementation artifact only when exact shape affects implementation or removes ambiguity. Omit obvious wiring and code that repeats contracts or `Logic change`.
- Put each included artifact in its own closed-by-default `<details>` block. Never add `open`.
- Give each block one `<summary>` named `Code change — <symbol> (<path>)`. Keep supporting text and artifact inside same wrapper:

````markdown
<details>
<summary><strong>Code change — <symbol> (<path>)</strong></summary>

```diff
<implementation diff>
```

</details>
````

- Never use H4-H6 headings for individual code-change artifacts. During revisions, preserve every `<details>` and `<summary>` wrapper; rename only summary text. Compactness cleanup must not flatten or remove required wrappers.
- Keep runtime intent in `Logic change` and implementation detail here. Do not explain behavior already visible in a diff.
- Existing code: show its signature, locating context, `-`/`+` lines, and `...` for omissions.
- New function or schema: show the complete definition; for a new function, add a small caller diff.
- Before presentation, commit, or remote sync, inspect every `### Code changes` section: all direct artifacts are wrapped, each wrapper has one summary, opening and closing counts match, and no `###### Code change` or `###### Code path` heading remains. Any failure blocks completion until corrected. Configuration diffs under `### Config changes` are exempt.

### Config changes

Use this structure for each changed configuration.

#### Subsection heading

- Use one `####` subsection per configuration.
- Use `#### <config_name> (service: <exact_service_name>)`.
- Resolve the service from the code that initializes or reads the configuration. Never infer it; report the service as unresolved when it cannot be verified.

#### Content order

1. Name changed namespace or key once: `Namespace/key: <config_name>.<nested_key>`. For nearby keys, name nearest shared namespace and list keys without values.
2. Add only read/use behavior absent from diff. Do not repeat `Logic change`.
3. Add one concise fenced `diff` block.

#### Configuration diff

- Expand dotted paths into their nested object structure. Never use dotted keys inside a structured configuration diff.
- Include enough unchanged parent, sibling, and array context to locate change.
- Keep unchanged lines unmarked. Prefix only actual additions with `+`, removals with `-`, and replacements with paired `-` and `+` lines.
- Use `...` at omitted boundaries. Never present a partial configuration as a complete replacement.
- Keep unchanged array entries visible when they provide useful context. Compact unchanged or wholly added/removed scalar arrays onto one line when readable; expand partially changed arrays so unchanged entries remain unmarked.
- Keep placeholders consistent between namespace label and diff. Do not repeat runtime behavior in diff.
- Use one short diff per configuration. Exclude unrelated values, inventory tables, and metadata columns for readers, outputs, sub-keys, or owners.

Required form:

````markdown
### Config changes

#### <config_name> (service: <exact_service_name>)

- Namespace/key: `<config_name>.<parent_key>.<child_key>` (`<nested_key>`, `<other_key>`).

```diff
{
  "<parent_key>": {
    "<unchanged_sibling>": true,
    "<unchanged_array>": ["<item-a>", "<item-b>"],
    "<child_key>": {
      "<nested_key>": [
        "<item-a>",
+        "<item-b>"
      ],
+      "<other_key>": "<value>"
    },
    ...
  }
}
```
````

## 7. Rollout Plan

Use shortest ordered list covering deployment order, compatibility gates, exposure gates, and end-to-end verification. One imperative action per step. Omit section when no sequencing or gate exists.

## 8. Release Checklist

Manual production actions absent from Rollout Plan only. Never repeat rollout steps. Write each as `verb + target`:

```text
- [ ] Register <configuration>
- [ ] Publish <template>
- [ ] Set <configuration>.<key> = <value> (prod)
- [ ] Deploy <service-a>
- [ ] Verify <production-constraint>
```

Omit section when no manual production action exists. Exclude implementation requirements, design behavior, tests, reviews, and routine automation.

## Compactness gate

Before every presentation or sync:

- Search for `Data and reliability`, `Behavior coverage`, default `Tests`, repeated mappings, and existing-field API tables. Delete anything already shown by `Logic change`, diagrams, contracts, configuration blocks, or code diffs.
- Move only unique reliability behavior into the relevant `Logic change`; keep exceptional tests grouped by behavior.
- Remove optional headings, tables, alternatives, and examples that add no decision value. Do not explain their removal.
- Keep rollout to sequencing and the release checklist to production actions. Every runtime fact must have one primary home.
- Keep visible non-code prose below 120 source lines.
- Replace every explanatory paragraph with bullets, including notes inside folded blocks. Verify grouped logic uses 2–4 meaningful levels without repeated subject prefixes.
- Delete any line whose removal changes no decision, contract, implementation, rollout order, or verification step.
- Search for filler: `the ... below`, `this section`, `we will`, `in order to`, `after that`, `then`. Rewrite as direct statements or ordered actions.
- Check that sections own distinct facts and that every proposed new symbol passes the `local-coding` minimum-solution gate.
