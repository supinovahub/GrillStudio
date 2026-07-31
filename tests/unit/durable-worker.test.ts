import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { wakeDurableWorker } from "@/lib/durable-worker";

const originalEnvironment = {
  durableWorkerWakeSecret: process.env.DURABLE_WORKER_WAKE_SECRET,
  serviceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL,
};

describe("durable worker wake client", () => {
  beforeEach(() => {
    process.env.DURABLE_WORKER_WAKE_SECRET =
      "synthetic-durable-worker-wake-secret-0001";
    process.env.SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role";
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://preview.invalid";
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    process.env.DURABLE_WORKER_WAKE_SECRET =
      originalEnvironment.durableWorkerWakeSecret;
    process.env.SUPABASE_SERVICE_ROLE_KEY =
      originalEnvironment.serviceRoleKey;
    process.env.NEXT_PUBLIC_SUPABASE_URL = originalEnvironment.supabaseUrl;
  });

  it("envia o segredo dedicado sem expô-lo no corpo", async () => {
    const workerFetch = vi.fn().mockResolvedValue(new Response(null));
    vi.stubGlobal("fetch", workerFetch);

    await expect(
      wakeDurableWorker({
        correlationId: "correlation-id",
        traceId: "trace-id",
      }),
    ).resolves.toBe(true);

    expect(workerFetch).toHaveBeenCalledWith(
      "https://preview.invalid/functions/v1/durable-worker",
      expect.objectContaining({
        body: "{}",
        headers: expect.objectContaining({
          "x-durable-worker-wake-secret":
            "synthetic-durable-worker-wake-secret-0001",
        }),
      }),
    );
  });

  it("falha fechado quando o segredo dedicado não está configurado", async () => {
    delete process.env.DURABLE_WORKER_WAKE_SECRET;
    const workerFetch = vi.fn();
    vi.stubGlobal("fetch", workerFetch);

    await expect(
      wakeDurableWorker({
        correlationId: "correlation-id",
        traceId: "trace-id",
      }),
    ).resolves.toBe(false);
    expect(workerFetch).not.toHaveBeenCalled();
  });

  it("converte falha HTTP do wake em resultado best-effort", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response(null, { status: 503 })),
    );

    await expect(
      wakeDurableWorker({
        correlationId: "correlation-id",
        traceId: "trace-id",
      }),
    ).resolves.toBe(false);
  });
});
