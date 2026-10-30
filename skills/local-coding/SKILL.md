---
name: "local-coding"
description: "Implement a user-requested change or approved design in a local repository or multi-repo workspace with the smallest correct diff and focused verification."
---

# Local Coding

Read [../local-writing/SKILL.md](../local-writing/SKILL.md) for plans, progress notes, and final output.

## Minimum solution ladder

Understand real flow. Stop at first valid solution:

1. Requested behavior exists: configure or expose it.
2. Existing helper, type, pattern, or boundary owns it: reuse or fix it.
3. Standard library or native platform supports it: use it.
4. Installed dependency supports it: use it.
5. Narrow direct change works: edit in place.
6. Add minimum new code.

Do not add speculative abstractions, compatibility layers, dependencies, configuration, or files. A new helper/type/file is justified only by a cohesive required responsibility, two current call sites, an import-cycle break, or existing public compatibility.

## Workflow

1. Read repository instructions, status, relevant code, and callers before editing.
2. Find the owning layer and root cause. Fix shared behavior once rather than patching named symptoms separately.
3. Plan only for cross-repository, risky, or genuinely multi-step work. Save required plans under workspace `implementation_plan/`.
4. Edit the fewest files. Preserve local patterns and unrelated user changes.
5. Run smallest check proving changed behavior. Broaden only when risk requires it.
6. Inspect `git diff --name-only`, `git diff --stat`, and every added symbol before finishing. Remove anything the direct solution does not need.

Plans use terse task lines: `<repo>/<path>: <change>; check: <command or behavior>`. Omit introductions, recaps, unchanged behavior, and speculative follow-ups.

## Guardrails

- Keep validation at trust boundaries, data-loss prevention, error handling, security, accessibility, and explicit compatibility requirements.
- Prefer guard clauses and early returns over wrapping existing flows in deeper branches.
- Keep protocol/schema changes at the boundary and domain behavior in its existing owning layer.
- Do not copy logic to avoid a dependency problem; move shared logic to the lowest existing neutral layer when reuse is real.
- Test observable behavior and relevant edge cases, not implementation shape.

## Comments

Default to no comment. Add one short comment only for a non-obvious invariant, ordering requirement, external constraint, or workaround. Never restate names or control flow.

## Wrapped parameters

- Keep a function or method signature on one line when it fits.
- Once its parameter list wraps, put every parameter on its own line and the closing delimiter on its own line. Never place multiple parameters on one wrapped line.
- Preserve separators required by the language and run the repository formatter.

## Multi-repo workspaces

For work based on a workspace tech design, read [references/workspace.md](references/workspace.md) before editing. Repository paths listed in `workspace.yml` are writable implementation scope regardless of grouping-folder name.

When two or more repositories changed, verify them concurrently with one concise result per repository when sub-agent tooling is available. Keep raw logs out of the main response.

## Final response

State workspace once when applicable. Report only:

- changed behavior and key files;
- checks run and result;
- a remaining risk or skipped work only when it matters.
