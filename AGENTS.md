# GrillStudio agent instructions

## Source of truth

Before planning or implementation, read `CONTEXT.md`, the index at `docs/product/README-Pacote-Tecnico-v1.md`, and the ADRs relevant to the area being changed.

Product behavior is governed by this order:

1. The user's latest explicit instruction.
2. `docs/product/Especificacao-do-Produto-v1.md`.
3. The remaining documents under `docs/product/`.
4. Accepted ADRs under `docs/adr/`.

Do not silently reinterpret an approved product decision. Surface genuine conflicts with their exact source.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues for `supinovahub/GrillStudio`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five canonical Matt Pocock triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository with one root `CONTEXT.md` and system-wide ADRs in `docs/adr/`. See `docs/agents/domain.md`.

## Safety

- Treat staging and production as separate systems.
- Never send staging messages to real leads.
- Never mutate production infrastructure, data, campaigns, WhatsApp connections, or AI activation without explicit user authorization.
- Preserve unrelated user changes.
- Keep secrets out of the browser, repository, logs, fixtures, screenshots, and issue bodies.

