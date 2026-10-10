# SVG Diagrams

## Source

Build diagrams from the verified graph produced during code exploration. Keep the terminal and document diagrams on the same nodes and edges.

## Document assets

- Present document diagrams as SVG assets, not diagram-language code fences. Do not generate PNG alternatives.
- Store assets under `tech_doc/assets/` with document-specific names, for example `<document-stem>-architecture.svg` and `<document-stem>-sequence.svg`.
- Embed each asset with a relative Markdown image link and meaningful alt text. Keep assets alongside the document when saving or syncing local work.
- Author SVG directly or generate it from editable source. When using a generator, retain its source alongside the SVG and regenerate after graph changes.
- Use self-contained SVG with a `viewBox`, text, shapes, and paths. Avoid scripts, external assets, and HTML `foreignObject` labels.

## Architecture flowchart

- Show only the primary nodes needed for the changed flow; do not pad a simple diagram to meet a node count.
- Default to top-down layout.
- Use left-to-right layout only for one linear path with at most five primary nodes, no branches, merges, or shared stores, short edge labels, and a readable render at normal document width.
- Use top-down layout for multiple paths, branches, shared stores, or long labels.
- If a top-down diagram is still too wide, split unrelated flows. Use concern or phase subgraphs only when they improve grouping, never only to control layout.
- Keep each rendered label line within 40 characters. Break labels at meaningful phrase or syntax boundaries; never split a word arbitrarily.
- Put operation detail in sequence diagrams when it makes the overview noisy.

Mark new nodes and edges with `(NEW)` and green styling. Keep labels legible against their backgrounds.

## Sequence diagrams

- Add one diagram for each non-trivial cross-service interaction: multiple hops, asynchronous work, retry, compensation, or meaningful branching.
- One exact operation per arrow. Use RPC method, HTTP method/path, SQL operation/table, cache command/key, or message topic.
- Do not use generic labels such as `call`, `request`, `read`, `write`, `update`, or `process` alone.
- Put conditions in `alt`/`opt` blocks and state transitions in short notes.
- Omit trivial single-hop diagrams.

## Review

- Parse each SVG as XML, then render and visually inspect it at normal document width; a successful syntax check is insufficient.
- Regenerate stale assets and verify that Markdown links resolve before presenting or syncing the document.
- Verify every rendered label line is at most 40 characters and each break preserves meaning.
- If labels require zooming or horizontal scrolling, change the diagram to top-down or split it.
- Every drawn edge has code or contract evidence.
- Shared nodes are not duplicated.
- The requested behavior is visible without explanatory prose.
- New and existing behavior are visually distinct.
- Diagram labels contain no information repeated below the diagram.
