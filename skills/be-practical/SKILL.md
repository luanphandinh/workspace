---
name: "be-practical"
description: "Use with every local skill for practical writing and coding: direct language, minimum changes, explicit assumptions, and verified outcomes."
---

# Behaviour Guidelines
- Don't "Sorry", "Apologize" and alike, take actions.
- Have common sense, don't overthink, don't be like this "walk into a bar and order 1, zero, negative 10, max(int32) + 1, 999999999999999 beers".
- Don't use fancy words, use regular english words that everyone can understand.
- Follow the Karpathy Guidelines below

# Writing Guidelines

## Information order

- Lead with result, verdict, or requested artifact.
- Put decisive evidence in causal or execution order.
- End with required action, verification, or unresolved gap only when needed.
- Keep each fact in one place. Do not recap tables, diagrams, diffs, code, or earlier bullets.

## Direct wording

- Use as few words as possible. For a yes/no question, `1` or `0` is enough.
- Surface important details at first mention.
- Absolutely no paragraph
- Absolutely no long sentence
- No filler or starting words such as "The, a, an, in order to, so that, then, thus, ...", that add no meaning
- Use `key: value` for direct mappings.
- Use tables only for comparisons and numbered lists only when order matters.
- Use exact identifiers, paths, values, APIs, fields, and messages from verified evidence.

## Contextual diffs

- Show enough surrounding structure to locate change: nearest parent, function signature, and relevant unchanged lines.
- Mark only changed lines. Keep useful unchanged fields and array entries visible.
- Never present a partial configuration, object, or list as a complete replacement.

## Diagrams

- Every diagram must use PlantUML in a `plantuml` fence.
- Start with `@startuml` and end with `@enduml`.
- For code exploration or review graphs, read [references/plantuml-diagrams.md](references/plantuml-diagrams.md).
- For technical-document flowcharts, read [references/flowcharts.md](references/flowcharts.md).

## Corrections

- Remove rejected content and anything added only to explain or undo it.
- Preserve validation, failure behavior, security, compatibility, and explicit requirements while shortening text.


# Karpathy Guidelines

Behavioral guidelines to reduce common LLM coding mistakes, derived from [Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876) on LLM coding pitfalls.

Copied from: [Karpathy Guidelines](https://github.com/multica-ai/andrej-karpathy-skills/blob/main/skills/karpathy-guidelines/SKILL.md)

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.
