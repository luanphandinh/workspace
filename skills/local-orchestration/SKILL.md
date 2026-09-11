---
name: "local-orchestration"
description: "Coordinate technical design, implementation, and independent review across durable Codex or Cursor sessions while routing each phase to an appropriate-cost model."
---

# Local Orchestration

Use this skill for work that spans design, implementation, and review. The parent session owns requirements, decisions, and the final answer.

## Route work

- **Design:** Keep the current parent model. Use `local-tech-design`, which must use `local-code-explore` to establish the real flow before drafting.
- **Exploration:** Delegate only independent, bounded branches. Prefer Codex `gpt-5.6-luna` at `medium` effort in read mode.
- **Implementation:** Use a durable Codex session with `local-coding`. Default to `gpt-5.6-luna` at `medium` effort.
- **Review:** Use one independent reviewer session for both gates. Prefer Cursor `gpt-5.6-terra[context=272k,reasoning=medium,fast=false]`; fall back to Codex `gpt-5.6-terra` at `high` effort.

The user may override any provider, model, or effort. Never silently move design to the cheaper worker.

## Durable workers

Choose a short name from the current thread title or objective. Name workers `[Dev] <thread-name>` and `[Review] <thread-name>`.

Start workers with `agent-session`. It records the running session before starting the turn, waits for completion, then returns `agent`, `session_id`, `name`, `status`, and `result` as JSON.

Every durable worker must use the workspace registry. It groups workers under the main orchestrator, so one workspace can contain multiple independent main agents and their sub-agents.

Registry shape: `workspace -> main_agents[] -> sub_agents[]`. Identify each main agent by runtime and session ID. Never write worker sessions directly at the workspace level.

- Pass `--config <config-name>` and `--main-agent-name <thread-name>`.
- `--main-agent-id` defaults to `CODEX_THREAD_ID` for a Codex orchestrator.
- Other runtimes pass `--main-agent-id` and `--main-agent-type` explicitly.
- Keep the same main-agent identity for every worker delegated by that orchestrator.
- Record native sub-agents under the same main-agent entry before another dependent worker starts.

```bash
agent-session --agent codex --mode write --model gpt-5.6-luna --effort medium \
  --config <config-name> --main-agent-name "<thread-name>" \
  --name "[Dev] <thread-name>" --cwd "<workspace>" \
  --prompt 'Use $local-coding. Implement the approved design and return focused verification.'

agent-session --agent cursor --mode read \
  --model 'gpt-5.6-terra[context=272k,reasoning=medium,fast=false]' \
  --config <config-name> --main-agent-name "<thread-name>" \
  --name "[Review] <thread-name>" \
  --cwd "<workspace>" \
  --prompt 'Review the design against the request and verified code evidence. Report gaps only. Do not edit files.'
```

Continue an orchestrated worker with `agent-session --agent <agent> --session <recorded-session-id> --mode <mode> --config <config-name> --main-agent-id <main-session-id>` and the same main-agent identity, model, effort, and cwd. A second `mcodex resume <session-id>` can live-attach to an active Codex turn, and closing either waiting client leaves that turn running. Resume the coding session for fixes. After implementation, resume the design reviewer with: `Use $local-code-review. Review the code against the approved design. Do not edit files.`

## Control

- Resolve design-review findings before implementation.
- Keep one durable implementation session active. It may delegate disjoint repositories to native sub-agents.
- Assign one writer per repository or non-overlapping path. The coding session owns cross-repository contracts, handoff, and combined verification.
- Give each sub-agent its repository, owned paths, required contract, checks, and return format. Sequence dependent contract changes instead of editing them concurrently.
- When sub-agents are used, record each worker's `repo`, `owned_paths`, `session_id`, `status`, `changed_paths`, `checks`, and concise `result` under its main agent in `luanphan_agents/<config-name>.json` before starting another dependent phase.
- Update the worker record on completion, failure, or interruption. Recover recorded sessions before creating replacements.
- Give workers the approved artifact path, scope, constraints, and expected return format.
- Read the worker summary and inspect its diff or evidence. Do not repeat its full investigation.
- Treat review findings as input, not permission for the reviewer to edit.
- Do not archive or delete worker sessions. `agent-session` disconnects after completion while preserving them for later resume.
- If `agent-session` returns `interrupted`, inspect the named Cursor ACP session before retrying.
- If no final JSON was returned, inspect the registry and resume the recorded Cursor session through `agent-session --agent cursor --session <recorded-session-id> --mode <mode> --config <config-name>` before creating another worker.
- Report each worker's provider, model, and session ID in the final answer.

Manual resume:

```bash
mcodex resume <codex-session-id>
agent-session --agent cursor --session <cursor-session-id> --mode <mode> --config <config-name> --cwd <workspace>
mcursor list
mcursor resume <cursor-chat-id-or-name>
```

`agent-session` resumes orchestrated Cursor ACP sessions. `mcursor list` and `mcursor resume` manage interactive native persistent sessions.

Bare `mcursor` opens a workspace-first persistent-session picker. Left/Right switches Workspace and All, Up/Down selects a session, Enter attaches, and Esc or an empty list starts Cursor's native persistent-session UI.
