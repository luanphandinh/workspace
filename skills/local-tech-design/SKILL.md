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
- Include a one-level-grouped repository in implementation mapping only when the user confirms it as implementation scope; folder names do not imply read-only ownership.
- Trace entrypoints, callers, downstream calls, storage, cache, and message edges with `path:line` evidence.
- Ask the user to confirm the repository mapping before treating it as implementation scope.

For two or more independent repositories, explore them concurrently when sub-agent tooling is available. Merge the results into one graph and one mapping.

## Draft

Read [references/document-contract.md](references/document-contract.md).

When the user supplies a tech doc, template, or example, treat it as the primary style reference. Preserve its useful structure, ordering, density, and artifact style. Apply the document contract for requirements the supplied reference does not define, without normalizing the document back to the default template.

When the user supplies no reference, use the contract's standard section order and omit sections that add no information.

When the user supplies no primary reference, read the closest complete example:

- [Small change: hide an address](references/examples/hide-address.md) for one setting, handler, or output change.
- [Multi-step change: shared collections](references/examples/shared-collections.md) for several APIs, access states, transactions, retries, or asynchronous work.

Match their directness, not their fictional APIs or architecture. Each fact has one home; add detail only for a changed contract, meaningful failure, or deployment dependency. Examples are invented teaching material, never evidence for a real repository. Do not invent facts in a real design unless the user explicitly requests a hypothetical example.

- Initial draft is the minimum implementable design. Include only changed contracts, changed runtime behavior, required implementation artifacts, real decisions, rollout dependencies, and production actions.
- Omit empty sections. Never add `N/A`, background history, unchanged behavior, future options, or explanatory setup text.
- Lead with models, examples, diagrams, and diffs. All explanatory prose uses bullets, including rationale and notes inside folded code blocks; no standalone paragraphs.
- Group logic in 2–4 levels when needed: component → method → condition → outcome. Each level names a real grouping; do not flatten related operations into repeated sibling lines.
- Use natural sentence order for descriptive bullets. Rollout and checklist steps start with imperative verbs.
- When using the default skeleton, keep standard section numbers for included sections. Do not create missing sections solely to preserve numbering.
- In Overview & Background, label the result `Target` or `Expected outcome`. Never use `Success`.
- Include only decisions that change architecture, contracts, ownership, reliability, or rollout risk. Use one reason and one material trade-off at most.
- Never invent alternatives. Ask only about unresolved choices that block a sound design.
- Document only the requested change and its necessary consequences. Do not add optional decisions, adjacent behavior, or correction history.
- Keep architecture in the overview, trade-offs in decisions, external contracts in external design, implementation in internal design artifacts, and production actions in the release checklist.
- Use the codebase's existing design and implementation patterns. Apply the `local-coding` minimum-solution and new-code gates to every proposed change.

## Revision loop

- Present the diagram and unresolved decisions first.
- Revise only sections whose facts changed. Delete stale, duplicate, and resolved content instead of preserving history.
- Re-run exploration when a revision changes an edge, owner, or contract.
- Run the compactness gate in the document contract before presenting the draft.

## Remote sync

Remote writes are never automatic. When the user explicitly requests a sync in the current turn, read [references/remote-sync.md](references/remote-sync.md) before any remote operation.
