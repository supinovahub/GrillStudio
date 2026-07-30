# Issue tracker: GitHub

Issues and PRDs for this repository live as GitHub Issues in `supinovahub/GrillStudio`.

## Access

- Prefer the connected GitHub app when it provides the required operation.
- Use the `gh` CLI for issue dependency, sub-issue, label, comment, or query operations not exposed by the connected app.
- Infer the repository from `git remote -v` when working in a local checkout.

## Conventions

- Read the complete issue body and comments before acting.
- Use the domain vocabulary from `CONTEXT.md`.
- Apply `ready-for-agent` only after the work is fully specified and its blockers are explicit.
- One implementation ticket must be one narrow, complete, independently verifiable vertical slice.
- Do not close or modify a parent specification issue when completing a child ticket.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## When a skill says “publish to the issue tracker”

Create a GitHub issue in `supinovahub/GrillStudio`.

## When a skill says “fetch the relevant ticket”

Fetch the issue body, comments, labels, dependencies and current state.

## Wayfinding operations

- **Map:** one issue labelled `wayfinder:map`.
- **Child:** a GitHub sub-issue where available; otherwise a task-list entry in the map plus `Part of #<map>` in the child.
- **Types:** `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, `wayfinder:task`.
- **Blocking:** use native GitHub issue dependencies where available; otherwise use a `Blocked by:` line.
- **Frontier:** an open, unassigned child with no open blockers.
- **Claim:** assign the issue before work.
- **Resolve:** record the answer, close the child, and add a short linked gist to the map’s Decisions-so-far section.

