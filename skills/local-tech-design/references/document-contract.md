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

## Cross-service call naming

- Across prose, logic, tables, diagrams, sequences, and call chains, write every cross-service call as `<target-service>.<MethodName>`.
- Resolve `<target-service>` from verified service-to-repository mapping or service identity. Use one established abbreviation throughout; an unambiguous repository-folder name is acceptable. Never use a bare method or generated service-interface name when an established short name exists.
- Keep local calls as their exact unprefixed symbols. Write asynchronous edges as `PRODUCE <message-name>` or `CONSUME <message-name>`.
- Preserve source identifiers inside code and diff blocks, including generated client package names.
- Before finalizing, audit every cross-service call for a verified, consistent target-service prefix.

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

- `## 3.1 Main changes`: required when multiple components or user-visible results are affected.
- `## 3.2 Model delta`: current/future table or data example. No prose recap.
- `## 3.3 Architecture flowchart`: Mermaid flowchart. Diagram only.
- `## 3.4 Cross-service sequence`: one Mermaid sequence per non-trivial flow. Use short H3 names only when there are multiple diagrams.

In `Main changes`:

- Use one short bold parent bullet per component or user-visible result: `- **<name>:**`.
- Put a shared condition in the parent bullet and each resulting operation in its own child bullet.
- Name exact fields, handlers, statuses, templates, tables, and messages. Do not add a prose recap.

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

- Put every implementation artifact in its own closed-by-default `<details>` block, including diffs, code, schemas, request-field tables, and code-path tables. Never add `open`.
- Every block has exactly one `<summary>` named `Code change — <symbol> (<path>)`. Keep its supporting text and artifact inside the same wrapper:

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

Apply this structure to every changed configuration.

#### Subsection heading

- Use one `####` subsection per configuration.
- Use `#### <config_name> (service: <exact_service_name>)`.
- Resolve the service from the code that initializes or reads the configuration. Never infer it; report the service as unresolved when it cannot be verified.

#### Content order

1. List each changed value as `<config_name>.<nested_key> = <value>`, including the complete dotted path.
2. Describe only the configuration-specific read/use behavior needed to connect the path to exact handlers and outputs. Do not repeat it in `Logic change`.
3. Add one fenced `diff` block containing the actual configuration change immediately after the runtime behavior.

#### Configuration diff

- Expand dotted paths into their full nested JSON object structure. Never use dotted keys inside the JSON diff.
- Include only changed keys and the complete parent object hierarchy needed to locate them.
- Prefix additions with `+`; use `-` and `+` for replacements; include deletions only when the design removes configuration.
- Keep placeholders identical to the dotted assignments. Do not repeat runtime behavior in the diff.
- Use one short diff per configuration. Exclude unrelated values, inventory tables, and metadata columns for readers, outputs, sub-keys, or owners.

Required form:

````markdown
### Config changes

#### <config_name> (service: <exact_service_name>)

- `<config_name>.<parent_key>.<child_key>.<nested_key> = <value>`
- When `<verified_condition>`:
  - `<exact_handler>` reads `<config_name>.<parent_key>.<child_key>.<nested_key>`.
  - `<exact_handler>` sets `<exact_output_field>`.

```diff
{
+  "<parent_key>": {
+    "<child_key>": {
+      "<nested_key>": "<value>"
+    }
+  }
}
```
````

## 7. Rollout Plan

At most four ordered steps covering only deployment order, compatibility gates, exposure gates, and end-to-end verification order. Do not repeat configuration values or expected outputs. Use `N/A — direct rollout.` when staging adds no value.

## 8. Release Checklist

Production actions only: register configuration, publish templates, set values, deploy services, and verify production constraints. Write each as `verb + target`:

```text
- [ ] Register <configuration>
- [ ] Publish <template>
- [ ] Set <configuration>.<key> = <value> (prod)
- [ ] Deploy <service-a>
- [ ] Verify <production-constraint>
```

No implementation requirements, design behavior, tests, reviews, or ordinary CI/CD steps.

## Compactness gate

Before every presentation or sync:

- Search for `Data and reliability`, `Behavior coverage`, default `Tests`, repeated mappings, and existing-field API tables. Delete anything already shown by `Logic change`, diagrams, contracts, configuration blocks, or code diffs.
- Move only unique reliability behavior into the relevant `Logic change`; keep exceptional tests grouped by behavior.
- Remove optional headings, tables, alternatives, and examples that add no decision value. Do not explain their removal.
- Keep rollout to sequencing and the release checklist to production actions. Every runtime fact must have one primary home.
- Keep visible non-code prose below 200 source lines.
- Replace every visible paragraph over three lines with a shorter artifact or bullet.
- Check that sections own distinct facts and that every proposed new symbol passes the `local-coding` minimum-solution gate.
