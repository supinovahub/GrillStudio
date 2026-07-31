import { randomUUID } from "node:crypto";

export type RequestContext = {
  correlationId: string;
  traceId: string;
};

type LogFields = RequestContext & {
  outcome: "accepted" | "denied" | "failed" | "succeeded";
  unsafe?: unknown;
};

export function createRequestContext(): RequestContext {
  return {
    correlationId: randomUUID(),
    traceId: randomUUID(),
  };
}

export function writeLog(event: string, fields: LogFields): void {
  console.info(
    JSON.stringify({
      correlation_id: fields.correlationId,
      event,
      outcome: fields.outcome,
      trace_id: fields.traceId,
    }),
  );
}
