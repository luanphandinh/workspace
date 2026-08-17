# Workspace Coding

## Resolve the workspace

- Coding happens in `<root>/local_workspaces/<workspace>/`, never in sibling root checkouts.
- Use the workspace created during technical design. Ask for its name only when it cannot be resolved from the current path or provided artifacts.
- Read `tech_doc/<name>.md`, `tech_doc/<name>_mapping.md`, `workspace.yml`, and relevant files under `implementation_plan/`.
- Ignore mapping entries under `<root>/_external/`; those repositories are read-only contract context.

## Attach implementation repositories

Use `local-workspace` and `mkws`; do not recreate worktree logic here.

- Empty workspace with no branch: obtain the feature branch, then attach mapped repositories with `mkws --branch <branch> --add <repo...>`.
- Existing branch and worktrees: compare them with the mapping and attach only missing repositories using `mkws --add <repo...>`.
- Missing workspace: surface the mismatch before creating or editing implementation worktrees.

Run every edit, build, test, and commit from the repository worktree under the workspace. Do not create `go.work`; each module uses its own dependency graph.

## Planning artifacts

Create files under `implementation_plan/` only when a persistent plan or execution record is useful. Keep design and mapping files under `tech_doc/`.

Suggested names:

- `<topic>_plan.md`
- `<topic>_tasks.md`
- `<topic>_execution.md`

Keep plans task-shaped: repository, file/symbol, behavior, check. Do not restate the technical design.

## Reporting paths

State once: `Code changes are applied in workspace folder: <workspace>`.

After that, use workspace-relative paths: `<repo>/<path>`. Absolute paths are for tool calls and sub-agent prompts only.
