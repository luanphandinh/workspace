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

## Protected sections

- `Links`: remote source of truth. Never create, replace, reorder, delete, or pull it during normal sync.
- `Release Checklist`: show the proposed change and obtain separate explicit confirmation.
- Diagrams/whiteboards: list changed diagram sections and obtain separate explicit replacement authorization.

A normal sync request authorizes exact-text updates and new unprotected sections only. It does not authorize block replacement or protected updates.

## Write strategy

1. Fetch the exact current section.
2. Use exact text replacement for an existing section.
3. Insert only when the section is new.
4. If exact replacement fails, stop and ask before block replacement.
5. Never silently fall back to delete/recreate or whole-document overwrite.
6. Re-fetch changed sections and verify unrelated content is unchanged.

For an empty remote, create sections selectively; omit Links and Release Checklist until their policies are satisfied.

## Native whiteboards

- Resolve wiki URLs to their document and use the matching `lark-cli` skill before choosing commands.
- Fetch the outline, then the target section with IDs, and prefer exact `str_replace`.
- Keep diagrams native. Pipe local Mermaid through stdin to `lark-cli whiteboard +update`; do not create or upload SVG/PNG intermediates.
- Preserve the title, whiteboard block, and whiteboard token. Replace board contents only after diagram authorization.
- Represent each node as one native shape containing its label. Attach connector endpoints to source and target object IDs.
- After update, query with both `--output_as code` and `--output_as raw`. Verify Mermaid syntax, shape text, connector attachments, and unchanged unrelated content.
- If OpenAPI conversion is needed, pipe converter output directly into `lark-cli`.

## Rich-text fidelity

- Convert nested list markers to native nested lists; do not leave `<br>`, `•`, or `**` as literal content.
- Keep named implementation blocks collapsed where the platform supports it.
- Give narrow columns only enough width for identifiers; give comparison/detail columns the remaining width.
- Re-fetch and verify structure, not only text.
