# PROTOTYPE — OpenAI model homologation

> Throwaway branch artifact. Do not copy this terminal shell into the product.

## Question

Can one small, reproducible harness make the Pedro model contract and recovery
state machine concrete enough to decide which failures may retry or fall back
without duplicating a tool effect or a WhatsApp reply?

This repository has no application runtime yet. The prototype therefore uses
plain Node.js 22, the runtime already approved in the product architecture, and
has no dependencies.

## Run

Validate the local contract, synthetic case catalog, and recovery matrix:

```bash
node prototypes/openai-model-homologation/harness.mjs --local
```

Drive the recovery state interactively:

```bash
node prototypes/openai-model-homologation/harness.mjs
```

Run a deliberately bounded live smoke test after supplying a development API
key through the environment:

```bash
OPENAI_API_KEY=... node prototypes/openai-model-homologation/harness.mjs \
  --live \
  --confirm-live \
  --models=gpt-5.6-sol \
  --runs=1 \
  --max-calls=109
```

The key is read only from `OPENAI_API_KEY`; it is never printed or written.
Live mode uses only synthetic Portuguese inputs, sets `store: false`, performs
no external tool effect, and prints JSON results to stdout. The harness makes
two calls per semantic case: one strict decision-envelope call and one actual
tool-selection call with the complete ten-tool catalog. It also makes nine
technical calls per model for the full strict catalog, four invalid schemas,
manual continuity replay, buffered streaming, and incomplete-output
classification.

Five repetitions per scenario are required for production homologation;
`--runs=1` is only a smoke test. A complete three-model run plans 1,527 calls,
so the command refuses live execution unless `--confirm-live` is present and
the plan fits the explicit `--max-calls` cap. Review current pricing and the
resulting cost before raising that cap.

## What this prototype does

- declares strict JSON Schemas for the Pedro decision and all ten proposed
  tools;
- keeps `parallel_tool_calls` disabled for the side-effecting tool catalog;
- validates a catalog of 50 distinct synthetic cases without contacting
  OpenAI;
- exercises a pure recovery decision function over transient failures,
  structural failures, partial replies, and tool-effect phases;
- can probe all ten tools with the Responses API and score schema, next action,
  exact qualification fields, accepted synthetic values, tool selection,
  domain-constrained arguments, prohibited actions, latency, tokens and
  estimated cost;
- contains live probes for invalid schemas, manual multi-turn replay with
  `store: false`, buffered SSE, and incomplete-response classification;
- emits gate inputs, but never auto-approves a profile; blind human `pt-BR`
  review, including every critical reply for prohibited claims, and owner
  approval remain external.

## What it deliberately does not do

- send WhatsApp messages;
- create or mutate GrillStudio records;
- use real leads, conversations, phone numbers, credentials, or production
  knowledge;
- approve a model from one smoke test;
- stream content to a lead before the complete response passes policy checks;
- persist provider-side response state or use `previous_response_id`;
- implement the production orchestrator.
