---
name: "local-technical-writing"
description: "Use with local code exploration, technical design, coding plans, and implementation reports to express complete technical meaning with the least necessary prose and reusable diagrams."
---

# Minimum Sufficient Technical Writing

Compress the output, not the investigation. Read and verify the full flow first.

## Compression ladder

Stop at the first form that carries the fact:

1. Omit it if the reader does not need it.
2. Do not repeat it if a table, diagram, schema, code block, or other artifact already shows it.
3. Use an identifier, data example, code block, table, or diagram.
4. Use one short bullet.
5. Use a paragraph only for rationale that cannot be encoded above.

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
- Use concrete identifiers. Do not translate self-evident names into prose.
- Use short bullets by default, especially for implementation actions, checks, and conditions.
- Use numbering only when execution order changes the result, such as rollout or migration sequencing.
- Keep one idea per bullet. Split compound sentences into separate bullets. Do not use prose semicolons.
- Keep at most three visible bullets per subsection.
- Keep visible paragraphs under three source lines.
- Shorten table cells and diagram labels. Remove optional content that adds no information.
- Preserve validation, failure behavior, security, compatibility, and explicit requirements. Brevity never removes correctness.
- End with only unresolved questions, evidence, or verification that changes a decision.

## Diagrams

Normalize findings into nodes and labeled edges before drawing. The diagram is the flow source of truth. Text below it contains evidence or exceptions only.

- Terminal exploration: read [references/terminal-diagrams.md](references/terminal-diagrams.md).
- Technical documents: read [references/mermaid-diagrams.md](references/mermaid-diagrams.md).

When both forms exist, derive them from the same graph and update them together.
