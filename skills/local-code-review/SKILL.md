---
name: "local-code-review"
description: "Use when reviewing code changes inside a local multi-repo git-worktree workspace, especially after local-coding implementation, to find bugs and explain changed cross-service flow."
---

# Local Code Review

## Review stance
- Prioritize bugs, regressions, unsafe behavior, missing tests, rollout risks, and mismatches with the tech doc or implementation plan.
- Findings first, ordered by severity. Use exact file:line references.
- Keep summaries short. Do not praise code. Do not rewrite the implementation unless the user asks.
- Output in chat by default. Do not create files unless the user asks.

## Workspace scope
- Review inside a `mkws` workspace at `<root>/local_workspaces/<workspace-name>/`.
- Ask for the workspace name/path if unclear.
- Read `<workspace>/workspace.yml` first. Review only repos listed under `repos:` and present as worktrees under `<workspace>/<repo>/`.
- Read context, when present:
  - `<workspace>/tech_doc/` for design and mapping inputs.
  - `<workspace>/implementation_plan/` for plans, task records, execution notes, and sub-agent summaries.
- Never review or edit original sibling source repos outside the workspace.
- Use each repo's own git worktree state. Run git commands from `<workspace>/<repo>/`.

## User-facing path format
- In review output, state the workspace once: `Code changes are applied in workspace folder: <workspace>`.
- After that line, reference code files relative to the workspace, starting with the repo folder: `<repo-name>/<path-to-file>:<line>`.
- Do NOT repeat the full `<root>/local_workspaces/<workspace-name>/...` prefix for every finding, evidence entry, or changed file.
- Absolute paths are still allowed in commands while inspecting; convert them back to workspace-relative paths before reporting to the user.

## Change discovery
For each repo listed in `workspace.yml`:
1. Run `git status --short --branch --untracked-files=all`.
2. Detect the comparison base:
   - Prefer upstream of the current branch if present.
   - Else use `origin/master`, then `origin/main`, then local `master`, then local `main`.
3. Inspect:
   - `git diff --stat <base>...HEAD`
   - `git diff --name-status <base>...HEAD`
   - `git diff <base>...HEAD -- <changed files>`
   - Include unstaged/staged working tree diff if present.
4. For untracked files, read only files likely relevant to the change. Do not bulk-read generated output.
5. If the workspace has no branch or no repos, report that clearly and stop.

## What to review
- Correctness: wrong condition, missing branch, bad default, bad error handling, nil/empty handling, ordering bugs, transaction boundaries, idempotency, retries, concurrency, context cancellation.
- Compatibility: request/response schema, IDL/API changes, database migrations, message format, config defaults, feature gates, backward compatibility.
- Cross-service behavior: RPC/HTTP/MQ edges added, removed, or changed; producer/consumer mismatch; missing timeout; missing fallback.
- Tests: changed logic without focused unit/integration tests, tests that assert implementation details but miss behavior, missing negative paths.
- Operability: logs, metrics, alarms, migration safety, rollout/rollback.
- Security/privacy only when the diff touches access control, secrets, user data, tokens, signatures, or external input.

## Changed-flow diagram
Always include exactly one merged terminal diagram when the change affects calls, handlers, storage, queues, or important internal logic.

Diagram rules:
- Text/ASCII only. No Mermaid, no external image.
- One merged graph only. Do not create one diagram per repo or service.
- Each service/repo gets its own box.
- Mark changed service boxes, handlers, methods, fields, stores, queues, or edges with `<<< CHANGED`.
- Mark risk hotspots found during review with `<<< REVIEW RISK`.
- Arrows must include protocol + method/path/topic/action.
- If a changed edge cannot be mapped to a repo, include it as `External / not found` in the same diagram.
- Draw visible horizontal connector lines for branches; do not leave detached vertical lines.

Preferred shape:
```
+-------------------------------+
| <service-a>                   |
| repo: <repo-a>                |
| changed: <handler/method>     | <<< CHANGED
+-------------------------------+
              |
              | RPC: <MethodName> <<< CHANGED
              v
+-------------------------------+
| <service-b>                   |
| repo: <repo-b>                |
| changed: <field/logic/store>  | <<< CHANGED
| risk: <short risk>            | <<< REVIEW RISK
+-------------------------------+
              |
              +-----------------------------+
              |                             |
              | MQ: <topic-name> <<< CHANGED| SQL: UPDATE <table>
              v                             v
+-------------------------------+  +-------------------------------+
| <service-c>                   |  | <store-name>                  |
| repo: <repo-c>                |  | repo: <repo-b>                |
| changed: consumer logic       |  | changed: write path           |
+-------------------------------+  +-------------------------------+
```

If the change is purely local and has no cross-service flow, still include a compact one-box diagram:
```
+-------------------------------+
| <repo-a>                      |
| changed: <function/file>      | <<< CHANGED
| risk: <short risk or none>    |
+-------------------------------+
```

## Output format
Use this order:
1. **Findings** — severity, file:line, concrete bug/risk, why it matters, suggested fix direction.
2. **Changed Flow** — the single merged terminal diagram.
3. **Evidence Map** — changed edges or logic entries with file:line references, ordered to match the diagram.
4. **Test Gaps** — missing or weak tests tied to specific changed behavior.
5. **Open Questions** — only blockers that affect review confidence.

If no issues are found, say so clearly, then still include Changed Flow, Evidence Map, and residual test/risk notes.
