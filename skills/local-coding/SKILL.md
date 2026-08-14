---
name: "local-coding"
description: "Implement a user-requested change or approved design in a local repository or multi-repo workspace with the smallest correct diff and focused verification."
---

# Local Coding

Read [../local-technical-writing/SKILL.md](../local-technical-writing/SKILL.md) for plans, progress notes, and final output.

## Minimum solution ladder

Understand the real flow first. Then stop at the first solution that holds:

1. The requested behavior already exists: configure or expose it.
2. The codebase has a helper, type, pattern, or boundary that owns it: reuse or fix it there.
3. The standard library or native platform supports it: use that.
4. An installed dependency supports it: use that.
5. A narrow direct change is enough: make it in place.
6. Only then add the minimum new code.

Do not add speculative abstractions, compatibility layers, dependencies, configuration, or files. A new helper/type/file is justified only by a cohesive required responsibility, two current call sites, an import-cycle break, or existing public compatibility.

## Workflow

1. Read repository instructions, status, relevant code, and callers before editing.
2. Find the owning layer and root cause. Fix shared behavior once rather than patching named symptoms separately.
3. Plan only when the work is cross-repository, risky, or genuinely multi-step. Save required plans under the workspace `implementation_plan/` folder.
4. Edit the fewest files. Preserve local patterns and unrelated user changes.
5. Run the smallest check that proves the changed behavior, then broaden according to risk.
6. Inspect `git diff --name-only`, `git diff --stat`, and every added symbol before finishing. Remove anything the direct solution does not need.

## Guardrails

- Keep validation at trust boundaries, data-loss prevention, error handling, security, accessibility, and explicit compatibility requirements.
- Prefer guard clauses and early returns over wrapping existing flows in deeper branches.
- Keep protocol/schema changes at the boundary and domain behavior in its existing owning layer.
- Do not copy logic to avoid a dependency problem; move shared logic to the lowest existing neutral layer when reuse is real.
- Test observable behavior and relevant edge cases, not implementation shape.

## Comments

Default to no comment. Add one short comment only for a non-obvious invariant, ordering requirement, external constraint, or workaround. Never restate names or control flow.

## Multi-repo workspaces

For work based on a workspace tech design, read [references/workspace.md](references/workspace.md) before editing. Repositories under `_external/` are read-only context.

When two or more repositories changed, verify them concurrently with one concise result per repository when sub-agent tooling is available. Keep raw logs out of the main response.

## Final response

State the workspace once when applicable. Then report only:

- changed behavior and key files;
- checks run and result;
- a remaining risk or skipped work only when it matters.
