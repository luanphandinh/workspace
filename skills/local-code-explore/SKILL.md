---
name: "local-code-explore"
description: "Exploring the code base"
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise

# About the tech design that you work on
## Output
- All the output is provided in the current chat, and DO NOT CREATE ANY FILE, unless the user ask you to do so
- Out put will be mapping, diagram (including call chain, basic logic and focus point on what user want to look up), logic explaination
## Explore phase
- All the microservices codebase should be under the the current folder that you get invoked, can proceed to check the folder name, some of the code
- **IGNORE the `local_workspaces/` container folder and any subfolder containing a `workspace.yml`** — these are `mkws`-managed git-worktree bundles that duplicate sibling repos already in the root. Skip the whole `local_workspaces/` tree and only explore the original sibling repos; otherwise you'll explore the same code twice and produce confused mappings.
- Treat `<root>/_external/` as a separate read-only external repo index. Do NOT explore `_external/` by default while building the primary service graph. If a call points to an external service and a matching repo may exist under `_external/`, ask the user whether to explore that external repo. If the user explicitly asks to include/explore external services, you may inspect `_external/<repo>` and label those nodes as external context, not editable implementation repos.
- Starting to explore the given code, either the function name or block of code, during exploration, if the codebase starting to call RPC or HTTP or any calls to external service, record it and look up the microservices that is being called, and also look up the codebase folder that is related to that microservice, then record the mapping between the microservice and its codebase folder, and also record the relationship between the microservices, such as which microservice is calling which microservice, and what is the protocol of the call, such as RPC or HTTP or any other protocol
- Explore as deep as you can, if A calls B, then B call C, then C call D, so on and so forth, and you can find any microservices mapping in the codebase, proceed to explore those service also, the explore have to go as deep as possible
- Also explore as high as you can, if service A call B, B call C, C call the current code block/ API that user asked for,  proceed to explore those service also, the explore have to go as high as possible, look up all the way up
- Provide the mapping, why the other services is involved in the mapping, which line of the code that tell you the service is involved in the process
- If the service publish any message to message queue, record the message queue and look up potential consumer in the codebase, if you can look them up, proceed to explore the consumer also, the consumer explore will be the same as the explore phase mentioned above.
## Parallel downstream exploration via sub-agents
- **When to fan out:** any time a service calls 2+ independent downstream services (RPC / HTTP / MQ consumer) and those branches don't depend on each other's results, explore them in parallel via sub-agents instead of serially in the main agent.
- **How to dispatch:** send **one message containing multiple Agent tool calls** (one per downstream repo) so they run concurrently. See `superpowers:dispatching-parallel-agents`. Do NOT dispatch one at a time — that serializes them.
- **Sub-agent prompt must be self-contained:** absolute path to the downstream codebase folder, exact entry point to start exploring (RPC method / HTTP handler / MQ topic), and what to report back. The sub-agent has no memory of the main conversation.
- **Ask each sub-agent for a SHORT report (<200 words):**
  - which files/lines implement the entry point
  - any further downstream calls it makes (so the main agent can decide whether to recurse)
  - brief logic summary — no full code dumps, no full file reads
- **Merge phase:** after all sub-agents return, the main agent must first merge every reported edge into one transitive service graph, then render that single graph in the final diagram + mapping. Do not output one chart per sub-agent or one chart per service. If any sub-agent surfaces a new downstream service (C calls D), decide whether to recurse with another parallel fan-out before final rendering.
- **Don't fan out when:** the call chain is strictly linear (A→B→C with no branching), the downstream is trivial (single helper), or the branches share state the main agent needs to reason about together.
### Sub-agent prompt template
```
Explore repo <repo-name> at <absolute-path>/<repo-folder>.
Entry point: <RPC method / HTTP path / MQ topic> — find where it's implemented.

Report back in under 200 words:
  - file:line of the entry-point handler
  - brief logic summary (bullet points, no code dumps)
  - any further downstream calls (RPC/HTTP/MQ) with target service name + protocol
  - if a downstream target is not obvious from the code, say so — don't guess
```
## Output phase
- Diagram format must be compatible with the current chat window, under text format so user can understand, dont use any external UML diagram.
- Rendering the diagram is mandatory for every exploration answer. Even if the graph is small, include the diagram first, then the mapping/evidence below it.
- Always render exactly one merged end-to-end call chain diagram for all services discovered during exploration. If A calls B and B calls D, the final diagram must show `A -> B -> D`, not separate diagrams `A -> B` and `B -> D`.
- The single diagram must include all connected branches in the same chart. Do not output one chart per service, branch, sub-agent, upstream chain, or downstream chain.
- Before drawing the diagram, mentally normalize findings into edges: `(caller service, protocol, method/path/topic, callee service, evidence file:line)`. Use those edges to compose full paths from upstream entrypoints through downstream leaves.
- Reuse the same service container for the same service across the entire diagram. If multiple upstream services call the same downstream service, draw multiple inbound connectors into that one shared service container; do NOT duplicate the downstream service or split into separate charts unless the user explicitly asks for per-scenario/per-upstream diagrams.
- A service container contains the service name and repo. If the service has only one relevant RPC/API/function entrypoint, write that operation directly as a normal line in the service container. Do NOT draw a nested operation box for a single-method service.
- Keep the diagram at RPC/API/function level. Do NOT dig into helper/private sub-method details by default; that creates noise. Only include helper/private functions if the user explicitly asks to drill into internal logic.
- Use smaller nested operation boxes only when the same service has multiple same-level RPC/API/function entrypoints that matter to the explored flow. If multiple upstream calls trigger different entrypoints in the same service, put those smaller operation boxes side by side inside the same bigger service container.
- If a discovered service is disconnected from the main chain, do not create a second diagram. Add it under the same diagram as a clearly labeled `Disconnected / evidence not found` box, then explain briefly why the connection is not proven.
- Each service must be rendered as a larger container box. Do not put `in:` / `out:` lines in the service container; arrows are the source of truth for inbound/outbound calls.
- A single-operation service should include `method: <method-name>`, `rpc: <Service>.<RPCMethod>`, `http: <METHOD> <path>`, or `consumer: <topic>` directly in the service container.
- Each smaller operation box inside a multi-operation service container should be named by the triggered function/RPC method/HTTP handler itself, such as `<method-name>`, `<Service>.<RPCMethod>`, or `HTTP <METHOD> <path>`.
- Operation boxes in the same service should stay at entrypoint/function level:
  - Same-level entrypoints, such as two RPC/HTTP handlers called by different upstreams, render side by side inside the service container when width allows.
  - Internal helper/private functions are omitted unless explicitly requested.
