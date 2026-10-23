---
name: "local-technical-writing"
description: "Use with local code exploration, technical design, coding plans, and implementation reports to express complete technical meaning with the least necessary prose and reusable diagrams."
---

# Minimum Sufficient Technical Writing

Investigate fully. Write only what the reader needs.

When the user supplies a tech doc, template, or example, use it as the primary style reference. Preserve its useful structure, ordering, density, and artifact style; use this skill to fill gaps rather than replace that style with a default format.

Initial drafts use the smallest form that supports implementation. Add detail only after evidence, risk, or user feedback requires it.

## Minimum form

Stop at the first form that carries the fact:

1. Omit it if the reader does not need it.
2. Do not repeat it if a table, diagram, schema, code block, or other artifact already shows it.
3. Prefer an exact identifier or artifact over prose.
4. Use a short bullet; use a paragraph only for necessary rationale.

For technical design documents, explanatory prose is strictly bullet-pointed, including rationale and notes inside folded blocks. Tables, diagrams, code and headings remain artifacts, not list items.

One fact has one home. Never add a prose recap after a clear artifact.

Delete any line whose removal would not change a decision, contract, implementation, rollout order, or verification step.

## Pick the carrier

| Information | Preferred form |
| --- | --- |
| State or model change | Current/future table or data example |
| Runtime flow | Diagram |
| Contract change | Field or schema diff |
| Implementation | Folded code or diff |
| Evidence | `path:line` |
| Real alternatives | Options, material trade-offs, verdict |
| Production action | Checklist |

Do not use a table for prose or an inventory that does not compare anything.

## Direct wording

- Use natural sentence order. Lead with subject or action based on what makes the point clearest.
- Ordered actions and checklists start with imperative verbs: `Deploy <service-a>`, `Verify <constraint>`.
- Prefer compact wording: `<handler>` locks `<record>`, writes `<member-row>` and `<event-row>` in one transaction.
- Remove articles (`a`, `an`, `the`), pronouns, and connective words when meaning stays clear. Keep them when omission changes meaning or makes wording unnatural.
- Delete filler such as `below`, `above`, `this section`, `we will`, `in order to`, `after that`, and `then`.
- Express sequence with numbered actions. Each step starts with one imperative verb; dependencies appear as short conditions.
- Use a heading or identifier alone when it already names the subject. Never introduce it with `The config ... below is for`, `This section describes`, or equivalent narration.
- Keep tightly coupled operations on one line. Split independent operations into child bullets.
- Use 2–4 list levels when logic needs grouping. Each level must name a real subject, condition, operation, or outcome.

Required rewrites:

```text
The config <config-name> below is for ...
→ <config-name>

We deploy <service-a>, then deploy <service-b>, then check <service-b>.
→ 1. Deploy <service-a>
  2. Deploy <service-b>
  3. Verify <service-b>

<handler> locks the record, then writes the member and event rows in one transaction.
→ <handler> locks <record>, writes <member-row> and <event-row> in one transaction.

```

## Contextual diffs

- Apply the same presentation rule to code, configuration, schemas, structured data, and any other diff: show enough unchanged surrounding structure to locate the change.
- Start from existing artifact. Keep nearest parent, signature, or surrounding entries. Compact unrelated context with `...`.
- Keep unchanged lines unmarked. Mark only actual removals and additions with `-` and `+`.
- Use `...` where omitted context would otherwise make a partial excerpt look like a complete replacement.
- For configuration, name namespace or key once. Show one concise contextual diff. Do not restate changed values as dotted-path bullets before diff.
- Preserve unchanged fields and array entries as context when they help locate or understand the change. Compact unchanged or wholly added/removed scalar arrays onto one line when readable; expand partially changed arrays so unchanged entries remain unmarked.
- Never present a partial configuration, object, or list excerpt as a complete replacement.
- Add a note outside the diff only when it explains behavior that the diff cannot show. Never recap visible changes in prose.

## Writing rules

- Every generated or substantially revised Markdown document must start with a standalone `[toc]` line, followed by a blank line before the first heading. If YAML frontmatter exists, put the marker immediately after it. Keep the marker outside code fences, lists, and folded blocks. This supplies the local browser preview's clickable heading sidebar; do not duplicate it with a manually maintained contents list.
- Start with the useful artifact. No preamble or process narration.
- Use short bullets by default. Number only steps whose order changes the result.
- Put a shared condition or method in a parent bullet and related behavior beneath it. Never print `Condition:` or `Action:` labels.
- In technical designs, use 2–4 list levels as logic requires: component → method → condition → outcome. Keep independent facts flat. Number only rollout or migration steps whose order matters.
- Split unrelated operations. Do not use prose semicolons, vague section references, or labels invented to explain structure.
- Keep at most three summary bullets per subsection.
- In technical designs, replace every standalone explanatory paragraph with bullets. Elsewhere, keep visible paragraphs under three source lines.
- Shorten table cells and diagram labels. Remove optional content and repeated mappings.
- Preserve validation, failure behavior, security, compatibility, and explicit requirements.
- End with only unresolved questions, evidence, or verification that changes a decision.

## Vocabulary fidelity

- Every technical noun must be traceable to the request, code, schema, interface definition, API, message topic, configuration, or established documentation.
- Use exact symbols, handlers, tables, fields, constants, topics, and messages. Never replace them with invented shorthand, aliases, metaphors, or catch-all nouns.
- Describe asynchronous data using its exact source plus `event` or `message`. Pair a numeric value with its verified symbolic name as `value(Name)`.
- A proposed identifier is valid only when it appears in proposed code. Rewrite or delete untraceable vocabulary.

## Final-state corrections

- If the user rejects assistant-added content, remove it and anything that exists only to explain, contrast, undo, or justify it.
- Treat rejected content as never proposed. Restore last approved state; apply only requested change.
- Keep a negative constraint only when the user requested it or the verified final design requires it.
- If text would not exist without the rejected content, delete it.

## Diagrams

Normalize findings into nodes and labeled edges before drawing. The diagram is the flow source of truth. Text below it contains evidence or exceptions only.

- Terminal exploration: read [references/terminal-diagrams.md](references/terminal-diagrams.md).
- Technical documents: read [references/mermaid-diagrams.md](references/mermaid-diagrams.md).

When both forms exist, derive them from the same graph and update them together.
