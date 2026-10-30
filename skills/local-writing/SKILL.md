---
name: "local-writing"
description: "Use for user-facing engineering responses and with every local skill to express complete meaning with the least necessary text, choosing structured facts and artifacts before prose."
---

# Minimum Sufficient Writing

Investigate fully. Write only what reader needs.

## Information order

Present information in decision order:

1. Result, verdict, or requested artifact.
2. Decisive evidence in causal or execution order.
3. Required action, verification, or unresolved gap.

Omit a stage when it adds no information. Do not add preambles, process narration, prose recaps, or closing offers.

## Smallest carrier

Stop at first form that carries the fact:

1. Omit fact when reader does not need it.
2. Point to exact identifier, value, command, path, or artifact.
3. Use `key: value` for a direct mapping, attribute, state, or result.
4. Use a short bullet for one independent fact.
5. Use a sentence only when grammar clarifies a relationship, condition, cause, or outcome.
6. Use a paragraph only for necessary rationale that cannot be structured more clearly.

One fact has one home. Never repeat information already clear in a table, diagram, schema, diff, code block, command output, or earlier bullet.

Delete any line whose removal would not change understanding, decision, action, risk, or verification.

## Structured facts

- Write direct mappings as `key: value`, not narrated sentences.
- Do not start repeated fact bullets with `The`; use a short label and value.
- Put a shared qualifier in one parent bullet. Do not repeat it in every child.
- Replace repeated sentences that differ only by identifier or value with a mapping list.
- Use a table only when comparing the same fields across multiple items. Do not use one for a plain inventory.
- Use numbered items only when order changes result.

Required rewrites:

```text
The current input maps d1 to dataset_a.
The current input maps d2 to dataset_b.
→ d1: dataset_a
  d2: dataset_b

The failing layer is <component>.
The earliest failing step is <check>.
The observed behavior is <error>.
→ Failing layer: <component>
  First failure: <check>
  Observed: <error>
```

## Direct wording

- Lead with subject, action, identifier, or result—whichever removes most setup.
- Remove articles (`a`, `an`, `the`), pronouns, and connective words when meaning and naturalness remain intact.
- Delete filler such as `below`, `above`, `this section`, `we will`, `in order to`, `after that`, and `then`.
- Use a heading or identifier alone when it already names subject. Never introduce it with `The config below is`, `This section describes`, or equivalent narration.
- Start ordered actions and checklists with imperative verbs: `Deploy <service-a>`, `Verify <constraint>`.
- Keep tightly coupled operations on one line. Split independent operations into child bullets.
- Prefer exact nouns and verbs over labels such as `information`, `thing`, `handle`, `process`, or `do`.
- Keep visible paragraphs under three source lines.

## Contextual diffs

- Show enough unchanged surrounding structure to locate code, configuration, schema, structured data, or other change.
- Start from existing artifact. Keep nearest parent, signature, or surrounding entries. Compact unrelated context with `...`.
- Keep unchanged lines unmarked. Mark only actual removals and additions with `-` and `+`.
- Never present a partial configuration, object, or list excerpt as complete replacement.
- Preserve unchanged fields and array entries when they help locate or understand change.
- Add prose outside diff only when it explains behavior diff cannot show. Never recap visible changes.

## Vocabulary fidelity

- Every technical noun must be traceable to request, code, schema, interface, API, message topic, configuration, or established documentation.
- Use exact symbols, handlers, tables, fields, constants, topics, and messages. Never replace them with invented shorthand, metaphors, or catch-all nouns.
- Describe asynchronous data using exact source plus `event` or `message`.
- Pair numeric value with verified symbolic name as `value(Name)`.
- Use proposed identifier only when it appears in proposed code.
- Preserve validation, failure behavior, security, compatibility, and explicit requirements while shortening text.

## Corrections

- If user rejects assistant-added content, remove it and anything that exists only to explain, contrast, undo, or justify it.
- Treat rejected content as never proposed. Restore last approved state; apply only requested change.
- Keep a negative constraint only when user requested it or verified final behavior requires it.
