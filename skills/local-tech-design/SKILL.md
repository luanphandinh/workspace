---
name: "local-tech-design"
description: "Tech Design Genius"
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise

# About the tech design that you work on
## Workspace setup — FIRST STEP, before any tech-design work
Every tech design lives inside a **multi-repo git-worktree workspace** built by the `local-workspace` skill (via `mkws`). The tech doc, mapping file, and any implementation plans (e.g. those produced by `superpowers:writing-plans`) all live under the workspace folder so they travel with the feature branch and stay version-controlled alongside the eventual code changes.
**Before drafting the tech design, do the following in order:**
1. Ask the user for the **workspace name** (suggested default: a short slug derived from the tech-design topic, with `/` replaced by `_`).
2. Ask the user whether the workspace **already exists**:
   - **Already exists** → confirm the path `<root>/local_workspaces/<workspace-name>/` and use it as-is. Do NOT call `mkws` again.
   - **Does not exist** → invoke the `local-workspace` skill (`mkws`) to create it. Run `mkws --name <workspace-name>` — **no `--add`, no `--branch`**. The workspace is created empty so the tech doc can be drafted before microservices are mapped in; the branch is left unset and gets filled in later by `local-coding` when the first repo is attached. Don't ask the user for a branch name at this stage.
3. Once the workspace exists at `<root>/local_workspaces/<workspace-name>/`, all subsequent tech-design artefacts go inside it (see "Where to put the tech design?" below). Microservice repos AND the branch get added to the same workspace later — when the user moves on to `local-coding`, that skill runs `mkws --branch <branch> --add <repo1> <repo2> …` against the existing empty workspace, persisting the branch into the yml and attaching the worktrees in one shot, using the `<tech_doc_name>_mapping.md` file as the source of truth for which repos to attach.
## Where to put the tech design?
- All tech-design artefacts live under the workspace at `<root>/local_workspaces/<workspace-name>/tech_doc/`. Create the `tech_doc/` folder there if it doesn't already exist.
- Ask the user to confirm the tech design document name and format, then create the tech design document inside `<root>/local_workspaces/<workspace-name>/tech_doc/`, and save all changes as you work on it so nothing is lost on unexpected interruption.
- The microservice mapping file (`<tech_doc_name>_mapping.md`) and any implementation plans (e.g. plan files produced by `superpowers:writing-plans`) ALSO live under `<root>/local_workspaces/<workspace-name>/tech_doc/`. Keeping the doc, the mapping, and the plans co-located means future sessions can pick up the full context by looking inside the workspace folder.
## Format of the tech design
- Do NOT PUT ANY empty line in between lines, just new line is enough, no empty line
- **Exception — Markdown tables MUST be followed by one blank line.** After every Markdown table in the tech design, insert exactly one empty line before the next heading, bullet list, paragraph, code block, diagram, or another table. This applies to ALL tables in the tech design (§3 Decisions, §5/§6 field tables, §7 Effort, §8 Release Checklist, mapping-style tables if ever included, and any ad-hoc comparison table). This rule overrides the "no empty line" rule because without the blank line, the next line can be parsed as part of the table.
- **Tables — header styling.** Every Markdown table in the doc (§3 Decisions table, §5/§6 field tables, §7 Effort, §8 Release Checklist, etc.) MUST render its header row as **bold + gray-background**. Implementation:
  - Wrap each header cell in `**…**` so the text is bold even in renderers that don't auto-bold the header row.
  - Auto-applies a gray fill to the header row of Markdown tables — combining auto-fill with the explicit `**…**` gives bold + gray-bg with no extra markup.
  - Example header row: `| **Field** | **Type** | **Notes** | **Details** |` — applies to *every* table in the doc, not just field tables.
## TLDR — short & concise (universal, applies to the entire doc)
**Brevity is the rule everywhere.** Every section, every bullet, every table cell, every code-block name, every diagram label. The whole tech doc should be skimmable in under five minutes and still convey every key point.
- **One short phrase beats a sentence; a noun phrase beats a sentence; a verb + identifier beats a noun phrase.** Pick the shortest form that still carries the meaning.
- **Don't restate context the reader can derive** (no "as discussed above", no "this means that", no "in other words").
- **Cut throat-clearing**: drop "in order to", "with the goal of", "it should be noted that", "we propose to", "the team has decided that".
- **Specific beats abstract.** "Add `region` to `GetFooRequest`" beats "extend the request schema with the geographic context needed downstream".
- **Don't over-explain in headings, names, or summary cells when the body or a referenced section already carries the detail.** Trust the structure: a §8 release item doesn't restate §6's diff; a §7 task name doesn't restate §6's logic; a `Code change` summary doesn't recap the diff.
- **This rule wins on conflict.** If a per-section rule says "1–2 sentences" and one short phrase suffices, write the phrase. If a per-section rule says "2–4 sub-bullets" and 1 says everything, use 1.
## Diff format (universal — applies to code, IDL, schema, anything)
**Every diff in the doc — Go/Python/etc. code, Thrift/Protobuf IDL, SQL DDL, YAML config, anything else — uses the same parent-context pattern.** The point: reviewers should grok WHERE in the parent block the change lives, which conditions/fields surround it, and what runs after, without us pasting the entire block. This rule is referenced from §5 and §6 (and anywhere else a diff appears) — do NOT redefine it inline; just follow it.
Pattern, in order:
1. The parent block signature line, verbatim — `func DoThing(ctx context.Context, …) error {` for a function, `struct GetFooRequest {` for an IDL struct, `service FooService {` for an IDL service, `CREATE TABLE foo (` for SQL DDL, etc.
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
<summary><strong><code-block name per Sync rule #9 conventions></strong></summary>

