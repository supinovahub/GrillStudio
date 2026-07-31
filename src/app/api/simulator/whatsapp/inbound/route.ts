import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";

import { getPreviewEnvironment } from "@/lib/environment";
import { wakeDurableWorker } from "@/lib/durable-worker";
import { createRequestContext, writeLog } from "@/lib/observability";
import { createAdminClient } from "@/lib/supabase/admin";
import {
  simulatorConnectionId,
  simulatorInboundAdapter,
} from "@/lib/whatsapp/simulator";

export const runtime = "nodejs";
const maximumPayloadBytes = 64 * 1024;

function authorized(request: Request): boolean {
  const configured = process.env.SIMULATOR_INGRESS_TOKEN;
  const supplied = request.headers.get("authorization")?.replace(
    /^Bearer\s+/i,
    "",
  );
  if (!configured || configured.length < 32 || !supplied) return false;

  const expectedBuffer = Buffer.from(configured);
  const suppliedBuffer = Buffer.from(supplied);
  return (
    expectedBuffer.length === suppliedBuffer.length &&
    timingSafeEqual(expectedBuffer, suppliedBuffer)
  );
}

async function readLimitedJson(request: Request): Promise<unknown> {
  if (
    !request.headers
      .get("content-type")
      ?.toLowerCase()
      .startsWith("application/json")
  ) {
    throw new Error("unsupported content type");
  }

  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (declaredLength > maximumPayloadBytes) {
    throw new Error("payload too large");
  }
  if (!request.body) throw new Error("empty payload");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximumPayloadBytes) {
      await reader.cancel();
      throw new Error("payload too large");
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

export async function POST(request: Request) {
  const context = createRequestContext();
  try {
    getPreviewEnvironment();
  } catch {
    writeLog("simulator.inbound", { ...context, outcome: "denied" });
    return NextResponse.json({ error: "Não encontrado." }, { status: 404 });
  }

  if (!authorized(request)) {
    writeLog("simulator.inbound", { ...context, outcome: "denied" });
    return NextResponse.json({ error: "Não autorizado." }, { status: 401 });
  }

  try {
    const raw = await readLimitedJson(request);
    const connectionId = simulatorConnectionId(raw);
    const normalizedEvent = simulatorInboundAdapter.normalize(raw);
    const supabase = createAdminClient();
    const { data, error } = await supabase.rpc("ingest_simulated_inbound", {
      normalized_event: normalizedEvent,
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
      target_connection_id: connectionId,
    });

    if (error) {
      writeLog("simulator.inbound", { ...context, outcome: "failed" });
      return NextResponse.json(
        { error: "Inbound sintético recusado." },
        { status: 422 },
      );
    }

    // Acceptance is already committed. Wake is intentionally best-effort;
    // the 5-second durable recovery path processes the same queue.
    void wakeDurableWorker(context);
    writeLog("simulator.inbound", { ...context, outcome: "accepted" });
    return NextResponse.json(data, { status: 202 });
  } catch (error) {
    writeLog("simulator.inbound", { ...context, outcome: "denied" });
    if (error instanceof Error && error.message === "payload too large") {
      return NextResponse.json(
        { error: "Payload acima do limite." },
        { status: 413 },
      );
    }
    return NextResponse.json(
      { error: "Payload sintético inválido." },
      { status: 400 },
    );
  }
}
