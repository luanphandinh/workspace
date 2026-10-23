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

A sync request authorizes exact-text updates, new sections, text-preserving H1/H2 block replacement for native numbering, and native update of every Mermaid diagram within the requested source scope. A complete-document sync includes every diagram. Preserve remote-owned sections and ask separately only before a destructive change outside the requested source scope.

## Write strategy

1. Fetch the exact current section.
2. Use exact text replacement for an existing section.
3. Insert only when the section is new.
4. If exact replacement fails, stop and ask before block replacement, except for required text-preserving H1/H2 native-numbering updates and in-scope native diagram updates.
5. Never silently fall back to delete/recreate or whole-document overwrite.
6. Re-fetch changed sections and verify unrelated content is unchanged.

For an empty remote, create sections selectively and omit Links.

## Native whiteboards

- Treat every Mermaid diagram within the requested source scope as part of the sync.
- Resolve wiki URLs to their document and read the matching document integration skill's native Mermaid-to-whiteboard instructions before writing.
- Fetch the target section and block IDs. Pipe local Mermaid through stdin to the native whiteboard update command; do not create or upload SVG/PNG intermediates.
- Keep each rendered label line within 40 characters in both local and remote Mermaid. Break at meaningful phrase or syntax boundaries; never split a word arbitrarily.
- Preserve unrelated diagrams, section titles, tokens, and blocks. Replace the corresponding whiteboard contents only.
- Re-fetch the updated section and inspect the rendered preview. Verify Mermaid syntax, shape text, connector attachments, location, and unchanged unrelated content.
- If native Mermaid-to-whiteboard conversion is unavailable, stop and report the limitation. Do not silently change formats or claim that the diagram was synchronized.

## Rich-text fidelity

- Convert nested list markers to native nested lists; do not leave `<br>`, `•`, or `**` as literal content.
- Use native disclosure blocks only when the target API supports and round-trips them; otherwise use the prepared heading and code block.
- Give narrow columns only enough width for identifiers; give comparison/detail columns the remaining width.
- Re-fetch and verify structure, not only text.
