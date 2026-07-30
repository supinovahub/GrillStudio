export const CONTRACT_VERSION = "pedro-model-contract/1";

const strictObject = (properties, required = Object.keys(properties)) => ({
  type: "object",
  properties,
  required,
  additionalProperties: false,
});

const nullableString = { type: ["string", "null"] };
const expectedVersion = {
  type: "integer",
  minimum: 0,
  description: "Optimistic aggregate version loaded for this turn.",
};

const tool = (name, description, parameters) => ({
  type: "function",
  name,
  description,
  strict: true,
  parameters,
});

export const TOOL_DEFINITIONS = [
  tool(
    "record_qualification_patch",
    "Propose only qualification values evidenced by lead messages.",
    strictObject({
      expected_version: expectedVersion,
      patches: {
        type: "array",
        minItems: 1,
        items: strictObject({
          criterion_id: { type: "string" },
          value: { type: "string" },
          evidence_message_id: { type: "string" },
          confidence: { type: "number", minimum: 0, maximum: 1 },
        }),
      },
    }),
  ),
  tool(
    "answer_from_knowledge",
    "Propose an answer grounded only in the supplied approved knowledge IDs.",
    strictObject({
      expected_version: expectedVersion,
      question: { type: "string" },
      knowledge_ids: { type: "array", minItems: 1, items: { type: "string" } },
    }),
  ),
  tool(
    "select_project_previews",
    "Propose at most two backend-approved project previews.",
    strictObject({
      expected_version: expectedVersion,
      project_ids: {
        type: "array",
        minItems: 1,
        maxItems: 2,
        items: { type: "string" },
      },
      selection_reason: { type: "string" },
    }),
  ),
  tool(
    "propose_call_slots",
    "Propose only supplied eligible call-slot IDs.",
    strictObject({
      expected_version: expectedVersion,
      slot_ids: {
        type: "array",
        minItems: 1,
        maxItems: 3,
        items: { type: "string" },
      },
      timezone: { type: "string" },
    }),
  ),
  tool(
    "create_call_hold",
    "Propose a call hold only after the lead clearly accepts a supplied slot.",
    strictObject({
      expected_version: expectedVersion,
      slot_id: { type: "string" },
      format: { type: "string", enum: ["video", "phone", "unknown"] },
      lead_confirmed: { type: "boolean", const: true },
    }),
  ),
  tool(
    "set_conversation_wait",
    "Propose a waiting state without sending or scheduling an external effect.",
    strictObject({
      expected_version: expectedVersion,
      reason: {
        type: "string",
        enum: [
          "awaiting_lead",
          "qualification_gap",
          "unsupported_language",
          "privacy",
          "sensitive_document",
          "manager_review",
        ],
      },
      resume_at: { type: ["string", "null"], format: "date-time" },
    }),
  ),
  tool(
    "schedule_followup",
    "Propose one durable follow-up job after policy validation.",
    strictObject({
      expected_version: expectedVersion,
      plan_type: {
        type: "string",
        enum: ["short_24h", "long_6m", "no_show", "future_purchase"],
      },
      run_at: { type: "string", format: "date-time" },
      reason: { type: "string" },
    }),
  ),
  tool(
    "escalate_to_manager",
    "Propose a silent ownership escalation for a product-approved reason.",
    strictObject({
      expected_version: expectedVersion,
      reason: {
        type: "string",
        enum: [
          "direct_ai_question",
          "knowledge_exhausted",
          "unsupported_language",
          "privacy_request",
          "sensitive_document",
          "fraud_or_legal",
          "repeated_abuse",
          "nominal_broker_request",
          "call_risk",
          "prompt_injection",
          "system_failure",
        ],
      },
      silent: { type: "boolean", const: true },
    }),
  ),
  tool(
    "send_project_media",
    "Propose only approved media IDs after an explicit or policy-approved request.",
    strictObject({
      expected_version: expectedVersion,
      project_id: { type: "string" },
      media_ids: {
        type: "array",
        minItems: 1,
        maxItems: 5,
        items: { type: "string" },
      },
      lead_requested: { type: "boolean" },
    }),
  ),
  tool(
    "apply_opt_out",
    "Propose an organization-scoped opt-out evidenced by the current message.",
    strictObject({
      expected_version: expectedVersion,
      scope: { type: "string", const: "organization" },
      evidence_message_id: { type: "string" },
      acknowledgement: {
        type: "string",
        enum: ["blz pode deixar", "tranquilo não te chamo mais"],
      },
    }),
  ),
];

