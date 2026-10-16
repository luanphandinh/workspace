# Remote Sync

## Authorization

- A current-turn request is required for every remote write.
- Fetch the remote document before planning changes.
- Before the first write, list the exact sections that will change.
- Never overwrite the whole document when an existing section can be updated.

## Compare

Locate this skill's installed directory and run its read-only helper:

```text
scripts/tech_doc_compare.py plan --local <local.md> --remote <remote-url>
```

Use `--remote-file <export.md>` when the remote was already exported and `--json` for machine consumption. If the helper reports an unstructured/unsafe remote, fetch a targeted section and use exact replacement; do not infer that every local section is new.

Update the deepest changed heading only. Treat each `<details>` block as one implementation artifact.

The helper compares section text, not SVG asset bytes. Compare each referenced SVG with the remote asset before declaring it unchanged, even when the Markdown image link has not changed.

## Outbound Markdown

- Pass every non-diagram section through `scripts/tech_doc_compare.py prepare` before writing it remotely. Use `--local <file>` or pipe section Markdown through stdin.
- The prepared form removes the local `[toc]` preview marker and manual numeric prefixes from Markdown headings, replaces each HTML disclosure wrapper with an H6 heading, and removes its closing tag. Never send `[toc]`, numbered heading text, `<details>`, or `<summary>` tags to Lark.
- Scan the exact outbound payload before writing and the fetched section afterward. If either disclosure tag remains, stop and correct that section.

## Native heading numbering

- Keep numbered headings in local Markdown. Strip their numeric prefixes only from the outbound payload; never put `1.` or `1.2` in remote heading text.
- After syncing heading text, replace each H1 and H2 block with the same level and title plus native sequence attributes:

```bash
lark-cli docs +update \
  --as user \
  --doc <doc-token> \
  --command block_replace \
  --block-id <heading-block-id> \
  --content '<h2 seq="auto" seq-level="auto">Heading title</h2>'
```

- Use `<h1 seq="auto" seq-level="auto">...</h1>` for H1 and `<h2 seq="auto" seq-level="auto">...</h2>` for H2. Preserve the exact unnumbered title and heading level.
- Do not add sequence attributes to H3-H6; keep those remote headings unnumbered.
- Re-fetch and verify every H1/H2 has both native sequence attributes, no heading text contains a manual numeric prefix, H3+ has no sequence attributes, and folded code sections remain intact.

## Fold code sections

- After syncing, resolve the Wiki token to its Docx `obj_token` and list the document blocks.
- Select H6 headings whose combined text begins with `Code change —` or `Code path —`, and confirm each immediately precedes its intended code block.
- In batches of at most 200, update only those blocks through the Docx block batch-update API with `style.folded=true` and `fields=[3]`. Preserve all text and content; never modify other headings.
- Re-read the blocks, verify every match is folded, and report matched and folded counts. Use the API, never desktop or browser UI.

## Remote-owned sections

- `Links`: remote source of truth. Never create, replace, reorder, delete, or pull it during normal sync.

A sync request authorizes exact-text updates, new sections, text-preserving H1/H2 block replacement for native numbering, and native import of every SVG referenced within the requested source scope. A complete-document sync includes every referenced diagram. Preserve remote-owned sections and ask separately only before a destructive change outside the requested source scope.

## Write strategy

1. Fetch the exact current section.
2. Use exact text replacement for an existing section.
3. Insert only when the section is new.
4. If exact replacement fails, stop and ask before block replacement, except for required text-preserving H1/H2 native-numbering updates and in-scope native diagram imports.
5. Never silently fall back to delete/recreate or whole-document overwrite.
6. Re-fetch changed sections and verify unrelated content is unchanged.

For an empty remote, create sections selectively and omit Links.

## SVG diagram sync

- Treat every SVG referenced within the requested source scope as part of the sync. Use the same verified SVG asset embedded by the local document.
- Read the matching document integration skill's native SVG-to-whiteboard instructions before writing. Use its native import path instead of a generic media upload, attachment, public link, raster image, or diagram-language conversion.
- Fetch the target section and block IDs. Import each SVG at its corresponding diagram location; replacing that corresponding diagram is within the requested sync scope.
- Preserve unrelated diagrams, section titles, tokens, and blocks. Ask separately only for destructive changes outside the requested source scope.
- Re-fetch the updated section and inspect the rendered preview. Verify the whiteboard is at the intended location, labels and edges are legible, no stale duplicate remains, and unrelated blocks are unchanged.
- If native SVG-to-whiteboard import is unavailable, stop and report the limitation. Do not silently change formats or claim that the diagram was synchronized.

## Rich-text fidelity

- Convert nested list markers to native nested lists; do not leave `<br>`, `•`, or `**` as literal content.
- Use native disclosure blocks only when the target API supports and round-trips them; otherwise use the prepared heading and code block.
- Give narrow columns only enough width for identifiers; give comparison/detail columns the remaining width.
- Re-fetch and verify structure, not only text.
