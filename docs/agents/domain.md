# Domain docs

This is a single-context repository.

## Before exploring

- Read `CONTEXT.md`.
- Read the ADRs in `docs/adr/` that touch the area being changed.
- Read `docs/product/README-Pacote-Tecnico-v1.md` and follow its source-of-truth links when product behavior is relevant.

If a file does not exist, proceed without inventing its contents.

## Use the glossary vocabulary

Use terms exactly as defined in `CONTEXT.md` in issue titles, code, tests, UI copy and technical explanations. Do not drift to synonyms listed under `_Avoid_`.

If a required concept is absent, use `domain-modeling` to resolve it before adding competing vocabulary.

## Flag conflicts

If proposed work contradicts an ADR or product document, surface the conflict explicitly with the document name and decision. Do not override it silently.

## Layout

```text
/
├── CONTEXT.md
├── docs/
│   ├── adr/
│   ├── agents/
│   └── product/
└── src/
```