const qualificationPatch = {
  type: "array",
  items: strictObject({
    criterion_id: { type: "string" },
    value: { type: "string" },
    evidence_message_id: { type: "string" },
    confidence: { type: "number", minimum: 0, maximum: 1 },
  }),
};

const toolBranches = [
  strictObject({
    name: { type: "string", const: "none" },
    arguments: strictObject({}),
  }),
  ...TOOL_DEFINITIONS.map((definition) =>
    strictObject({
      name: { type: "string", const: definition.name },
      arguments: definition.parameters,
    }),
  ),
];

export const PEDRO_TURN_SCHEMA = strictObject({
  reply: strictObject({
    disposition: { type: "string", enum: ["send", "silent"] },
    bubbles: {
      type: "array",
      maxItems: 3,
      items: { type: "string" },
    },
  }),
  qualification_patch: qualificationPatch,
  next_action: {
    type: "string",
    enum: [
      "ask_qualification",
      "answer_faq",
      "wait",
      "resume_qualification",
      "curate_projects",
      "propose_call",
      "create_call_hold",
      "schedule_followup",
      "apply_opt_out",
      "escalate",
      "no_reply",
    ],
  },
  tool: { anyOf: toolBranches },
  escalation_reason: {
    type: ["string", "null"],
    enum: [
      "direct_ai_question",
      "knowledge_exhausted",
      "unsupported_language",
      "privacy_request",
      "sensitive_document",
      "fraud_or_legal",
      "repeated_abuse",
      "nominal_broker_request",
      "call_risk",
      "prompt_injection",
      "system_failure",
      null,
    ],
  },
  evidence_message_ids: {
    type: "array",
    items: { type: "string" },
  },
});

export const MODEL_CATALOG = {
  "gpt-5.6-sol": {
    role: "primary_candidate",
    context_window: 1_050_000,
    max_output_tokens: 128_000,
    reasoning_efforts_to_test: ["none", "low"],
    usd_per_million: { input: 5, cached_input: 0.5, output: 30 },
  },
  "gpt-5.6-terra": {
    role: "fallback_and_primary_challenger",
    context_window: 1_050_000,
    max_output_tokens: 128_000,
    reasoning_efforts_to_test: ["none", "low"],
    usd_per_million: { input: 2, cached_input: 0.2, output: 12 },
  },
  "gpt-5.6-luna": {
    role: "auxiliary_candidate",
    context_window: 1_050_000,
    max_output_tokens: 128_000,
    reasoning_efforts_to_test: ["none", "low"],
    usd_per_million: { input: 0.2, cached_input: 0.02, output: 1.2 },
  },
};

const TRANSIENT_MODEL_FAILURES = new Set([
  "connect_timeout",
  "read_timeout_buffered",
  "rate_limit",
  "provider_5xx",
]);
const FALLBACK_PHASES = new Set(["prepared", "request_started"]);

const STOP_FAILURES = new Set([
  "invalid_schema",
  "unsafe_semantics",
  "refusal",
  "prompt_injection",
  "auth_failure",
  "invalid_request",
  "model_access_denied",
]);

