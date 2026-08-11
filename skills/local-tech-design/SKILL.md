---
name: "local-tech-design"
description: "Create concise, evidence-backed technical designs for local multi-repo workspaces, with strict section ownership and anti-repetition rules."
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise

# About the tech design that you work on
## Workspace setup — FIRST STEP, before any tech-design work
Every tech design lives inside a **multi-repo git-worktree workspace** built by the `local-workspace` skill (via `mkws`). The tech doc, mapping file, and any implementation plans (e.g. those produced by `superpowers:writing-plans`) all live under the workspace folder. `mkws` creates `<workspace>/tech_doc/` as its own git repo so design milestones can be committed before code worktrees are attached.
**Before drafting the tech design, do the following in order:**
1. Ask the user for the **workspace name** (suggested default: a short slug derived from the tech-design topic, with `/` replaced by `_`).
2. Ask the user whether the workspace **already exists**:
   - **Already exists** → confirm the path `<root>/local_workspaces/<workspace-name>/` and use it as-is. Do NOT call `mkws` again.
   - **Does not exist** → invoke the `local-workspace` skill (`mkws`) to create it. Run `mkws --name <workspace-name>` — **no `--add`, no `--branch`**. The workspace is created empty so the tech doc can be drafted before microservices are mapped in; the branch is left unset and gets filled in later by `local-coding` when the first repo is attached. Don't ask the user for a branch name at this stage.
3. Once the workspace exists at `<root>/local_workspaces/<workspace-name>/`, all subsequent tech-design artefacts go inside it (see "Where to put the tech design?" below). Microservice repos AND the branch get added to the same workspace later — when the user moves on to `local-coding`, that skill runs `mkws --branch <branch> --add <repo1> <repo2> …` against the existing empty workspace, persisting the branch into the yml and attaching the worktrees in one shot, using the `<tech_doc_name>_mapping.md` file as the source of truth for which repos to attach.
## Where to put the tech design?
- All tech-design artefacts live under the workspace at `<root>/local_workspaces/<workspace-name>/tech_doc/`. Create the `tech_doc/` folder there if it doesn't already exist.
- Ask the user to confirm the tech design document name and format, then create the tech design document inside `<root>/local_workspaces/<workspace-name>/tech_doc/`, and save all changes as you work on it so nothing is lost on unexpected interruption.
- Commit meaningful design milestones inside `<root>/local_workspaces/<workspace-name>/tech_doc/` using local git commits. Good commit points include the first draft, mapping confirmation, approved decision revisions, and final local draft. Do not push or sync remote documents unless the user explicitly asks in the current turn.
- The microservice mapping file (`<tech_doc_name>_mapping.md`) and any implementation plans (e.g. plan files produced by `superpowers:writing-plans`) ALSO live under `<root>/local_workspaces/<workspace-name>/tech_doc/`. Keeping the doc, the mapping, and the plans co-located means future sessions can pick up the full context by looking inside the workspace folder.
## Format of the tech design
- Do NOT PUT ANY empty line in between lines, just new line is enough, no empty line
- **Exception — Markdown tables MUST be followed by one blank line.** After every Markdown table in the tech design, insert exactly one empty line before the next heading, bullet list, paragraph, code block, diagram, or another table. This applies to all tables, including the §4 choice table, §5/§6 field tables, the optional §6 service summary, and ad-hoc comparison tables. This rule overrides the "no empty line" rule because without the blank line, the next line can be parsed as part of the table.
- **Exception — HTML block boundaries MUST have one blank line.**
  - Insert exactly one blank line after every `</details>` before the next Markdown block.
  - Insert exactly one blank line before `<details>` when it follows a heading, list, paragraph, or another `</details>`.
  - This overrides the "no empty lines" rule; without it, renderers may treat following headings as raw text.
- **Tables — header styling.** Every Markdown table in the doc MUST render its header row as **bold + gray-background**. Implementation:
  - Wrap each header cell in `**…**` so the text is bold even in renderers that don't auto-bold the header row.
  - Auto-applies a gray fill to the header row of Markdown tables — combining auto-fill with the explicit `**…**` gives bold + gray-bg with no extra markup.
  - Example header row: `| **Field** | **Type** | **Notes** | **Details** |` — applies to *every* table in the doc, not just field tables.
## TLDR — short & concise (universal, applies to the entire doc)
**Brevity is the rule everywhere.** Every section, every bullet, every table cell, every code-block name, every diagram label. The whole tech doc should be skimmable in under five minutes and still convey every key point.
- **User feedback overrides template completeness.** Brevity wins over filling optional headings, rows, bullets, diagrams, tables, or examples.
- **One short phrase beats a sentence; a noun phrase beats a sentence; a verb + identifier beats a noun phrase.** Pick the shortest form that still carries the meaning.
- **Don't restate context the reader can derive** (no "as discussed above", no "this means that", no "in other words").
- **Cut throat-clearing**: drop "in order to", "with the goal of", "it should be noted that", "we propose to", "the team has decided that".
- **Specific beats abstract.** "Add `<field-name>` to `<RequestStruct>`" beats "extend the request schema with context needed downstream".
- **Don't over-explain in headings, names, or summary cells when the primary artefact already carries the detail.** Trust the structure: a §8 production action doesn't restate §6's diff; a §7 rollout phase doesn't restate §8's action; a `Code change` summary doesn't recap the folded block.
- **One fact, one home — strict ownership:**
  - Architecture flow belongs only in §3.
  - Unresolved architectural trade-offs belong only in §4.
  - Implementation details belong only in folded §6 blocks.
  - Production deployment actions belong only in §8.
  - Never repeat a fact across these sections, including as a summary, pointer, caption, or rephrasing.
