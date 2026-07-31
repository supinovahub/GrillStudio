import { headers } from "next/headers";

import { createRequestContext, type RequestContext } from "@/lib/observability";

export async function getRequestContext(): Promise<RequestContext> {
  const requestHeaders = await headers();
  const traceId = requestHeaders.get("x-trace-id");
  const correlationId = requestHeaders.get("x-correlation-id");

  if (traceId && correlationId) {
    return { correlationId, traceId };
  }

  return createRequestContext();
}