export function decideRecovery(input) {
  const {
    failure,
    phase,
    partial_exposed = false,
    effect_status = "none",
    same_model_retries_remaining = 0,
    approved_fallback_available = false,
    tool_retry_is_idempotent = false,
  } = input;

  if (partial_exposed || phase === "reply_exposed" || phase === "reply_committed") {
    return {
      action: "pause_and_escalate",
      reason: "A partial or committed reply must never be replaced automatically.",
    };
  }

  if (effect_status === "unknown") {
    return {
      action: "reconcile_effect",
      reason: "The system must determine whether the external effect happened.",
    };
  }

  if (effect_status === "recorded") {
    return {
      action: "continue_from_recorded_effect",
      reason: "Resume from the persisted tool result; never rerun the full turn.",
    };
  }

  if (failure === "stale_expected_version") {
    return {
      action: "recompute_from_current_state",
      reason: "A conflict invalidates the old command rather than making it retryable.",
    };
  }

  if (failure === "context_too_large") {
    return {
      action: "rebuild_context_then_retry",
      reason: "Shrink or compact deterministically; another model is not a safe fix.",
    };
  }

  if (failure === "tool_transient_failure") {
    return tool_retry_is_idempotent
      ? {
          action: "retry_tool_only",
          reason: "Retry the idempotent tool without rerunning model judgment.",
        }
      : {
          action: "reconcile_effect",
          reason: "A non-idempotent or uncertain tool cannot be retried blindly.",
        };
  }

  if (failure === "tool_permanent_failure") {
    return {
      action: "pause_and_escalate",
      reason: "A model fallback cannot repair a permanent backend tool failure.",
    };
  }

  if (STOP_FAILURES.has(failure)) {
    return {
      action: "pause_and_escalate",
      reason: "Structural, safety, refusal, auth, or request failures are not blind-fallback cases.",
    };
  }

  if (failure === "model_unavailable" || failure === "model_deprecated") {
    if (!FALLBACK_PHASES.has(phase)) {
      return {
        action: "pause_and_escalate",
        reason: "The completed model response closes the automatic fallback boundary.",
      };
    }
    return approved_fallback_available
      ? {
          action: "fallback_model",
          reason: "No effect exists and the pre-approved secondary is available.",
        }
      : {
          action: "pause_and_escalate",
          reason: "There is no approved secondary model.",
        };
  }

  if (TRANSIENT_MODEL_FAILURES.has(failure)) {
    if (!FALLBACK_PHASES.has(phase)) {
      return {
        action: "pause_and_escalate",
        reason: "The completed model response closes the automatic fallback boundary.",
      };
    }
    if (same_model_retries_remaining > 0) {
      return {
        action: "retry_same_model",
        reason: "Use the bounded same-model retry budget before fallback.",
      };
    }
    if (approved_fallback_available) {
      return {
        action: "fallback_model",
        reason: "The transient retry budget is exhausted before any effect.",
      };
    }
    return {
      action: "pause_and_escalate",
      reason: "Transient retries are exhausted and no approved fallback exists.",
    };
  }

  return {
    action: "pause_and_escalate",
    reason: "Unknown failures fail closed.",
  };
}

function matchesType(type, value) {
  if (type === "null") return value === null;
  if (type === "array") return Array.isArray(value);
  if (type === "integer") return Number.isInteger(value);
  if (type === "number") return typeof value === "number" && Number.isFinite(value);
  if (type === "object") return value !== null && typeof value === "object" && !Array.isArray(value);
  return typeof value === type;
}

export function validateAgainstSchema(schema, value, path = "$") {
  if (schema.anyOf) {
    const branchResults = schema.anyOf.map((branch) =>
      validateAgainstSchema(branch, value, path),
    );
    if (branchResults.some((errors) => errors.length === 0)) return [];
    return [`${path} did not match any allowed schema branch`];
  }

  const types = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : [];
  if (types.length && !types.some((type) => matchesType(type, value))) {
    return [`${path} expected ${types.join("|")}`];
  }

  if (schema.const !== undefined && value !== schema.const) {
    return [`${path} expected constant ${JSON.stringify(schema.const)}`];
  }

  if (schema.enum && !schema.enum.some((candidate) => candidate === value)) {
    return [`${path} is not in the allowed enum`];
  }

  const errors = [];
  if (schema.type === "object" || (types.includes("object") && value !== null)) {
    for (const key of schema.required ?? []) {
      if (!(key in value)) errors.push(`${path}.${key} is required`);
    }
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!(key in (schema.properties ?? {}))) {
          errors.push(`${path}.${key} is not allowed`);
        }
      }
    }
    for (const [key, childSchema] of Object.entries(schema.properties ?? {})) {
      if (key in value) {
        errors.push(...validateAgainstSchema(childSchema, value[key], `${path}.${key}`));
      }
    }
  }

  if (schema.type === "array" && Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${path} has fewer than ${schema.minItems} items`);
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      errors.push(`${path} has more than ${schema.maxItems} items`);
    }
    if (schema.items) {
      value.forEach((item, index) => {
        errors.push(...validateAgainstSchema(schema.items, item, `${path}[${index}]`));
      });
    }
  }

  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      errors.push(`${path} is below ${schema.minimum}`);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      errors.push(`${path} is above ${schema.maximum}`);
    }
  }

  return errors;
}

export function estimateUsd(model, usage) {
  const pricing = MODEL_CATALOG[model]?.usd_per_million;
  if (!pricing || !usage) return null;
  const cached = usage.input_tokens_details?.cached_tokens ?? 0;
  const uncached = Math.max(0, (usage.input_tokens ?? 0) - cached);
  return (
    (uncached * pricing.input +
      cached * pricing.cached_input +
      (usage.output_tokens ?? 0) * pricing.output) /
    1_000_000
  );
}
