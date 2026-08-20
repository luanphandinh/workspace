---
name: "local-tech-design"
description: "Create a compact, evidence-backed technical design for a local multi-repo workspace, with diagrams, implementation artifacts, and protected remote synchronization."
---

# Local Tech Design

Read [../local-technical-writing/SKILL.md](../local-technical-writing/SKILL.md) and [../local-technical-writing/references/mermaid-diagrams.md](../local-technical-writing/references/mermaid-diagrams.md) before drafting.

## Workspace

Every design lives under `<root>/local_workspaces/<workspace>/tech_doc/`.

1. Resolve the workspace name from context. Ask only when it is unknown.
2. If missing, use `local-workspace` to run `mkws --name <workspace>`. Do not attach repositories or choose a branch during design.
3. Store the design as `<name>.md` and the confirmed service mapping as `<name>_mapping.md`.
4. Save continuously. Commit meaningful local design milestones. Do not push or sync without a current-turn request.

The mapping file has two columns only: service/component name and root repository folder. Plans belong under the workspace `implementation_plan/` folder, not `tech_doc/`.

## Evidence

Use `local-code-explore` before drafting architecture or service changes.

- Inspect root repositories, excluding `local_workspaces/` and other worktree copies.
- Use `_external/` only for required read-only contract context. Never add it to the implementation mapping.
- Trace entrypoints, callers, downstream calls, storage, cache, and message edges with `path:line` evidence.
- Ask the user to confirm the repository mapping before treating it as implementation scope.

For two or more independent repositories, explore them concurrently when sub-agent tooling is available. Merge the results into one graph and one mapping.

## Draft

Read [references/document-contract.md](references/document-contract.md). Use its eight-section skeleton, but remove optional content that adds no information.

- Lead with models, examples, diagrams, and diffs. Prose fills only gaps between those artifacts.
- Use short bullets by default. Number only rollout or migration steps whose order changes the result.
- In Overview & Background, label the result `Target` or `Expected outcome`. Never use `Success`.
- Put a decision in the document only when it changes architecture, contracts, ownership, reliability, or rollout risk.
- Never invent alternatives. Ask only about unresolved choices that block a sound design.
- Keep architecture in the overview, trade-offs in decisions, external contracts in external design, implementation in folded internal blocks, and production actions in the release checklist.
- Use the codebase's existing design and implementation patterns. Apply the `local-coding` minimum-solution and new-code gates to every proposed change.

## Revision loop

- Present the diagram and unresolved decisions first.
- Revise only sections whose facts changed.
- Remove resolved decision rows rather than preserving decision history.
- Re-run exploration when a revision changes an edge, owner, or contract.
- Run the compactness gate in the document contract before presenting the draft.

## Remote sync

Remote writes are never automatic. When the user explicitly requests a sync in the current turn, read [references/remote-sync.md](references/remote-sync.md) before any remote operation.
