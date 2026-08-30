# Domain Docs

How engineering skills should consume this repository’s domain documentation.

## Layout

This is a single-context repository:

- `CONTEXT.md` contains the project glossary and domain model.
- `docs/adr/` contains architecture decision records.

These files are created lazily when terminology or architectural decisions
need to be recorded.

## Before exploring

Read `CONTEXT.md` and any ADRs relevant to the area being changed. If they do
not exist, proceed silently; do not require them before beginning ordinary
work.

## Use the glossary’s vocabulary

When output names a domain concept—in an issue title, proposal, hypothesis, or
test—use the term defined in `CONTEXT.md`. Do not drift to synonyms the glossary
explicitly avoids.

If a required concept is absent, reconsider whether the term belongs to the
project or note the gap for the domain-modeling skill.

## Flag ADR conflicts

If proposed work contradicts an existing ADR, surface it explicitly rather
than silently overriding it:

> _Contradicts ADR-0007, but worth reopening because…_
