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
  --models=gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-luna \
  --runs=1
```

The key is read only from `OPENAI_API_KEY`; it is never printed or written.
Live mode uses only synthetic Portuguese inputs, sets `store: false`, performs
no external tool effect, and prints JSON results to stdout. Five repetitions
per scenario are required for production homologation; `--runs=1` is only a
smoke test. The command refuses live execution unless `--confirm-live` is
present.

## What this prototype does

- declares strict JSON Schemas for the Pedro decision and all ten proposed
  tools;
- keeps `parallel_tool_calls` disabled for the side-effecting tool catalog;
- validates synthetic cases without contacting OpenAI;
- exercises a pure recovery decision function over transient failures,
  structural failures, partial replies, and tool-effect phases;
- can probe a model with the Responses API and record the returned model,
  schema result, action/tool match, latency, token usage, and estimated cost.

## What it deliberately does not do

- send WhatsApp messages;
- create or mutate GrillStudio records;
- use real leads, conversations, phone numbers, credentials, or production
  knowledge;
- approve a model from one smoke test;
- stream content to a lead before the complete response passes policy checks;
- implement the production orchestrator.
