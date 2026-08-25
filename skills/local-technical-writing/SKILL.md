---
name: "local-technical-writing"
description: "Use with local code exploration, technical design, coding plans, and implementation reports to express complete technical meaning with the least necessary prose and reusable diagrams."
---

# Minimum Sufficient Technical Writing

Investigate fully. Write only what the reader needs.

## Minimum form

Stop at the first form that carries the fact:

1. Omit it if the reader does not need it.
2. Do not repeat it if a table, diagram, schema, code block, or other artifact already shows it.
3. Prefer an exact identifier or artifact over prose.
4. Use a short bullet; use a paragraph only for necessary rationale.

One fact has one home. Never add a prose recap after a clear artifact.

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

## Writing rules

- Start with the useful artifact. No preamble or process narration.
- Use short bullets by default. Number only steps whose order changes the result.
- Put a shared condition in a parent bullet and one operation in each child bullet. Never print `Condition:` or `Action:` labels.
- Split compound operations. Do not use prose semicolons, vague section references, or labels invented to explain structure.
- Keep at most three summary bullets per subsection.
- Keep visible paragraphs under three source lines.
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
- Treat the rejected content as never proposed. Restore the last approved state, then apply only the requested change.
- Keep a negative constraint only when the user requested it or the verified final design requires it.
- If text would not exist without the rejected content, delete it.

## Diagrams

Normalize findings into nodes and labeled edges before drawing. The diagram is the flow source of truth. Text below it contains evidence or exceptions only.

- Terminal exploration: read [references/terminal-diagrams.md](references/terminal-diagrams.md).
- Technical documents: read [references/mermaid-diagrams.md](references/mermaid-diagrams.md).

When both forms exist, derive them from the same graph and update them together.
