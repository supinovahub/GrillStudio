import { describe, expect, it, vi } from "vitest";

import {
  constantTimeSecretEqual,
  createDurableWorkerHandler,
} from "../../supabase/functions/_shared/durable-worker-handler";

const wakeSecret = "synthetic-durable-worker-wake-secret-0001";

function environment(name: string): string | undefined {
  return {
    DURABLE_WORKER_WAKE_SECRET: wakeSecret,
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service-role",
    SUPABASE_URL: "https://preview.invalid",
  }[name];
}

describe("durable worker Edge boundary", () => {
  it("compara o segredo dedicado sem aceitar aproximações", async () => {
    await expect(
      constantTimeSecretEqual(wakeSecret, wakeSecret),
    ).resolves.toBe(true);
    await expect(
      constantTimeSecretEqual(wakeSecret, `${wakeSecret}-divergent`),
    ).resolves.toBe(false);
    await expect(constantTimeSecretEqual(wakeSecret, null)).resolves.toBe(
      false,
    );
  });

  it.each([
    ["JWT de usuário sem segredo", null],
    ["JWT anônimo com segredo incorreto", "wrong-secret"],
  ])("recusa com 403 %s", async (_label, suppliedSecret) => {
    const workerFetch = vi.fn();
    const handler = createDurableWorkerHandler(environment, workerFetch);
    const headers = new Headers({
      authorization: "Bearer valid-non-service-jwt",
    });
    if (suppliedSecret) {
      headers.set("x-durable-worker-wake-secret", suppliedSecret);
    }

    const response = await handler(
      new Request("https://preview.invalid/functions/v1/durable-worker", {
        method: "POST",
        headers,
      }),
    );

    expect(response.status).toBe(403);
    expect(workerFetch).not.toHaveBeenCalled();
  });

  it("executa o RPC somente com o segredo dedicado correto", async () => {
    const workerFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ processed: 1 }), { status: 200 }),
    );
    const handler = createDurableWorkerHandler(environment, workerFetch);
    const response = await handler(
      new Request("https://preview.invalid/functions/v1/durable-worker", {
        method: "POST",
        headers: {
          authorization: "Bearer gateway-validated-jwt",
          "x-durable-worker-wake-secret": wakeSecret,
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(workerFetch).toHaveBeenCalledOnce();
    expect(workerFetch).toHaveBeenCalledWith(
      "https://preview.invalid/rest/v1/rpc/run_durable_workers",
      expect.objectContaining({
        method: "POST",
        headers: expect.objectContaining({
          authorization: "Bearer synthetic-service-role",
        }),
      }),
    );
  });
});