- **Trust primary artefacts.** If a diagram, folded code/config block, field name, or upstream requirement already communicates the information, do not explain it again.
- **Avoid inventory tables.** Add a consumer inventory only when it materially compares at least three consumers. For multi-service scope, prefer one compact service summary table in §6 over separate inventories.
- **This rule wins on conflict.** If a per-section rule says "1–2 sentences" and one short phrase suffices, write the phrase. If a per-section rule says "2–4 sub-bullets" and 1 says everything, use 1.
## Diff format (universal — applies to code, IDL, schema, anything)
**Every diff in the doc — Go/Python/etc. code, Thrift/Protobuf IDL, SQL DDL, YAML config, anything else — uses the same parent-context pattern.** The point: reviewers should grok WHERE in the parent block the change lives, which conditions/fields surround it, and what runs after, without us pasting the entire block. This rule is referenced from §5 and §6 (and anywhere else a diff appears) — do NOT redefine it inline; just follow it.
Pattern, in order:
1. The parent block signature line, verbatim — `func <ParentFunc>(ctx context.Context, …) error {` for a function, `struct <RequestStruct> {` for an IDL struct, `service <ServiceName> {` for an IDL service, `CREATE TABLE <table_name> (` for SQL DDL, etc.
2. **Up to 5 lines** of explicit context that matters (early returns, validation, sibling fields/methods near the change — keep them, don't elide).
3. `...` on its own line to elide an uninteresting middle stretch.
4. **Up to 5 lines** of explicit context immediately above the change.
5. The actual `-` / `+` lines.
6. **Up to 5 lines** of explicit context immediately below the change.
7. `...` to elide whatever's left in the parent block.
Use a fenced ```diff``` block. Identifier names appear naturally in the diff; no extra prose call-out needed.
**Every diff block MUST be wrapped in a named, collapsible `<details>` element in source.** Source format:
````
<details>
<summary><strong><code-block name per Sync rule #10 conventions></strong></summary>

```diff
 <diff content>
```

</details>
````
This makes the block render as a collapsed disclosure widget on GitHub / GitLab natively, and on Lark / Confluence the converter maps the wrapper to the platform's native collapsible code primitive (collapsed by default + named title) — see Sync-to-remote rule #12 for the per-platform conversion. Never emit a bare ```diff``` block without the wrapper.
**Exception — substantial NEW function**: when a cohesive new behaviour is large enough that embedding it in an existing function would make the diff hard to review, prefer extracting it into a focused function. Show the complete new function in a normal language code block, without diff markers or `...`; do not render that new function as a diff. Wrap it in the same named `<details>` disclosure as every other §6 implementation block. Then show a separate small `diff` block for the existing caller that invokes it, preserving the parent-context pattern above. This extraction is allowed by the new-code gate when it isolates a substantial responsibility rather than creating a speculative wrapper.
**Exception — other fully NEW parent blocks**: when a new struct/service/table or similar non-function definition has no prior version, show the **entire definition** with `+` on every line and no `...` elisions. Reviewers need the full definition because there is no existing context to compare.
**New-code gate for proposed diffs:** §5/§6 Code changes MUST reuse the local-coding "New code gate — no speculative abstractions" rule. Do not propose new files, types, wrappers, helpers, option structs, adapters, aliases, or exported APIs unless the design proves one of the allowed conditions: directly required by the request, a substantial cohesive responsibility qualifying for the standalone-new-function rule above, 2+ real call sites needing shared logic now, an import-cycle break without duplicated logic, or public-API compatibility for existing callers. Otherwise show the direct change to the existing function/signature/body. Type aliases are justified only for compatibility with existing callers; otherwise use the real concrete type directly.
Code-change example (existing function, placeholders only):
````
```diff
 func <ParentFunc>(ctx context.Context, input *<InputType>) (*<OutputType>, error) {
     if input == nil {
         return nil, <ErrNilSentinel>
     }
     ...
     result, err := <fetchFromA>(ctx, input.ID)
     if err != nil {
         return nil, err
     }
-    if <existing condition> {
-        result, err = <fetchFromB>(ctx, input.ID)
+    if <existing condition> || <new condition> {
+        result, err = <fetchFromB>(ctx, input.ID)
+        <writeToA>(ctx, input.ID, result, <ttl>)
     }
     if err != nil {
         return nil, err
     }
     ...
 }
```
````
IDL-diff example (existing struct, adding one field — Thrift placeholder):
````
```diff
 struct <RequestStruct> {
     1: required i64 user_id
     2: optional string region
     ...
     5: optional i32 page_size
+    6: optional bool include_deleted
     7: optional string cursor
     ...
 }
```
````
IDL-diff example (NEW method — show everything, no elision):
````
```diff
+service <ServiceName> {
+    <ResponseStruct> <NewMethod>(1: <RequestStruct> req)
+}
+
+struct <RequestStruct> {
+    1: required i64 user_id
+    2: optional string region
+}
+
+struct <ResponseStruct> {
+    1: required i32 status
+    2: optional string message
+}
```
````
## Nested-list table cell format (universal — applies to any table cell that holds a 2-level nested list)
**Define the cell shape ONCE here; rules elsewhere (§4 `Options / trade-offs` and any other cell that needs nested content) reference this format and add only their own content constraints.** Do NOT redefine the encoding inline.
**Source encoding** — kept compact so the cell stays a valid Markdown table cell while still being parsable into a nested list:
- **Level 1 (item header)** — a bold line: `**<header text>**`. **No leading bullet character.** Header text is short.
- **Level 2 (sub-bullet)** — a line starting with `• ` (bullet + space) followed by the bullet text.
- **`<br>`** separates lines within a Level-1 item (between the header and its first sub-bullet, between consecutive sub-bullets).
- **`<br><br>`** separates Level-1 items.
- **`<br>` IS permitted** in any cell that opts into this format (overrides the "single-line cells only" rule for those specific cells).
**Generic shape**:
`**<L1 header A>**<br>• <sub-bullet A.1><br>• <sub-bullet A.2><br><br>**<L1 header B>**<br>• <sub-bullet B.1>`
**Remote rendering**: the **Sync-to-remote** rule converts cells in this format to platform-native nested lists (Lark `bullet` blocks at indent depth 1/2, Confluence nested `<ul><li>`, Google Docs `createParagraphBullets` with `nestingLevel: 1`, GFM `<ul><li>` HTML for git markdown). Never let `<br>` or `•` survive as literal text on the rendered page.
**When a rule references this format**, it specifies only what's specific to that use:
- Which Level-1 headers are required (fixed labels + order) or how they're shaped (e.g. `**Option <N> — <name>**`).
- Cap on number of Level-1 items.
- Cap on number of Level-2 sub-bullets per Level-1 item.
- Any content rules (e.g. "statements only, no questions").
## Confirming microservices and their codebase/relationship
- Microservice source repos live as **siblings of `local_workspaces/`** under the root the user invoked from (NOT inside the workspace itself — the workspace is initially empty by design). Walk the root folder, inspect candidate folder names, peek at code if needed, and map each microservice in the design to its sibling repo folder.
- **IGNORE the `local_workspaces/` container folder and any subfolder containing a `workspace.yml`**: every workspace created by `mkws` lives at `<root>/local_workspaces/<name>/` and its contents are duplicates of sibling repos already in the root. Skip the entire `local_workspaces/` tree (and defensively any other `workspace.yml`-bearing folder); only consider the original sibling repos as candidates for the mapping.
- Treat `<root>/_external/` as read-only external design context. Repos under `_external/` are not implementation repos and must not be added to the coding mapping file. Use them to understand external API contracts, upstream/downstream constraints, and compatibility risk when they are relevant to the design.
- If the design touches behavior owned by a repo under `_external/`, document it in `# 5. External Technical Design` using that section's per-API structure. Keep implementation work for normal sibling repos in `# 6. Internal Technical Design`.
- Use `local-code-explore` for relationship discovery. After candidate repos are identified, invoke/use `local-code-explore` to trace the relevant entrypoints, downstream calls, upstream callers, storage, and queue edges across those repos.
- Use the `local-code-explore` evidence map to confirm service relationships. Do not rely on folder names, stale docs, or separate hand-built call graphs when code evidence is available.
- If `_external/` repos are needed to understand a relationship, ask the user before exploring them unless the user already explicitly requested external-repo exploration.
- Provide the mapping and ask the user to confirm — wait for confirmation before proceeding.
- If the user has any feedback on the mapping, update accordingly and re-ask for confirmation until approved.
- Save the confirmed mapping as `<tech_doc_name>_mapping.md` inside the workspace's tech-doc folder: `<root>/local_workspaces/<workspace-name>/tech_doc/<tech_doc_name>_mapping.md`. Two-column Markdown table — column 1 = microservice name (as used in the design), column 2 = sibling-repo folder name (the source of truth for `mkws --add` later).
- The mapping file is referenced by `local-coding` later to attach repos to the same workspace via `mkws --add`. Keeping it co-located with the tech doc means the coding step picks up the full context with one folder.
- Mapping information should NOT BE INCLUDED in the tech design document itself — it lives only in the mapping file.
## Required document structure (mandatory — 8 numbered sections, in order)
The tech doc MUST follow this exact section structure. Do not reorder, do not skip; if a section doesn't apply, leave it with a one-line "N/A — <why>" rather than removing it.

**Heading levels in the OUTPUT tech doc** — do NOT start the file with a top-level `# <Tech Doc Title>` heading. The doc starts directly at `# 1. Overview & Background`.

Heading hierarchy is **strict and contiguous: H1 > H2 > H3 > H4 > H5**. Never jump (no `# Section` directly to `### Sub-sub-block`). Per-section levels:

| Section            | H1                                | H2                                | H3                                | H4                                | H5                                |
| ------------------ | --------------------------------- | --------------------------------- | --------------------------------- | --------------------------------- | --------------------------------- |
| §1, §2, §7, §8     | `# N. <name>`                     | —                                 | —                                 | —                                 | —                                 |
| §3 Solution Overview | `# 3. Solution Overview`          | `## 3.1 Architecture flowchart`, `## 3.2 Cross-service sequence diagrams` | `### <diagram name>` (under §3.2 — required when there are 2+ sequence diagrams; omit the H3 when there's exactly 1) | —                                 | —                                 |
| §4 Design Decisions| `# 4. Design Decisions`           | none by default — entire section is ONE table; H2 sub-sections (`## 4.X <name>`) added ONLY when user explicitly asks for a deeper writeup | —                                 | —                                 | —                                 |
| §5 External        | `# 5. External Technical Design`  | `## <method/api_name>`            | `### Request`, `### Response`, `### Logic change`, `### Code change` | — | — |
| §6 Internal        | `# 6. Internal Technical Design`  | `## 6.X Service: <Name>`          | folded `<details>` blocks only | — | — |

The examples below use `### N.` for §1..§8 purely because they're embedded in this SKILL.md (which has its own H1/H2 above). In the tech doc you generate, those become `# N.`, every `#### X.Y` becomes `## X.Y`, and so on per the table above.

### 1. Overview & Background
- **Up to 3 bullet points**, no prose paragraphs. One bullet each, in order:
  1. The problem (what's broken or missing).
  2. Why now (the trigger — deadline, incident, dependency).
  3. Success criterion (the single observable thing that means we're done).
- Skip any bullet that genuinely doesn't apply rather than padding it. Two bullets is fine; one is fine if the work is small.
- **No background dumps** — existing-system context belongs in §3's diagram labels or in the relevant §6 microservice section, not here. If a reader needs the architecture to grasp the problem, the problem statement is too abstract; rewrite the bullet.

### 2. Links
**Links only.** Never put repository mappings, code paths, evidence, ownership notes, or implementation references here; those stay in `<tech_doc_name>_mapping.md` and exploration evidence. Pre-populate with empty URL bullets:
```
- Tracking ticket:
- PRD / requirement doc:
- Related MRs:
- Monitoring / dashboards:
- Other:
```

### 3. Solution Overview
The "wide-angle lens" section: every reader should be able to grok the new architecture and its cross-service flows from §3 alone, without scrolling into the decisions or per-service deep-dive. §3 has TWO subsections, in this exact order:

#### 3.1 Architecture flowchart
- A coherent picture of the proposed architecture. Keep it consistent with the decisions documented immediately afterward in §4.
- Required: a mermaid `flowchart` showing services + primary data flow.
- **Mark NEW parts in green** — every new node (service, store, queue, table) and every new edge introduced by this design must be styled green so reviewers see the delta against today's architecture at a glance. See the "Highlight what's NEW" rule under "Diagrams" for the exact mermaid `classDef`/`linkStyle` snippet.
- **Diagram only — no prose, no captions, no overview text.** The diagram IS the contract. Labels on nodes/edges carry the meaning. If you feel a paragraph or even a one-liner is needed to explain it, the diagram is wrong: rename nodes, add edge labels, or split into multiple diagrams.

#### 3.2 Cross-service sequence diagrams
- One mermaid `sequenceDiagram` block per non-trivial cross-service interaction (≥2 hops, async edges, retries). Trivial single-RPC calls don't need one.
- This subsection lives **here** (under overview), **not** scattered inside the per-service sections in §6 — readers see the full end-to-end interactions before they drill into individual services.
- **Per-diagram heading** — when there are **2 or more** sequence diagrams, each diagram MUST be preceded by a heading **one level smaller than the §3.2 heading** (i.e. H3 in the output tech doc, since §3.2 is H2): `### <short diagram name>`. The name is a short noun phrase describing what the flow is (e.g. `### Request processing`, `### State reconciliation`, `### Cache miss read path`) — keep it scannable, not a sentence. When there is **exactly one** sequence diagram, omit the H3 entirely (the §3.2 heading covers it).
- **Diagrams only — no scenario descriptions, no preceding/trailing prose.** The H3 name is the only label. If a diagram needs an in-flow label, put it inside the `sequenceDiagram` (e.g. as a `Note over Participant: ...` block or in the participant names themselves).
- Mark NEW arrows / participants in green using the same `(NEW)` marker + green styling rule as the §3.1 flowchart — keeps the visual signal consistent across diagrams.
- **Every arrow MUST name the exact operation, never a generic verb.** The label answers "what call is this?" precisely enough that a reviewer could grep for it. Use the form below per protocol:
  - **HTTP** — `METHOD /path/with/{params}` (e.g. `POST /v1/<resource>`, `GET /v1/<resource>/{id}`).
  - **RPC** — `<Service>.<Method>` exactly as registered in the IDL (e.g. `<ServiceA>.<MethodX>`).
  - **SQL** — the SQL verb + table (e.g. `SELECT FROM <table>`, `UPDATE <table> SET <field>`, `INSERT INTO <table>`). For complex queries, name the named query / stored proc.
  - **Redis** — the command + key pattern (e.g. `GET <key>:{id}`, `SET <key>:{id} EX <ttl>`).
  - **Kafka / message broker** — `PRODUCE <topic>` / `CONSUME <topic>` (e.g. `PRODUCE <cluster>.<topic>`).
  - **Other** — pick the operation name from the actual API surface (`<S3-style> PutObject bucket=…`, `gRPC stream <StreamName>`, etc.).
- Generic labels are **forbidden**: never write `call`, `request`, `read`, `write`, `query`, `update`, `notify`, `event`, `process` on their own. If you can't name the operation, the arrow is ambiguous — fix the diagram before keeping it.

### 4. Design Decisions
**Only unresolved, high-impact architectural choices belong here.** A row must have at least two viable options that materially change architecture, cross-service contracts, data ownership, reliability, or irreversible rollout risk.
- Exclude trivial, forced, reversible, convention-fixed, or upstream-fixed choices without mentioning them.
- Never invent an obvious alternative to populate the table.
- Zero rows is preferred when the architecture is already fixed. Write exactly `N/A — no unresolved high-impact architectural choices.`
- Cap the table at four rows. Ask the user only about choices that remain unresolved and block the design.
| **#** | **Choice** | **Options / trade-offs** | **Recommendation** |
| ----- | ---------- | ------------------------ | ------------------ |
| 4.1 | <short architectural choice> | **Option 1 — <name>**<br>• <material benefit><br>• <material cost><br><br>**Option 2 — <name>**<br>• <material benefit><br>• <material cost> | <option> — <one-phrase reason> |
- Use the Nested-list table cell format only for `Options / trade-offs`; maximum three viable options and two short bullets per option.
- Do not restate constraints already visible in §3 or linked upstream requirements.
- No per-decision prose or sub-sections unless the user explicitly requests a deeper comparison.

### 5. External Technical Design
- Changes affecting external clients (mobile apps, web frontends, partner integrations, public APIs).
- Changes or constraints discovered from `<root>/_external/` repos also belong here. Treat those repos as external contract owners: describe required request/response/logic/code-contract diffs, but do not list them as internal implementation repos.
- For NEW APIs: full request/response schema.
- For existing APIs: ONLY the diff fields.
- If there is no external contract change, this section is exactly one line: `N/A — no external contract change.` Do not mention internal dependencies, library/module versions, or implementation details.
- **Per-API structure** (heading levels in the OUTPUT tech doc):
  - `## <method/api_name>` (H2) — one block per external method that changes.
  - Inside each block, fixed-label sub-headings at H3, in this exact order:
    - `### Request`
    - `### Response`
    - `### Logic change`
    - `### Code change`
- **Under `### Request` and `### Response`** — TWO artefacts in this exact order:
  1. The `Field | Type | Notes | Details` 4-column field table (format below).
  2. An **IDL diff code block** for the request struct (under Request) and the response struct (under Response), following the **universal Diff format** rule defined earlier in this skill. Do NOT redefine the diff pattern here.
     - **NEW API** (no prior version): show the **entire** request/response struct definition with `+` on every line, no `...` elisions.
     - **Existing API**: show only the diff using the parent-context pattern (struct signature + ≤5 lines context above/below + `-`/`+` lines + `...` for elided middles).
- **Field table format** — request/response payloads are documented as Markdown tables, one per request and one per response, using **exactly these 4 columns** in this order:
  ```
  | **Field** | **Type** | **Notes** | **Details**                             |
  | --------- | -------- | --------- | --------------------------------------- |
  | field_a   | int64    | New       | <one-line purpose / constraint>         |
  | field_b   | int64    | Updated   | was string; widened to int64            |
  | field_c   | int64    | Exist     | included for context — no change        |
  | field_d   | int64    | Removed   | replaced by field_e in v2 clients       |
  ```
  - **Field** = name only, plain text — **no backticks**, no descriptions, no markup, no `<br>`. Write `field_a`, never `` `field_a` ``. Same in prose: refer to fields plainly. Backticks belong only on actual code snippets, never on field names.
  - **Type** = the IDL type only. Same no-backtick rule.
  - **Notes** = a SHORT status tag — one of `New`, `Updated`, `Exist`, `Removed`. Nothing else in this column. Reviewers scan this column to see the shape of the diff at a glance.
  - **Details** = only information not already clear from the field name, type, status, diff, or upstream contract. Leave it empty when self-evident. If a row has no reason beyond completeness, drop it.

### 6. Internal Technical Design
Use `<tech_doc_name>_mapping.md` as the canonical service list; never copy repository paths or mapping evidence into the doc.
- For two or more changed services, use at most one compact `Service | Change | Risk` summary table. Skip it when it adds no comparison value.
- Each `## 6.X Service: <Name>` section has at most three short visible bullets total. Include only service-specific facts not already communicated by §3, §4, §5, or the folded blocks.
- Put request/response diffs, logic, code, schema, and config under named `<details>` disclosures. All implementation code/config is collapsed by default. If §5 already owns an external schema, omit it from §6 without a pointer.
- Prefer the code/config artefact over prose. Do not explain identifiers, fields, branches, or call order that the folded block already shows.
- For substantial new functions, show the complete function in a folded language block and a separate small folded diff for its existing caller.
- When tests need documentation, group them into at most five behavior categories. Never list individual test cases, test function names, or repetitive input permutations; keep test detail folded.
- Do not place architecture or sequence diagrams here; §3 owns flow. Do not place deployment commands here; §8 owns production actions.

### 7. Rollout Plan
- At most four numbered phases or gates.
- State sequencing, exposure, and decision gates only; do not repeat implementation details from §6 or concrete production actions from §8.
- Omit obvious CI/CD steps. If no staged rollout is needed, write `N/A — direct rollout.`

### 8. Release Checklist
**Production-deploy only.** What physically goes to prod — nothing else. NO dev-flow items (no MR-merge gates, no test-green gates, no review-approval gates, no testing-env deploys, no rollback-doc reminders); those belong in the team's normal CI/CD.
Per the **TLDR rule**, every line is **verb + name**. NO description of what's in the release, why, or what it does — §6 is the source of truth.
- Include production actions only. Never add implementation requirements, test reminders, design constraints, or rollout rationale.
- **Services to deploy** — `Deploy <service-name>`. Just that. Order = rollout order if there's a dependency.
- **Configs / dynamic settings** — `Update <namespace>/<key> = <new-value> (<env>)` or `Enable feature flag <flag-name> (<env>, <%>)`. NO explanation of what the config controls.
- **EXCEPTION — multi-step releases for one service.** Only when a single service needs ordered sub-steps (e.g. schema migration before app deploy, shadow → canary → 100%, dependency cutover) — promote it to a nested checklist under the service's bullet. Single-step deploys stay one line.
Example:
```
- [ ] Deploy <service-a>
- [ ] Deploy <service-b>
- [ ] Update config <namespace>/<key> = <new-value> (prod)
- [ ] Enable feature flag <flag-name> (prod, 100%)
```
Multi-step example:
```
- [ ] Deploy <service-c>
  - [ ] Run schema migration <name>
  - [ ] Deploy app to canary (10%)
  - [ ] Promote to 100%
```
If a service or config is already in §6 as a code change but doesn't need a separate prod action, it does NOT belong here. This is the deploy artefact, not a re-listing of the diff.

## Diagrams — reuse local-code-explore ASCII, mermaid in tech doc
- Every non-trivial design needs a diagram. Required at two points, BOTH in §3:
  1. **§3.1 Architecture flowchart** — a top-level service map + primary data flow consistent with every decision documented in §4. This is the single most important diagram in the doc.
  2. **§3.2 Cross-service sequence diagrams** — a sequence diagram for each non-trivial cross-service interaction (≥2 hops, async edges, retries). Trivial single-RPC calls don't need one. These live with the overview, NOT inside per-service sections in §6 — readers see end-to-end flows before drilling in.
- **Code exploration source of truth**: before drafting §3 diagrams for a code-backed design, invoke/use `local-code-explore` to explore the existing entrypoints, call chains, branches, storage, queue edges, and service relationships. Treat its evidence map and merged service graph as the source for the design diagram.
- **In the terminal chat**: reuse the `local-code-explore` terminal diagram format and rules. Do not invent a separate ASCII layout in this skill. The terminal diagram must stay as one merged graph with shared service boxes, RPC/API/function level nodes, centered connectors, and protocol/method/topic labels on arrows.
- **In the tech doc**: convert the same `local-code-explore` graph into a fenced ```mermaid``` block (`flowchart` / `sequenceDiagram` / `classDiagram` as appropriate). Mermaid-aware viewers render it inline.
- **Mermaid flowchart parser safety**: `flowchart` node IDs must be simple identifiers only (e.g. `service_a`, `service_b`, `store_a`, `step_a`). Do NOT put spaces, punctuation, paths, key patterns, operation names, or `(NEW)` markers in node IDs.
  - Flowchart node labels with spaces, punctuation, or `(NEW)` MUST use quoted label syntax: `svc["Service A (NEW)"]`.
  - Database / cylinder nodes MUST quote the label too: `store_a[("Store A")]`.
  - Edge labels containing key patterns, RPC names, HTTP paths, `/`, `{}`, `+`, `*`, `:`, `.`, or `(NEW)` MUST use quoted edge-label syntax: `-->|"RPC: <Service>.<Method> (NEW)"|`.
  - Keep one Mermaid statement per line. Do not split a node or edge statement across multiple lines.
- **Mermaid flowchart layout width control**: §3.1 is architecture shape, not full operation detail. Prefer `flowchart LR` only while the diagram stays readable. When the architecture flowchart becomes too wide or turns into a long single-row chain, switch to `flowchart TB` and split it into stacked `subgraph` blocks by concern or phase.
  - In top-down mode, each subgraph should use `direction TB` so local steps stack vertically.
  - Keep cross-subgraph edges short and high-level.
  - Put detailed operation names in §3.2 sequence diagrams or §6 code changes, not in §3.1 edge labels.
  - Shorten §3.1 edge labels to operation intent, e.g. `Write derived state (NEW)` instead of a full key pattern.
  - Target 5–10 visible nodes and choose top-down layout instead of shrinking labels or keeping an unreadable horizontal chain.
- **Keep both representations in sync**: ASCII and mermaid encode the same nodes/edges/labels from the `local-code-explore` graph. If you change one, change the other.
- **Keep diagrams concise**: target 5–10 primary nodes in the shared overview. For doc-only deep dives, add smaller §3.2 sequence diagrams by concern; do not split the terminal ASCII overview into per-service or per-repo charts.
- **Update on revisions**: when the design changes, update the mermaid in the tech doc AND re-emit the updated ASCII in chat. Stale diagrams are worse than no diagram.
- **Highlight what's NEW**: every diagram MUST visually distinguish new pieces (new services, new tables, new edges, new fields) from existing ones. Mermaid: green fill + green text via a `new` class (`classDef new fill:#bbf7d0,stroke:#16a34a,color:#16a34a,font-weight:bold`) applied to new nodes — this also colors any `(NEW)` marker inside the node label green; new edges styled with `linkStyle <idx> stroke:#16a34a,stroke-width:2px,color:#16a34a` (the trailing `color:` greens the edge-label text including its `(NEW)` tag). Tag new nodes/edges with a trailing `(NEW)` marker in BOTH ASCII and mermaid (use parentheses, never `[NEW]` — `[...]` is mermaid node syntax and breaks the parser inside edge labels). The `(NEW)` text must render green wherever it appears. Existing pieces stay default-styled — the contrast is the point.
Mermaid equivalent derived from the shared graph:
```mermaid
flowchart TB
  subgraph stage_a["Stage A"]
    direction TB
    service_a["Service A"]
    service_b["Service B"]
    store_a[("Store A (NEW)")]
    service_a -->|"Read source data"| service_b
    service_a -->|"Write derived state (NEW)"| store_a
  end
  subgraph stage_b["Stage B"]
    direction TB
    component_a["Component A"]
    step_a["Step A (NEW)"]
    output_a["Output A"]
    component_a -->|"Use derived state (NEW)"| step_a
    step_a -->|"Build output (NEW)"| output_a
  end
  store_a -->|"Read state (NEW)"| component_a
  classDef new fill:#bbf7d0,stroke:#16a34a,color:#16a34a,font-weight:bold
  class store_a,step_a new
  linkStyle 1 stroke:#16a34a,stroke-width:2px,color:#16a34a
  linkStyle 2 stroke:#16a34a,stroke-width:2px,color:#16a34a
  linkStyle 3 stroke:#16a34a,stroke-width:2px,color:#16a34a
  linkStyle 4 stroke:#16a34a,stroke-width:2px,color:#16a34a
```
## Final brevity gate
Run this gate before final approval and before every remote sync:
1. **Anti-repetition pass:** remove anything already communicated by a diagram, folded code/config block, field name, upstream requirement, or another section. Do not replace removed text with a pointer.
2. **Five-minute budget:** visible non-code prose outside `<details>` blocks must stay below 200 source lines. If it reaches 200 lines, cut content before proceeding.
3. **Readability failures:** flag and fix every repeated concept and every visible paragraph longer than three source lines. Prefer deletion, a short bullet, or a primary artefact.
4. **Ownership check:** §3 flow, §4 unresolved trade-offs, folded §6 implementation, and §8 production actions must not overlap.
5. **Template check:** remove optional structure that does not add information. User feedback overrides template completeness.
## Design loop (workflow — how to fill the 8 sections)
- The doc is **never final** until the feature is in production. Keep asking for feedback after every revision.
- **First round:** produce the eight top-level sections in order, using the exact N/A lines where required and leaving optional structures empty when they add no information.
- Ask the user only about unresolved, high-impact architectural choices that block a sound design. Do not surface, record, or request confirmation for trivial, forced, reversible, convention-fixed, or upstream-fixed choices.
- **Subsequent rounds:** revise only sections whose facts changed. Remove resolved §4 rows instead of preserving decision history in the design.
- **For mapping, cross-service exploration, and diagrams**: invoke/use `local-code-explore` first so the confirmed mapping, §3, and §6 share one verified call graph instead of separately reconstructed flows.
- **For §6 (Internal Technical Design)**: dispatch one FOCUSED AGENT TASK per microservice IN PARALLEL — each agent explores its repo, computes the IDL/logic/code diff, applies the local-coding new-code gate to every proposed added file/type/function/helper/wrapper/alias/API, and reports back. The main agent stitches the results into §6 and reconciles it with the `local-code-explore` graph.
- **Permission:** invoking `local-tech-design` is explicit permission to use sub-agents when the §6 agent-task rule or `local-code-explore` fan-out rule matches. Do not avoid sub-agents or ask again for permission unless sub-agent tooling is unavailable.
- Use the codebase mapping from `<tech_doc_name>_mapping.md` as the canonical microservice list — never guess service boundaries.
- Run the Final brevity gate after every revision and again before presenting or syncing the design.
## Sync to remote (when the user provides a URL)
**HARD RULE — sync is ALWAYS user-invoked, NEVER automatic.** Do NOT push the tech doc (or any part of it) to a remote URL on your own initiative. This applies even when the user has previously synced. Every remote write — first upload, every incremental update, every section replacement — requires an **explicit, current-turn instruction** from the user (e.g. "sync to <URL>", "push the §6 update to Lark", "update the remote doc"). Until that instruction arrives, the local file under `tech_doc/` is the only artefact you touch. If you finish a revision round and notice a remote URL was previously provided, do NOT auto-push the new revision — wait for the user to ask. Surface a one-line reminder if useful (e.g. "Local doc updated. Want me to sync the changes to <URL>?"), then stop.
**Trigger**: user explicitly asks to sync, and a URL is on hand (either provided this turn or previously confirmed for this doc). Detect the platform from the URL host + path and route to the right skill:
| **URL pattern**                                                                              | **Platform**                | **Skill / tool**                                                                                         |
| -------------------------------------------------------------------------------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------- |
| `feishu.cn`, `larksuite.com`, `larkoffice.com` — match sub-path `/docx/`, `/sheets/`, `/wiki/`, `/file/` | Lark / 飞书                  | `lark-doc` (docx), `lark-sheets` (sheets), `lark-wiki` (wiki node), `lark-markdown` (raw `.md` in Drive) |
| `atlassian.net/wiki/`, `*.atlassian.com/wiki/`, self-hosted Confluence                       | Confluence                  | WebFetch + Confluence REST API (`/rest/api/content/{id}`)                                                |
| `docs.google.com/document/`, `docs.google.com/spreadsheets/`                                 | Google Docs / Sheets        | `mcp__claude_ai_Google_Drive__*` deferred tools                                                          |
| `github.com/.../blob/.../*.md`, `gitlab.*/.../blob/.../*.md`, any git-hosted markdown file   | Remote markdown in git repo | `codebase` skill or `gh` CLI for GitHub                                                                  |
If the URL doesn't match any pattern above, ask the user which platform it is rather than guessing.
**Upload algorithm**:
1. **Fetch the remote first.** If it's empty / placeholder / brand-new, build the initial payload from the local tech doc but omit §2 Links. Also omit §8 Release Checklist until the user separately confirms its exact content. Never use a whole-document overwrite that would bypass these exclusions.
2. **Use the reusable compare helper before writing.** First locate the installed copy of this skill, then inspect and run the helper from that installed skill directory: `<installed-skill-dir>/scripts/tech_doc_compare.py`. Do not assume the current working tree is the active skill installation. Run `<installed-skill-dir>/scripts/tech_doc_compare.py plan --local <tech_doc.md> --remote <remote-url>` for Lark docx, or `<installed-skill-dir>/scripts/tech_doc_compare.py plan --local <tech_doc.md> --remote-file <remote-export.md>` when the remote content has already been exported. Use `--json` when the changed-section list will be consumed by another script. This helper is read-only: it canonicalizes remote/local exports into comparable content blocks, reports normal text changes, reports diagrams as `diagram_sections`, reports §8 as `confirmation_sections`, and reports §2 as `ignored_sections`. Never mix these protected groups into normal text updates. If the helper reports `unsafe` because the remote has no parseable headings, do NOT treat local sections as new; fall back to a targeted keyword/section fetch and exact text replacement for the requested change. Do not recreate one-off comparison scripts unless this helper cannot represent the current document format.
3. If the remote has existing content → compute a **section-level diff** using the §1..§8 numbered headings and supported sub-headings such as §5 methods and §6 service sections as diff boundaries; treat each `<details>` block as an indivisible implementation artefact. Prefer the compare helper output as the diff plan. For each heading whose body actually changed, replace **only that section** remotely. **Never overwrite the entire doc.** Apply these section policies before writing:
   - **§2 Links — remote source of truth.** Never create, replace, delete, reorder, or synchronize this section from the local doc. Ignore every local/remote difference in Links and preserve the remote section exactly.
   - **§8 Release Checklist — separate confirmation required.** Do not create or modify it under a normal sync instruction. Show the exact proposed §8 change and ask the user to confirm that Release Checklist update explicitly, just like diagram replacement confirmation.
4. Walk both local and remote as a heading tree (`H1 > H2 > H3 > ...`). The **deepest** heading whose body differs is the replacement unit — don't replace a parent if only one child changed. Identical sections are skipped.
5. **Write strategy — exact text replacement is highest priority.**
   - For any existing remote section/block, first fetch the exact current remote text and update it with the platform's exact text replacement operation only.
   - If exact text replacement cannot be performed because the remote text cannot be matched, STOP and ask the user before using any block-level replacement.
   - Do NOT silently fall back to `block_replace`, `block_delete` + insert, `overwrite`, or any whole-block rewrite for existing content.
   - Exception: if the section/block is new and has no remote counterpart, creating it with an insert/create operation is allowed.
6. Per-platform write strategy:
   - **Lark docx** — first use `docs +fetch --scope outline --max-depth <n>` to locate the target heading block id, then read the current section with `docs +fetch --scope section --start-block-id <heading-block-id> --detail with-ids`. Update with `docs +update --command str_replace` targeted at the exact section text. Use `block_insert_after` only for NEW sections/blocks. Use `block_replace` only after `str_replace` fails and the user explicitly confirms that block replacement is acceptable. **Never use `overwrite`** on the whole doc.
   - **Confluence** — pages store body as a single XHTML blob. Read the body, splice in the changed sections by heading, write back via `PUT /rest/api/content/{id}`. Section-level intent, single-write API.
   - **Google Docs / Sheets** — `documents.batchUpdate` with `replaceAllText` / `insertText` requests scoped to the changed section's range; for Sheets, target the cell range that holds that section.
   - **Git markdown** — pull, edit only the changed sections in place using the universal Diff format pattern, commit with a message naming the sections (e.g. `tech-doc: update §4.2, §6.1.<method-name>`), push or open a PR per repo convention.
7. **Diagram write strategy — separate confirmation required.** If the compare helper reports `diagram_sections`, list them in a separate "Diagram updates" section before any remote write. A normal sync instruction does NOT authorize diagram replacement. Ask the user to explicitly confirm replacing/overwriting those remote diagram blocks. After confirmation, replace the whole remote diagram block for each changed local diagram instead of trying exact text replacement inside the rendered block.
   - **Lark / Feishu whiteboards must stay native.** Never render or upload SVG/PNG when the diagram can be represented natively. Use the local Mermaid logic as the source and update the existing board directly with `lark-cli whiteboard +update`, piping diagram content through stdin without temporary image files.
   - Preserve the document title, whiteboard block, and whiteboard token. Replace only the existing board contents after the user explicitly authorizes that diagram replacement.
   - Represent each node as one native shape containing its own label. Do not split a node into separate box, text, or icon objects. Bind every connector endpoint to its source and target node IDs; do not use coordinate-only arrows.
   - After updating, query the board with both `--output_as code` and `--output_as raw`. Verify that each shape contains its own `text`, every connector has `start_object` and `end_object` attachment IDs, the returned syntax is Mermaid, and unrelated diagrams and document content remain unchanged.
   - If OpenAPI conversion is required, pipe `whiteboard-cli` output directly into `lark-cli`; never persist SVG/PNG intermediates.
8. **Confirmation gate**: before the FIRST remote write, list to the user the exact set of sections about to change. The user's current-turn sync instruction authorizes normal exact-text updates and new unprotected sections. It does NOT authorize block replacement, diagram replacement, or any §8 Release Checklist update. Each protected update requires separate explicit confirmation.
9. **Local file is the source of truth except §2 Links.** Sync is one-way (local → remote) for normal sections. Links is remote-owned and must remain untouched; never pull it into local or push local Links remotely unless the user explicitly requests a separate non-sync editing task.
10. **Table cells using the Nested-list table cell format MUST be uploaded as platform-native nested lists, NOT as `<br>•` run-on text.** This applies to the §4 `Options / trade-offs` column and any other cell that opts into the format. The remote cell must visually show indented sub-items (Level-1 header > Level-2 sub-bullets), not a single paragraph with `•` characters and line breaks left as literal text.
   - **Parse the source cell** per the encoding defined in the Nested-list cell format section (bold non-indented line = Level 1; `• ` line = Level 2; `<br>` within an item; `<br><br>` between items). Preserve the bold marker on Level-1 lines as bold formatting on the rendered list item.
   - **CRITICAL — `<br>` and `•` are PARSER MARKERS, not content.** Both characters must be **consumed entirely** during parsing and **never appear** in the text content of any rendered list item:
     - `<br>` is a structural separator (line boundary inside the cell). It must NOT survive into a rendered list item's body and become a hard line break inside that item. A Level-2 sub-bullet renders as **ONE continuous line of text**, full stop — no internal `<br>`-induced line breaks splitting one bullet's text into two visual lines.
     - `• ` (bullet + space) is the Level-2 marker. The platform's native bullet glyph replaces it; the literal `•` character must NOT appear at the start of the rendered item.
     - The Level-1 bold marker `**…**` becomes bold styling on the rendered item; the `**` characters must NOT survive as literal text.
   - **Long sub-bullets wrap naturally**: if a single Level-2 sub-bullet's text is long enough to need wrapping in the remote table cell, let the platform's renderer auto-wrap it based on column width (per the column-width rule in #11). Never insert `<br>` or any other hard-break marker inside a sub-bullet's text to force a wrap — that breaks the "one bullet = one logical line" invariant and produces fragmented rendered items.
   - **Verify after write**: re-fetch the cell and confirm (a) every list item is a single logical line of text, (b) no `<br>`, `•`, or `**` characters appear as literal text anywhere in the rendered list, and (c) no list item has been split into multiple list items by a stray `<br>`. If any of these fail, the conversion is broken — fix the parser/emitter, don't paper over with text-substitution hacks.
   - **Per-platform list emission**:
     - **Lark docx**: emit nested `bullet` list blocks inside the table cell — Level-1 items at indent depth 1, Level-2 sub-bullets at indent depth 2. Use `docs +update` block-level operations targeting the cell. Never let `•` survive as a literal character on the rendered page.
     - **Confluence**: emit `<ul><li>...</li></ul>` for Level 1 with a nested `<ul><li>...</li></ul>` inside each `<li>` for Level 2. Strip the source `•` and `<br>` markers entirely.
     - **Google Docs / Sheets**: `documents.batchUpdate` with `createParagraphBullets` requests scoped to the cell range; Level-2 sub-bullets get `nestingLevel: 1`.
     - **Git markdown**: GFM table cells don't support multi-line markdown lists, so emit explicit `<ul><li>...</li></ul>` HTML inside the cell — GitHub / GitLab honor the HTML and render proper nested lists.
11. **Table column widths on remote — applies to every table in the doc**, including the §4 choice table, §5/§6 field tables, the optional §6 service summary, and future tables. When writing to a rich-text platform that supports explicit column widths (Lark / Confluence / Google Docs), set widths to **maximize horizontal use of the row** instead of leaving the platform's default even-distribution — the goal is to stop wide-content cells from wrapping mid-sentence onto extra lines.
   - **Narrow columns (set as small as possible while keeping the widest value on one line)**: numbering, index, short-tag, field, type, and service-name columns. Pick the smallest width the platform supports that still keeps the longest cell value on one line.
   - **Wide content columns (give them the rest of the row width)**: `Options / trade-offs`, `Recommendation`, `Change`, `Risk`, `Notes`, and `Details`. Distribute the remaining row width proportionally to content density. A single Level-2 sub-bullet should fit on one rendered line; Level-1 items should not get fragmented.
   - **Per-platform mechanism**: Lark docx — set `column_width` on each table column block during `docs +update`; Confluence — emit `<colgroup><col style="width: …%"></col>…</colgroup>` inside the `<table>`; Google Docs — `updateTableColumnProperties` with explicit `columnWidthPx` per column.
   - **Markdown remote (git)**: GFM tables don't support explicit widths — skip width control entirely; renderers auto-fit. Don't pad the source with extra dashes trying to fake widths.
   - **Verify after write**: re-fetch the page and confirm narrow columns haven't been auto-widened, wide content cells use the full available row width, and no wide cell wraps a single sub-bullet onto a second line just because the column was too narrow.
12. **Code blocks: name them + collapse-by-default on remote.** Every diff code block (and any other code block longer than ~10 lines) MUST carry a **name** identifying what it is, and MUST be uploaded in the **collapsed** state on every platform that supports collapsing. The local source uses a `<details><summary>` wrapper as the canonical encoding (per the universal Diff format rule); the converter maps that wrapper to the platform's native collapsible-code primitive.
   - **Source encoding** (local markdown):
     ````
     <details>
     <summary><strong>Code change — &lt;ParentFunc&gt; (path/to/file.go)</strong></summary>

     ```diff
      func <ParentFunc>(...) ... {
      ...
     ```

     </details>
     ````
     The summary text follows the **Code-block name conventions** below.
   - **Code-block name conventions**:
     - Function diff → `Code change — <ParentFunc> (<short file path>)` (e.g. `Code change — <ParentFunc> (<short file path>)`).
     - IDL struct diff → `IDL — <StructName> (<idl file>)` (e.g. `IDL — <RequestStruct> (<idl file>)`).
     - IDL service / method diff → `IDL — <ServiceName>.<Method> (<idl file>)`.
     - SQL DDL diff → `SQL — <table_name> (<migration file>)`.
     - Config diff → `Config — <config key> (<file path or namespace>)`.
   - **Per-platform conversion of the `<details>` wrapper**:
     - **Lark docx**: emit a code block with `language: diff` and the summary text set as the block's title; mark the block as **collapsed by default**. Use lark-doc's collapsible code-block / callout-with-code support.
     - **Confluence**: emit `<ac:structured-macro ac:name="code">` with `<ac:parameter ac:name="title">…name…</ac:parameter>`, `<ac:parameter ac:name="language">diff</ac:parameter>`, and `<ac:parameter ac:name="collapse">true</ac:parameter>`.
     - **Google Docs**: no native collapsible code block. Render the summary as a small bold paragraph immediately above the code block; leave the code expanded (platform limitation — flag this in the confirmation gate so the user knows).
     - **Git markdown**: keep the `<details><summary>…</summary>…</details>` wrapper as-is. GitHub / GitLab render it natively as a collapsed disclosure widget. Do NOT strip the wrapper.
   - **Verify after write**: re-fetch and confirm the code block has its name visible above/inline with the block, is in the collapsed state on supporting platforms, and the diff content expands correctly when toggled.
