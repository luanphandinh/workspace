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
- The prepared form removes manual numeric prefixes from Markdown headings only, replaces each HTML disclosure wrapper with an H6 heading, and removes its closing tag. Never send numbered heading text, `<details>`, or `<summary>` tags to Lark.
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

## Protected sections

- `Links`: remote source of truth. Never create, replace, reorder, delete, or pull it during normal sync.
- `Release Checklist`: show the proposed change and obtain separate explicit confirmation.
- Diagrams/whiteboards: list changed diagram sections and obtain separate explicit replacement authorization.

A normal sync request authorizes exact-text updates, new unprotected sections, and text-preserving H1/H2 block replacement for native numbering. It does not authorize other block replacement or protected updates.

## Write strategy

1. Fetch the exact current section.
2. Use exact text replacement for an existing section.
3. Insert only when the section is new.
4. If exact replacement fails, stop and ask before block replacement, except for the required text-preserving H1/H2 native-numbering update.
5. Never silently fall back to delete/recreate or whole-document overwrite.
6. Re-fetch changed sections and verify unrelated content is unchanged.

For an empty remote, create sections selectively; omit Links and Release Checklist until their policies are satisfied.

## SVG diagram sync

- Resolve wiki URLs to their document and read the matching document skill's media/upload references before choosing commands. Confirm SVG support for the intended block type; do not infer it from generic image-upload support.
- Sync the same verified SVG asset used by the local document. Do not send diagram-language fences for automatic whiteboard conversion or generate PNG alternatives.
- Fetch the target section and block IDs. List the exact diagram changes and obtain separate replacement authorization before modifying an existing diagram or migrating a whiteboard to SVG.
- Upload the SVG and use the returned media token or remote asset URL at the authorized location. A local filesystem image link is not a remote upload. Do not publish private assets at public URLs.
- Check current CLI help for targeted insertion. The media-insert shortcut defaults to document end, but can insert relative to a text selection; nested selections may place media at a top-level ancestor. Verify the exact insertion location, and use a targeted block operation or stop when selection-based placement cannot preserve the section.
- If inline SVG is unsupported, report that limit and ask before attaching or linking the SVG instead. Never silently rasterize it, change format, or claim inline preview succeeded.
- Keep existing whiteboards, tokens, section titles, and unrelated content intact unless their exact replacement was authorized. Preserve the old diagram until the uploaded SVG and its placement are verified.
- Re-fetch the updated section, verify the asset token or URL and unchanged unrelated blocks, and inspect the remote preview when supported. Verify uploaded asset bytes separately; do not treat unchanged Markdown or a successful upload as proof of a correct diagram.

## Rich-text fidelity

- Convert nested list markers to native nested lists; do not leave `<br>`, `•`, or `**` as literal content.
- Use native disclosure blocks only when the target API supports and round-trips them; otherwise use the prepared heading and code block.
- Give narrow columns only enough width for identifiers; give comparison/detail columns the remaining width.
- Re-fetch and verify structure, not only text.
