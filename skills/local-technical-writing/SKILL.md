---
name: "local-technical-writing"
description: "Use in addition to local-writing when creating or substantially revising technical documents that require local Markdown conventions, contextual diffs, or Mermaid diagrams."
---

# Technical Document Writing

Read [../local-writing/SKILL.md](../local-writing/SKILL.md) first. This skill adds document-specific rules only.

When the user supplies a tech doc, template, or example, use it as the primary style reference. Preserve its useful structure, ordering, density, and artifact style; use this skill to fill gaps rather than replace that style with a default format.

Initial drafts use the smallest form that supports implementation. Add detail only after evidence, risk, or user feedback requires it.

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

## Document rules

- Every generated or substantially revised technical document must start with a standalone `[toc]` line, followed by a blank line before the first heading. If YAML frontmatter exists, put marker immediately after it. Keep marker outside code fences, lists, and folded blocks. Do not duplicate it with a manually maintained contents list.
- Explanatory prose is strictly bullet-pointed, including rationale and notes inside folded blocks. Tables, diagrams, code, and headings remain artifacts, not list items.
- Use 2–4 list levels as logic requires: component → method → condition → outcome. Keep independent facts flat. Number only rollout or migration steps whose order matters.
- Do not use prose semicolons, vague section references, or labels invented to explain structure.
- Keep at most three summary bullets per subsection.
- Shorten table cells and diagram labels. Remove optional content and repeated mappings.
- End with only unresolved questions, evidence, or verification that changes a decision.

## Diagrams

Normalize findings into nodes and labeled edges before drawing. The diagram is the flow source of truth. Text below it contains evidence or exceptions only.

- Technical documents: read [references/mermaid-diagrams.md](references/mermaid-diagrams.md).

When both forms exist, derive them from the same graph and update them together.