- Arrows must connect directly to the specific operation box they trigger, both for inbound and outbound calls. Do not terminate arrows at the outer service container unless the exact operation is unknown.
- Arrows between operation boxes must include the protocol plus method/path/topic, such as `RPC: MethodAB`, `HTTP: POST /path`, or `MQ: topic-x`.
- Always include what the user asked to look up directly in the diagram using the user's actual requested identifier/behavior, not a generic placeholder. If the user asks about a field, API, method, topic, condition, config, or value, use that exact code identifier/value when it is present in the code.
- Do NOT use `FOCUS`, `USER FOCUS`, or repeated generic labels. Instead, add concise request-trace lines only on related boxes/edges:
  - `**request:** <actual requested item>`
  - `**value:** <observed value / condition / enum / payload field>` when known.
  - `**mutates:** <from> -> <to>` when the service changes, maps, enriches, filters, or drops the value.
  - `**passes:** <item>` when the service only forwards it unchanged.
  - `**missing:** <item>` when expected propagation is not found.
- Highlight means text style: use bold markdown (`**request:**`, `**value:**`, `**mutates:**`, `**passes:**`, `**missing:**`) and keep the highlighted line inside the box or next to the exact edge. Do not rely on words like "focus" to create emphasis.
- Only annotate boxes/edges that are related to the user's request. Unrelated branches still appear in the graph but should not carry request-trace lines.
- Draw boxes with consistent width within the same row and use continuous ASCII borders (`+-----+`, `| ... |`). Do not use fragmented or uneven box borders.
- Nested operation boxes must have visible horizontal padding inside the service container: at least two spaces after the outer `|` before the inner `+`, and at least two spaces before the closing outer `|`. The inner method box must never visually touch or break the service container border.
- Keep line width readable. If an RPC method, HTTP path, MQ topic, request trace, or code identifier is too long, split it across multiple aligned lines inside the box or edge label instead of widening the entire diagram. Prefer breaking after protocol, service name, path segment, or `|`.
- Align connectors by box centers. The connector must leave from the horizontal center of the upstream box and the arrow head must land at the horizontal center of the downstream box whenever the layout width allows.
- Branch from a centered spine: first draw a vertical line down from the source box center, then branch horizontally, then drop vertical lines into each target box center. Do not aim arrows at a target's left or right edge unless there is no room.
- Prefer row-based layouts for branches and convergence: services at the same graph depth should appear on the same row when width allows, and a shared downstream service should be centered beneath its upstream callers. Keep connector columns aligned under each source and above the shared target.
- Preferred format for connected graphs with multiple branches:
```
+--------------------------------+        +--------------------------------+
| service-a                      |        | service-c                      |
| repo: repo-a                   |        | repo: repo-c                   |
| method: <caller-func-a>        |        | http: POST /to-b               |
+--------------------------------+        +--------------------------------+
                |                                     |
                | RPC: MethodAB                       | HTTP: POST /to-b
                |                                     |
                v                                     v
        +----------------------------------------------------------+
        | service-b                                                |
        | repo: repo-b                                             |
        |  +------------------------+  +------------------------+  |
        |  | MethodAB handler       |  | POST /to-b handler     |  |
        |  | **request:** <field>   |  | **passes:** <field>    |  |
        |  +------------------------+  +------------------------+  |
        +----------------------------------------------------------+
                       |                            |
                       | HTTP: POST /to-d           | MQ: topic-x
                       |                            |
                       v                            v
+--------------------------------+  +--------------------------------+
| service-d                      |  | service-e                      |
| repo: repo-d                   |  | repo: repo-e                   |
| http: POST /to-d handler       |  | consumer: topic-x              |
| **passes:** <field>            |  | **value:** <payload>           |
+--------------------------------+  +--------------------------------+
                |                                |
                | RPC: MethodDF                  | HTTP: GET /to-g
                v                                v
+--------------------------------+  +--------------------------------+
| service-f                      |  | service-g                      |
| repo: repo-f                   |  | repo: repo-g                   |
| rpc: MethodDF handler          |  | http: GET /to-g handler        |
+--------------------------------+  +--------------------------------+
```
- If the external service can not be found in the codebase, hightlight it
- If an explored node comes from `_external/`, mark it as `external: yes` inside the service box and include evidence from `_external/<repo>` only when the user approved or explicitly requested external exploration.
- If user asks about a specific field or part of the logic, highlight it in the diagram and the logic summary so the user can easily spot it.
- DO NOT OVER EXPLAIN, if the user want to drill down to the detail of the specfic part, user need to ask and you will support
- Provide some key information under the diagram, such as when RPC function get calls, which file and line of code is that, the information should be provided follow the diagram call chains, so that user can easily understand the relationship between the diagram and the codebase