```diff
 <diff content>
```

</details>
````
This makes the block render as a collapsed disclosure widget on GitHub / GitLab natively, and on Lark / Confluence the converter maps the wrapper to the platform's native collapsible code primitive (collapsed by default + named title) — see Sync-to-remote rule #9 for the per-platform conversion. Never emit a bare ```diff``` block without the wrapper.
**Exception — fully NEW parent block**: when the parent function/struct/service/table itself is new (no prior version exists), show the **entire definition** with `+` on every line, no `...` elisions — reviewers need the full thing because there is no "around it" to scan. This applies to a brand-new RPC method (full IDL method + request + response structs), a new struct, a new SQL table, a new endpoint, etc.
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
**Define the cell shape ONCE here; rules elsewhere (§3 Detail, §3 Decisions, anything else that needs nested content in a table cell) reference this format and add only their own content constraints.** Do NOT redefine the encoding inline.
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
| §3 Design Decisions| `# 3. Design Decisions`           | none by default — entire section is ONE table; H2 sub-sections (`## 3.X <name>`) added ONLY when user explicitly asks for a deeper writeup | —                                 | —                                 | —                                 |
| §4 Solution Overview | `# 4. Preferred Solution Overview` | `## 4.1 Architecture flowchart`, `## 4.2 Cross-service sequence diagrams` | `### <diagram name>` (under §4.2 — required when there are 2+ sequence diagrams; omit the H3 when there's exactly 1) | —                                 | —                                 |
| §5 External        | `# 5. External Technical Design`  | `## <method/api_name>`            | `### Request`, `### Response`, `### Logic change`, `### Code change` | — | — |
| §6 Internal        | `# 6. Internal Technical Design`  | `## 6.X Service: <Name>`          | `### API changes`, `### Infra changes`, `### Impact + mitigation` (omitted by default — keep ONLY if there's a genuinely critical cross-cutting risk; cap 3 points) | `#### <method/api_name>` (under API changes) or `#### Redis library change` etc. (under Infra changes) | `##### Request`, `##### Response`, `##### Logic change`, `##### Code change` |

The examples below use `### N.` for §1..§8 purely because they're embedded in this SKILL.md (which has its own H1/H2 above). In the tech doc you generate, those become `# N.`, every `#### X.Y` becomes `## X.Y`, and so on per the table above.

### 1. Overview & Background
- **Up to 3 bullet points**, no prose paragraphs. One bullet each, in order:
  1. The problem (what's broken or missing).
  2. Why now (the trigger — deadline, incident, dependency).
  3. Success criterion (the single observable thing that means we're done).
- Skip any bullet that genuinely doesn't apply rather than padding it. Two bullets is fine; one is fine if the work is small.
- **No background dumps** — existing-system context belongs in §4's diagram labels or in the relevant §6 microservice section, not here. If a reader needs the architecture to grasp the problem, the problem statement is too abstract; rewrite the bullet.

### 2. Links
Placeholder block — the user fills in URLs later. Pre-populate with empty bullets:
```
- Tracking ticket:
- PRD / requirement doc:
- Related MRs:
- Monitoring / dashboards:
- Other:
```

### 3. Design Decisions
**ONE single table for the entire §3 — by default, no sub-headings, no per-decision prose, no separate comparison tables.** Every meaningful design choice lives as a row in the same table so reviewers see the whole set at a glance.
**High-impact only — cap at 3–4 rows total.** Each row answers ONE concrete question that came up while designing AND would meaningfully change the architecture if picked differently (caching strategy, data-sync model, schema shape that crosses services, rollout strategy with risk, error semantics that propagate, etc.). Drop trivial / obvious / upstream-fixed choices entirely; their resolution shows up naturally in the §6 Code change diff.
**What to OMIT** as a row:
- **Already specified upstream** (PRD, requirements doc, parent tech doc) — cite the upstream doc once in §2 Links and skip.
- Dictated by an existing convention or framework default ("we use Hertz, so handler shape is fixed").
- Easily reversible local-to-one-file picks (rename a field, swap a struct).
- A typical reviewer wouldn't push back on either alternative.
**Bias hard toward fewer rows.** Zero rows is fine if upstream specs pin every meaningful choice; in that case write `N/A — all design choices fixed by <link in §2>`. If you have more than 4 rows, drop the weakest until only heavyweights remain.
**The table — exactly 4 columns, in this exact order:**
| **#**   | **Name**             | **Detail**                                                                                                                                                              | **Decisions**                                                                                                                                                                          |
| ------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3.1     | <short topic>        | **Summary**<br>• <constraint / trigger 1><br>• <constraint / trigger 2><br><br>**Target**<br>• <goal 1><br>• <goal 2>                                                   | **Option 1 — <preferred short name> (Preferred)**<br>• <logic step 1><br>• <logic step 2><br><br>**Option 2 — <short name>**<br>• <logic step 1><br>• <logic step 2>                    |
| 3.2     | <short topic>        | **Summary**<br>• <constraint 1><br><br>**Target**<br>• <goal 1><br>• <goal 2>                                                                                          | **Option 1 — <preferred short name> (Preferred)**<br>• <logic step 1><br>• <logic step 2><br><br>**Option 2 — <short name>**<br>• <logic step 1><br>• <logic step 2><br><br>**Option 3 — <short name>**<br>• <logic step 1><br>• <logic step 2> |
| 3.3     | <short topic>        | **Summary**<br>• <upstream constraint that left only one viable path><br><br>**Target**<br>• <goal>                                                                    | **Option 1 — <preferred short name> (Preferred)**<br>• <logic step 1><br>• <logic step 2>                                                                                              |
- **#** — `3.<N>`, contiguous starting at `3.1`.
- **Name** — short noun-phrase topic. **NOT a question** (no `?`, no "How should we…", no "Should we…"). Scannable.
- **Detail** — uses the **Nested-list table cell format**. Constraints specific to this column:
  - Exactly **TWO Level-1 items**, in this fixed order: `**Summary**`, then `**Target**`.
  - **1–3 Level-2 sub-bullets** per Level-1 item.
  - All sub-bullets are **statements, never questions** (no `?`, no "Should we…"). `Summary` bullets state the constraint / trigger that forces this decision; `Target` bullets state the concrete goal we're aiming for.
- **Decisions** — uses the **Nested-list table cell format**. Constraints specific to this column:
  - **Up to 3 Level-1 items** (options) for complex decisions; **just 1** for trivial / forced picks (e.g. an upstream constraint left only one viable path — record it for transparency).
  - **The Preferred option is ALWAYS Option 1** — pick the chosen option first and number it `Option 1`. Alternatives become `Option 2`, `Option 3` in any order. The `**(Preferred)**` suffix still appears on Option 1 for explicit visual confirmation, but its position alone signals the pick. Reviewers should never have to scan past Option 1 to find what was chosen.
  - Level-1 header shape: `**Option <N> — <short name>**`, numbered contiguously from 1.
  - **2–4 Level-2 sub-bullets** per option, describing the option's simple logic (what it does, where, when, fallback).
**No per-decision sub-sections by default.** No prose context, no per-decision criterion-comparison table, no individual H2 headings. The table above is the entire §3.
**Promote to an H2 sub-section ONLY when the user explicitly asks** (e.g. "expand 3.2 with a comparison table" or "add a deeper writeup for 3.1"). When promoted, the sub-section may include: a context paragraph, per-option logic bullets at full depth, and a `Criterion × Option` comparison table. Add a `(see §3.2 below)` pointer in the table's row when this happens.

### 4. Preferred Solution Overview
The "wide-angle lens" section: every reader should be able to grok the new architecture and its cross-service flows from §4 alone, without scrolling into the per-service deep-dive in §6. §4 has TWO subsections, in this exact order:

#### 4.1 Architecture flowchart
- A coherent picture that **stitches together every "Decision" picked in §3** into one architecture.
- Required: a mermaid `flowchart` showing services + primary data flow.
- **Mark NEW parts in green** — every new node (service, store, queue, table) and every new edge introduced by this design must be styled green so reviewers see the delta against today's architecture at a glance. See the "Highlight what's NEW" rule under "Diagrams" for the exact mermaid `classDef`/`linkStyle` snippet.
- **Diagram only — no prose, no captions, no overview text.** The diagram IS the contract. Labels on nodes/edges carry the meaning. If you feel a paragraph or even a one-liner is needed to explain it, the diagram is wrong: rename nodes, add edge labels, or split into multiple diagrams.

#### 4.2 Cross-service sequence diagrams
- One mermaid `sequenceDiagram` block per non-trivial cross-service interaction (≥2 hops, async edges, retries). Trivial single-RPC calls don't need one.
- This subsection lives **here** (under overview), **not** scattered inside the per-service sections in §6 — readers see the full end-to-end interactions before they drill into individual services.
- **Per-diagram heading** — when there are **2 or more** sequence diagrams, each diagram MUST be preceded by a heading **one level smaller than the §4.2 heading** (i.e. H3 in the output tech doc, since §4.2 is H2): `### <short diagram name>`. The name is a short noun phrase describing what the flow is (e.g. `### Order placement`, `### Refund cancellation`, `### Cache miss read path`) — keep it scannable, not a sentence. When there is **exactly one** sequence diagram, omit the H3 entirely (the §4.2 heading covers it).
- **Diagrams only — no scenario descriptions, no preceding/trailing prose.** The H3 name is the only label. If a diagram needs an in-flow label, put it inside the `sequenceDiagram` (e.g. as a `Note over Participant: ...` block or in the participant names themselves).
- Mark NEW arrows / participants in green using the same `(NEW)` marker + green styling rule as the §4.1 flowchart — keeps the visual signal consistent across diagrams.
- **Every arrow MUST name the exact operation, never a generic verb.** The label answers "what call is this?" precisely enough that a reviewer could grep for it. Use the form below per protocol:
  - **HTTP** — `METHOD /path/with/{params}` (e.g. `POST /v1/<resource>`, `GET /v1/<resource>/{id}`).
  - **RPC** — `<Service>.<Method>` exactly as registered in the IDL (e.g. `<ServiceA>.<MethodX>`).
  - **SQL** — the SQL verb + table (e.g. `SELECT FROM <table>`, `UPDATE <table> SET <field>`, `INSERT INTO <table>`). For complex queries, name the named query / stored proc.
  - **Redis** — the command + key pattern (e.g. `GET <key>:{id}`, `SET <key>:{id} EX <ttl>`).
  - **Kafka / message broker** — `PRODUCE <topic>` / `CONSUME <topic>` (e.g. `PRODUCE <cluster>.<topic>`).
  - **Other** — pick the operation name from the actual API surface (`<S3-style> PutObject bucket=…`, `gRPC stream <StreamName>`, etc.).
- Generic labels are **forbidden**: never write `call`, `request`, `read`, `write`, `query`, `update`, `notify`, `event`, `process` on their own. If you can't name the operation, the arrow is ambiguous — fix the diagram before keeping it.

### 5. External Technical Design
- Changes affecting external clients (mobile apps, web frontends, partner integrations, public APIs).
- For NEW APIs: full request/response schema.
- For existing APIs: ONLY the diff fields.
- If no external changes: write `N/A — internal-only change` and move on.
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
  - **Details** = the actual explanation: what changed for `Updated`, the constraint or purpose for `New`, the reason an `Exist` row is in the table at all (context, backcompat, still required by some client), the deprecation path for `Removed`. Keep it concise — one short phrase per row, no sentences, no nested bullets, no `<br>`. If a row has no real reason to exist beyond completeness, drop the row.

### 6. Internal Technical Design
**Two-level structure**: Service → then API-method (or Infra-action). Use the codebase mapping from the `<tech_doc_name>_mapping.md` file as the canonical service list. For each service that changes:

#### 6.X Service: <ServiceName>

##### API changes
For EACH API method that changes, one block, in this exact order:

###### <method/api_full_name>
Each per-method block (`#### <method>` H4 in the tech doc) has these fixed-label sub-headings at H5, in this exact order:

- `##### Request`
- `##### Response`
- `##### Logic change`
- `##### Code change`

If the same API is already documented in §5 (External Technical Design), **omit `Request` and `Response` entirely** — no heading, no field table, no IDL diff block, no pointer, no "see §5" line. The block then has only `Logic change` + `Code change` headings. Don't duplicate the schema or IDL across sections.

The content under each heading:

- Under **Request** / **Response** — TWO artefacts in this exact order, identical to §5:
  1. The `Field | Type | Notes | Details` 4-column table (only rows worth listing).
  2. An **IDL diff code block** for the request struct (under Request) and the response struct (under Response), following the **universal Diff format** rule. NEW method → entire struct with `+` on every line, no elisions; existing method → diff with parent-context pattern.
- Under **Logic change** — 2–5 bullets describing the **high-level behaviour change** at the API level: what the method now does differently end-to-end. This is the "what" only. Drilling into specific helper functions, private method names, internal struct fields, or anything wrapped in backticks belongs in the Code change diff, not here.
- Under **Code change** — diff per the **universal Diff format** rule. Do not redefine the pattern here.

##### Infra changes (omit the heading entirely if the service has no infra work)
Only use this section when the change touches infrastructure (Redis client, Kafka consumer, DB driver, message broker, cache layer, etc.). Each block is named by **the infra action**, never by source file or function:

Examples of infra-action block names (H4 in the tech doc):

- `#### Redis library change`
- `#### Kafka consumer change`
- `#### DB schema migration`

Each infra-action block has these fixed-label sub-headings at H5:

- `##### Logic change` — high-level only, same rule as API changes.
- `##### Code change` — diff per the **universal Diff format** rule (covers code AND schema/DDL/config diffs).

##### Impact + mitigation
**Omit this heading entirely by default.** Only include it when the service introduces a **genuinely critical, cross-cutting risk** that reviewers must be warned about up front (e.g. breaking change to an upstream contract, data migration with rollback constraints, latency budget eaten by a new sync RPC). If nothing meets that bar — no heading, no empty placeholder, no "N/A". Keep the noise floor low.
**When kept, the section is a tight nested list — at most 3 critical points.** Format:
- **Level 1** — one bullet per critical point. Each bullet is **a single line stating the problem** (what breaks, what regresses, what risks blowing up). No prose paragraph, no multi-clause sentence — one short statement.
- **Level 2 (indented child)** — exactly one sub-bullet under each Level-1 point, prefixed `Mitigation: `, stating concretely how the risk is handled (feature flag, rollout step, fallback path, monitoring alert, etc.). One line.
- **Cap: 3 Level-1 points.** If you have a 4th, either it's not actually critical (drop it) or two of the existing ones are the same risk in disguise (merge them). The list is a triage signal — bloating it dilutes attention.
Example shape (placeholders):
```
- <Problem 1 in one line>
  - Mitigation: <one-line concrete handling>
- <Problem 2 in one line>
  - Mitigation: <one-line concrete handling>
```
— Do NOT put sequence diagrams here; those live in §4.2 so they're surfaced before the deep-dive.

### 7. Effort & Estimation
A small Markdown table — exactly 4 columns in this order:
| **Microservice / task** | **Owner**     | **Effort (d)** | **Notes**                       |
| ----------------------- | ------------- | -------------- | ------------------------------- |
| <service-a>             | <owner / TBD> | <person-days>  | <empty or a few words>          |
| <task-name>             | <owner / TBD> | <person-days>  | blocked on <X>                  |
- Per the **TLDR rule**, every cell is as short as possible. The §6 diff is the source of truth for what's actually being built — never restate §6 content here.
- **Microservice / task** — service name (e.g. `service-a`) or short task verb-phrase (e.g. `migrate redis client`, `backfill region column`). NO description of what the work does. If the reader needs to know what's in the change, they read §6.
- **Owner** — single name, or `TBD` if unassigned.
- **Effort (d)** — person-days, rounded to halves (`0.5`, `1`, `1.5`, …).
- **Notes** — keep **empty by default**. Only fill it when there's a genuinely useful planning signal (a blocker, a dependency on another team, a non-obvious risk). Even then, prefer a single short phrase (`blocked on <X>`, `needs DBA review`, `depends on §3.2 pick`). Use the **Nested-list table cell format** ONLY when there are 2+ structured categories worth listing (e.g. multiple dependencies + multiple risks); cap 3 Level-1 items, 1–3 sub-bullets each. If you can't justify the structure, leave it as a single phrase.

### 8. Release Checklist
**Production-deploy only.** What physically goes to prod — nothing else. NO dev-flow items (no MR-merge gates, no test-green gates, no review-approval gates, no testing-env deploys, no rollback-doc reminders); those belong in the team's normal CI/CD.
Per the **TLDR rule**, every line is **verb + name**. NO description of what's in the release, why, or what it does — §6 is the source of truth.
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

## Diagrams — ASCII in chat, mermaid in tech doc
- Every non-trivial design needs a diagram. Required at two points, BOTH in §4:
  1. **§4.1 Architecture flowchart** — a top-level service map + primary data flow that reflects EVERY decision picked in §3. This is the single most important diagram in the doc.
  2. **§4.2 Cross-service sequence diagrams** — a sequence diagram for each non-trivial cross-service interaction (≥2 hops, async edges, retries). Trivial single-RPC calls don't need one. These live with the overview, NOT inside per-service sections in §6 — readers see end-to-end flows before drilling in.
- **In the terminal chat**: render the diagram as **plain ASCII art** — boxes drawn with `+--+` / `|`, arrows with `-->`, `<--`, `==>` (sync vs async), labels next to arrows. Sequence diagrams as left-to-right swim lanes with time flowing top-to-bottom. The chat client doesn't render mermaid, so source code is harder to scan than ASCII; the ASCII IS the readable overview.
- **In the tech doc**: save the same diagram as a fenced ```mermaid``` block (`flowchart` / `sequenceDiagram` / `classDiagram` as appropriate). Mermaid-aware viewers render it inline.
- **Keep both representations in sync**: ASCII and mermaid encode the same nodes/edges/labels. If you change one, change the other.
- **Keep diagrams concise**: 5–10 nodes max per diagram. If you need more, split into multiple smaller diagrams (one per concern) rather than one mega-diagram.
- **Update on revisions**: when the design changes, update the mermaid in the tech doc AND re-emit the updated ASCII in chat. Stale diagrams are worse than no diagram.
- **Highlight what's NEW**: every diagram MUST visually distinguish new pieces (new services, new tables, new edges, new fields) from existing ones. Mermaid: green fill + green text via a `new` class (`classDef new fill:#bbf7d0,stroke:#16a34a,color:#16a34a,font-weight:bold`) applied to new nodes — this also colors any `(NEW)` marker inside the node label green; new edges styled with `linkStyle <idx> stroke:#16a34a,stroke-width:2px,color:#16a34a` (the trailing `color:` greens the edge-label text including its `(NEW)` tag). Tag new nodes/edges with a trailing `(NEW)` marker in BOTH ASCII and mermaid (use parentheses, never `[NEW]` — `[...]` is mermaid node syntax and breaks the parser inside edge labels). The `(NEW)` text must render green wherever it appears. Existing pieces stay default-styled — the contrast is the point.
ASCII style example (chat) — placeholders only:
```
+----------+    <op A>      +-------------+
| Service X| -------------> |  Service Y  |
+----------+                +------+------+
                                   |
                                <op B>
                                   |
                         +---------+---------+
                         v                   v
                   +-----+-----+       +-----+-----+
                   | Store A   |       | Store B   |
                   |  (NEW)    |       |           |
                   +-----------+       +-----------+
```
Mermaid equivalent (tech doc):
```mermaid
flowchart LR
  ServiceX -->|<op A>| ServiceY
  ServiceY -->|<op B-1>| StoreA
  ServiceY -->|<op B-2>| StoreB
  classDef new fill:#bbf7d0,stroke:#16a34a,color:#16a34a,font-weight:bold
  class StoreA new
  linkStyle 1 stroke:#16a34a,stroke-width:2px,color:#16a34a
```
## Design loop (workflow — how to fill the 8 sections)
- The doc is **never final** until the feature is in production. Keep asking for feedback after every revision.
- **First round**: produce a draft of all 8 sections in order. §3 (Design Decisions) typically has the most back-and-forth — surface every non-trivial decision you can think of, with options and a recommendation, and let the user steer.
- **MANDATORY brainstorming pass after the first draft.** Once microservices are discovered (per the mapping file rule) AND the first draft is on disk under `<workspace>/tech_doc/`, **invoke `superpowers:brainstorming`** to systematically walk through every design decision with the user — including the trivial / forced / upstream-fixed ones that will NOT make it into the §3 table. The point: don't silently drop those low-impact picks; surface them so the user can confirm or override. Any artefacts produced by brainstorming or by `superpowers:writing-plans` are saved under `<root>/local_workspaces/<workspace-name>/tech_doc/` so they live alongside the doc and the mapping file.
  - Brainstorming output is a list of decisions split into two buckets:
    1. **Tabled decisions** — the high-impact ones that satisfy the §3 inclusion criteria. These become rows in the §3 Decisions table.
    2. **Omitted decisions** — the trivial / reversible / upstream-fixed / convention-forced picks. These get **recorded but not tabled**.
  - **The user must confirm both buckets** before you continue. If the user wants something moved (table → omitted, or omitted → table), update accordingly and re-confirm.
  - **Omitted decisions MUST still be stated in the doc** — never leave them invisible. Add a one-line bullet for each omitted pick at the end of §3 under a small italic note: `*Omitted from the table (low-impact / forced / upstream-fixed):*` followed by a flat bullet list. Each line is `<short topic> — <picked option> (<one-phrase reason for omitting>)`. Example: `*Omitted from the table:*` `- Logger field name — picked snake_case (matches existing convention)` `- Retry backoff base — picked 100ms (framework default)`. This keeps the audit trail without bloating the table.
- **Subsequent rounds**: only revise the sections that actually changed. Don't rewrite §1/§2/§7/§8 unless the requirement itself shifted. New questions that arise during §6 deep-dive get added back into the brainstorming bucket and re-classified (table vs omitted) — promote into §3 only if genuinely high-impact.
- **For §6 (Internal Technical Design)**: dispatch one FOCUSED AGENT TASK per microservice IN PARALLEL — each agent explores its repo, computes the IDL/logic/code diff, and reports back. The main agent stitches the results into §6.
- Use the codebase mapping from `<tech_doc_name>_mapping.md` as the canonical microservice list — never guess service boundaries.
## Sync to remote (when the user provides a URL)
**HARD RULE — sync is ALWAYS user-invoked, NEVER automatic.** Do NOT push the tech doc (or any part of it) to a remote URL on your own initiative. This applies even in auto mode and even when the user has previously synced. Every remote write — first upload, every incremental update, every section replacement — requires an **explicit, current-turn instruction** from the user (e.g. "sync to <URL>", "push the §6 update to Lark", "update the remote doc"). Until that instruction arrives, the local file under `tech_doc/` is the only artefact you touch. If you finish a revision round and notice a remote URL was previously provided, do NOT auto-push the new revision — wait for the user to ask. Surface a one-line reminder if useful (e.g. "Local doc updated. Want me to sync the changes to <URL>?"), then stop.
**Trigger**: user explicitly asks to sync, and a URL is on hand (either provided this turn or previously confirmed for this doc). Detect the platform from the URL host + path and route to the right skill:
| **URL pattern**                                                                              | **Platform**                | **Skill / tool**                                                                                         |
| -------------------------------------------------------------------------------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------- |
| `feishu.cn`, `larksuite.com`, `larkoffice.com` — match sub-path `/docx/`, `/sheets/`, `/wiki/`, `/file/` | Lark / 飞书                  | `lark-doc` (docx), `lark-sheets` (sheets), `lark-wiki` (wiki node), `lark-markdown` (raw `.md` in Drive) |
| `atlassian.net/wiki/`, `*.atlassian.com/wiki/`, self-hosted Confluence                       | Confluence                  | WebFetch + Confluence REST API (`/rest/api/content/{id}`)                                                |
| `docs.google.com/document/`, `docs.google.com/spreadsheets/`                                 | Google Docs / Sheets        | `mcp__claude_ai_Google_Drive__*` deferred tools                                                          |
| `github.com/.../blob/.../*.md`, `gitlab.*/.../blob/.../*.md`, any git-hosted markdown file   | Remote markdown in git repo | `codebase` skill or `gh` CLI for GitHub                                                                  |
If the URL doesn't match any pattern above, ask the user which platform it is rather than guessing.
**Upload algorithm**:
1. **Fetch the remote first.** If it's empty / placeholder / brand-new → push the entire local tech doc once and stop. Done.
2. If the remote has existing content → compute a **section-level diff** using the §1..§8 numbered headings (and their sub-headings: §3.X, §5.`<method>`, §6.X Service, §6.X.`<method>`, etc.) as the diff boundaries. For each heading whose body actually changed, replace **only that section** remotely. **Never overwrite the entire doc.**
3. Walk both local and remote as a heading tree (`H1 > H2 > H3 > ...`). The **deepest** heading whose body differs is the replacement unit — don't replace a parent if only one child changed. Identical sections are skipped.
4. Per-platform write strategy:
   - **Lark docx** — `docs +fetch --section <heading>` to read the current section, then `docs +update` with `block_replace` / `str_replace` / `block_insert_after` targeted at that section's blocks. **Never use `overwrite`** on the whole doc.
   - **Confluence** — pages store body as a single XHTML blob. Read the body, splice in the changed sections by heading, write back via `PUT /rest/api/content/{id}`. Section-level intent, single-write API.
   - **Google Docs / Sheets** — `documents.batchUpdate` with `replaceAllText` / `insertText` requests scoped to the changed section's range; for Sheets, target the cell range that holds that section.
   - **Git markdown** — pull, edit only the changed sections in place using the universal Diff format pattern, commit with a message naming the sections (e.g. `tech-doc: update §3.2, §6.1.GetFoo`), push or open a PR per repo convention.
5. **Confirmation gate**: before the FIRST remote write, list to the user the exact set of sections about to change. In auto mode, edits to §1 / §2 / §7 / §8 push directly; edits touching §3 / §4 / §5 / §6 require explicit user confirmation (these are the high-impact sections reviewers care about most).
6. **Local file is the source of truth.** Sync is one-way (local → remote). Never pull remote changes back into the local tech doc without the user's explicit instruction.
7. **Table cells using the Nested-list table cell format MUST be uploaded as platform-native nested lists, NOT as `<br>•` run-on text.** This applies to the §3 Detail and Decisions columns and any other cell that opts into the format. The remote cell must visually show indented sub-items (Level-1 header > Level-2 sub-bullets), not a single paragraph with `•` characters and line breaks left as literal text.
   - **Parse the source cell** per the encoding defined in the Nested-list cell format section (bold non-indented line = Level 1; `• ` line = Level 2; `<br>` within an item; `<br><br>` between items). Preserve the bold marker on Level-1 lines as bold formatting on the rendered list item.
   - **CRITICAL — `<br>` and `•` are PARSER MARKERS, not content.** Both characters must be **consumed entirely** during parsing and **never appear** in the text content of any rendered list item:
     - `<br>` is a structural separator (line boundary inside the cell). It must NOT survive into a rendered list item's body and become a hard line break inside that item. A Level-2 sub-bullet renders as **ONE continuous line of text**, full stop — no internal `<br>`-induced line breaks splitting one bullet's text into two visual lines.
     - `• ` (bullet + space) is the Level-2 marker. The platform's native bullet glyph replaces it; the literal `•` character must NOT appear at the start of the rendered item.
     - The Level-1 bold marker `**…**` becomes bold styling on the rendered item; the `**` characters must NOT survive as literal text.
   - **Long sub-bullets wrap naturally**: if a single Level-2 sub-bullet's text is long enough to need wrapping in the remote table cell, let the platform's renderer auto-wrap it based on column width (per the column-width rule in #8). Never insert `<br>` or any other hard-break marker inside a sub-bullet's text to force a wrap — that breaks the "one bullet = one logical line" invariant and produces fragmented rendered items.
   - **Verify after write**: re-fetch the cell and confirm (a) every list item is a single logical line of text, (b) no `<br>`, `•`, or `**` characters appear as literal text anywhere in the rendered list, and (c) no list item has been split into multiple list items by a stray `<br>`. If any of these fail, the conversion is broken — fix the parser/emitter, don't paper over with text-substitution hacks.
   - **Per-platform list emission**:
     - **Lark docx**: emit nested `bullet` list blocks inside the table cell — Level-1 items at indent depth 1, Level-2 sub-bullets at indent depth 2. Use `docs +update` block-level operations targeting the cell. Never let `•` survive as a literal character on the rendered page.
     - **Confluence**: emit `<ul><li>...</li></ul>` for Level 1 with a nested `<ul><li>...</li></ul>` inside each `<li>` for Level 2. Strip the source `•` and `<br>` markers entirely.
     - **Google Docs / Sheets**: `documents.batchUpdate` with `createParagraphBullets` requests scoped to the cell range; Level-2 sub-bullets get `nestingLevel: 1`.
     - **Git markdown**: GFM table cells don't support multi-line markdown lists, so emit explicit `<ul><li>...</li></ul>` HTML inside the cell — GitHub / GitLab honor the HTML and render proper nested lists.
8. **Table column widths on remote — applies to EVERY table in the doc** (§3 Decisions table, §5/§6 field tables, §7 Effort table, §8 Release Checklist, and any future tables). When writing to a rich-text platform that supports explicit column widths (Lark / Confluence / Google Docs), set widths to **maximize horizontal use of the row** instead of leaving the platform's default even-distribution — the goal is to stop wide-content cells from wrapping mid-sentence onto extra lines.
   - **Narrow columns (set as small as possible while keeping the widest value on one line)**: numbering / index / short-tag columns — `#` in §3, `**Field**` and `**Type**` in §5/§6 field tables, `**Owner**` and `**Effort (d)**` in §7, status checkboxes in §8. Pick the smallest width the platform supports that still keeps the longest cell value on one line.
   - **Wide content columns (give them the rest of the row width)**: `Detail` and `Decisions` in §3, `Notes` / `Details` in §5/§6 field tables, `Notes` in §7, the description text in §8 — distribute the remaining row width proportionally to content density. A single Level-2 sub-bullet should fit on ONE rendered line; Level-1 items shouldn't get fragmented.
   - **Per-platform mechanism**: Lark docx — set `column_width` on each table column block during `docs +update`; Confluence — emit `<colgroup><col style="width: …%"></col>…</colgroup>` inside the `<table>`; Google Docs — `updateTableColumnProperties` with explicit `columnWidthPx` per column.
   - **Markdown remote (git)**: GFM tables don't support explicit widths — skip width control entirely; renderers auto-fit. Don't pad the source with extra dashes trying to fake widths.
   - **Verify after write**: re-fetch the page and confirm narrow columns haven't been auto-widened, wide content cells use the full available row width, and no wide cell wraps a single sub-bullet onto a second line just because the column was too narrow.
9. **Code blocks: name them + collapse-by-default on remote.** Every diff code block (and any other code block longer than ~10 lines) MUST carry a **name** identifying what it is, and MUST be uploaded in the **collapsed** state on every platform that supports collapsing. The local source uses a `<details><summary>` wrapper as the canonical encoding (per the universal Diff format rule); the converter maps that wrapper to the platform's native collapsible-code primitive.
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
     - Function diff → `Code change — <ParentFunc> (<short file path>)` (e.g. `Code change — GetFoo (handler/foo.go)`).
     - IDL struct diff → `IDL — <StructName> (<idl file>)` (e.g. `IDL — GetFooRequest (foo.thrift)`).
     - IDL service / method diff → `IDL — <ServiceName>.<Method> (<idl file>)`.
     - SQL DDL diff → `SQL — <table_name> (<migration file>)`.
     - Config diff → `Config — <config key> (<file path or namespace>)`.
   - **Per-platform conversion of the `<details>` wrapper**:
     - **Lark docx**: emit a code block with `language: diff` and the summary text set as the block's title; mark the block as **collapsed by default**. Use lark-doc's collapsible code-block / callout-with-code support.
     - **Confluence**: emit `<ac:structured-macro ac:name="code">` with `<ac:parameter ac:name="title">…name…</ac:parameter>`, `<ac:parameter ac:name="language">diff</ac:parameter>`, and `<ac:parameter ac:name="collapse">true</ac:parameter>`.
     - **Google Docs**: no native collapsible code block. Render the summary as a small bold paragraph immediately above the code block; leave the code expanded (platform limitation — flag this in the confirmation gate so the user knows).
     - **Git markdown**: keep the `<details><summary>…</summary>…</details>` wrapper as-is. GitHub / GitLab render it natively as a collapsed disclosure widget. Do NOT strip the wrapper.
   - **Verify after write**: re-fetch and confirm the code block has its name visible above/inline with the block, is in the collapsed state on supporting platforms, and the diff content expands correctly when toggled.
