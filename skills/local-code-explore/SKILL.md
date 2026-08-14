---
name: "local-code-explore"
description: "Trace a behavior through a local multi-repo workspace and return one concise, evidence-backed call graph with upstream, downstream, storage, and message edges."
---

# Local Code Explore

Read [../local-technical-writing/SKILL.md](../local-technical-writing/SKILL.md) and [../local-technical-writing/references/terminal-diagrams.md](../local-technical-writing/references/terminal-diagrams.md) before producing the answer.

## Output

- Reply in chat. Do not create files unless the user asks.
- Diagram first, then ordered evidence, then at most three non-obvious findings.
- Do not narrate searches, summarize the diagram, or dump code.

## Resolve scope

- Detect `<root>`, the active workspace under `<root>/local_workspaces/<workspace>/`, and the repository containing the focus.
- Search the active workspace first, then direct repositories under `<root>`, then matching read-only repositories under `<root>/_external/` when a proven edge requires them.
- Prefer an active-workspace checkout over its root checkout. Use one checkout of each repository per graph.
- Do not scan unrelated workspaces or external repositories.
- Mark `_external/` evidence as external context, never an implementation target.

## Trace

1. Start at the exact symbol, field, API, topic, condition, or behavior named by the user.
2. Record its definition and direct use sites with `path:line` evidence.
3. Walk upstream callers until entrypoints or no proven caller remains.
4. Walk downstream through functions, RPC, HTTP, storage, cache, and message producers/consumers until leaves or repeated nodes.
5. Resolve service-to-repository mappings from code and configuration. Never infer an edge from names alone.
6. Preserve important branches, mutations, filtering, retries, and missing propagation. Omit private helper detail unrelated to the question.

Follow the complete proven flow. Stop on cycles, duplicates, unrelated branches, or missing evidence; do not replace missing evidence with a guess.

## Parallel branches

When one node fans out to two or more independent repositories, explore those branches concurrently with one sub-agent per repository when sub-agent tooling is available. Linear chains and tightly coupled branches stay in the main investigation.

Each sub-agent receives:

```text
Repository: <absolute-path>
Entry: <RPC method, HTTP path, message topic, or symbol>
Return under 200 words:
- entrypoint path:line
- key behavior
- downstream RPC/HTTP/storage/message edges with path:line
- unresolved targets; do not guess
```

Merge every result into one graph before rendering. Recurse only when a returned edge is relevant and not yet explored.

## Evidence format

List evidence in graph order:

```text
service-a -> service-b | RPC ServiceB.MethodB | repo-a/path/file.go:42
service-b -> topic-a   | PRODUCE topic-a      | repo-b/path/file.go:88
topic-a -> service-c   | CONSUME topic-a      | repo-c/path/file.go:21
```

Add a finding only when it changes how the user should understand the flow: a mutation, fallback, missing edge, ambiguity, or external ownership boundary.
