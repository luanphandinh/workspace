# Terminal Diagrams

## Output contract

- Start the answer with exactly one merged diagram in a top-level fenced block with info string `ansi`.
- Emit real ANSI SGR bytes. Color only the user's requested identifier, value, mutation, or missing edge; never color borders, connectors, arrows, or padding.
- Follow the diagram with ordered `path:line` evidence. Add at most three bullets for behavior not visible in the graph.

## Graph model

Normalize each cross-boundary edge as:

`(source, protocol, operation/path/topic, target, evidence path:line)`

- Trace upstream callers and downstream effects into one graph.
- Reuse one node for the same service or component. Merge shared paths and convergence; do not render one chart per branch.
- Keep nodes at service and entrypoint level. Include private helpers only when the user asks about their internal logic.
- A single-entrypoint service uses one box with `repo:` plus `rpc:`, `http:`, `consumer:`, or `method:`.
- Use nested operation boxes only when multiple same-level entrypoints in one service matter.
- Use standalone logic boxes for important branches, validation, mutation, or filtering inside one entrypoint.
- Label every cross-node edge with the exact protocol and operation: RPC method, HTTP method/path, SQL operation/table, cache command/key, or message topic.
- Put unproven targets in one `Disconnected / evidence not found` box. Mark read-only external evidence with `external: yes`.

## Focus trace

Use the user's actual identifier, not a generic `FOCUS` label:

- `request: <identifier>`
- `value: <observed value>`
- `mutates: <before> -> <after>`
- `passes: <identifier>`
- `missing: <identifier>`

Suggested ANSI colors: cyan bold for the requested item, green bold for confirmed mutation, yellow bold for missing or unproven propagation. Width calculations must ignore ANSI bytes.

## Layout

- Use continuous ASCII boxes and consistent widths within a row.
- Connect arrows to the exact operation or logic box they trigger.
- Align connectors by box center. Branch from a centered spine and place same-depth nodes on one row when readable.
- Wrap long labels inside the box; preserve connector columns and visible width.
- A branch is incomplete unless every target has a connected arrow.

```text
              +--------------------------------+
              | service-a                      |
              | repo: repo-a                   |
              | http: POST /entry              |
              +--------------------------------+
                              |
                              | RPC: ServiceB.MethodB
                              v
              +--------------------------------+
              | service-b                      |
              | repo: repo-b                   |
              | rpc: ServiceB.MethodB          |
              +--------------------------------+
                      |                         |
                      | branch: path-a          | branch: path-b
                      v                         v
+--------------------------------+  +--------------------------------+
| PATH A                         |  | PATH B                         |
| mutates: state-a -> state-b    |  | passes: field-a               |
+--------------------------------+  +--------------------------------+
                      |                         |
                      +------------+------------+
                                   |
                                   | PRODUCE topic-a
                                   v
              +--------------------------------+
              | service-c                      |
              | repo: repo-c                   |
              | consumer: topic-a              |
              +--------------------------------+
```
