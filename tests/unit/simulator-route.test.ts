import { beforeEach, describe, expect, it, vi } from "vitest";

const {
  createAdminClient,
  getPreviewEnvironment,
  rpc,
  wakeDurableWorker,
  writeLog,
} = vi.hoisted(() => {
  const rpc = vi.fn();
  return {
    createAdminClient: vi.fn(() => ({ rpc })),
    getPreviewEnvironment: vi.fn(),
    rpc,
    wakeDurableWorker: vi.fn(),
    writeLog: vi.fn(),
  };
});

vi.mock("@/lib/durable-worker", () => ({ wakeDurableWorker }));
vi.mock("@/lib/environment", () => ({ getPreviewEnvironment }));
vi.mock("@/lib/observability", () => ({
  createRequestContext: () => ({
    correlationId: "correlation-id",
    traceId: "trace-id",
  }),
  writeLog,
}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient }));

import { POST } from "@/app/api/simulator/whatsapp/inbound/route";

const token = "synthetic-preview-route-token-000001";
const defaultBody = JSON.stringify({
  connection_id: "f50f0542-fdf2-4979-8865-d49a1aa52c93",
  chat: { id: "opaque-chat" },
  identity: {
    aliases: [{ type: "simulator_user", value: "opaque-user" }],
  },
  message: {
    id: "opaque-message",
    kind: "text",
    text: "Mensagem sintética",
  },
});

function request(body = defaultBody) {
  return new Request("http://localhost/api/simulator/whatsapp/inbound", {
    body,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    method: "POST",
  });
}

describe("simulator inbound route boundary", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    process.env.SIMULATOR_INGRESS_TOKEN = token;
    getPreviewEnvironment.mockReturnValue({
      branchName: "agent/t05-issue-17",
      label: "Preview segura — PR #65",
      prNumber: 65,
      projectRef: "egzxqgplyjtvykvdgepv",
      tone: "preview",
    });
    rpc.mockResolvedValue({ data: { status: "received" }, error: null });
    wakeDurableWorker.mockResolvedValue(true);
  });

  it.each(["main", "mismatch", "ambiguous"])(
    "não alcança o RPC em ambiente %s",
    async () => {
      getPreviewEnvironment.mockImplementation(() => {
        throw new Error("not a matching Preview");
      });
      const response = await POST(request());
      expect(response.status).toBe(404);
      expect(createAdminClient).not.toHaveBeenCalled();
      expect(rpc).not.toHaveBeenCalled();
    },
  );

  it("chama somente o RPC sintético numa Preview correspondente", async () => {
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(rpc).toHaveBeenCalledOnce();
    expect(rpc).toHaveBeenCalledWith(
      "ingest_simulated_inbound",
      expect.objectContaining({
        normalized_event: expect.objectContaining({ provider: "simulator" }),
        raw_body: defaultBody,
        target_connection_id: "f50f0542-fdf2-4979-8865-d49a1aa52c93",
      }),
    );
    expect(wakeDurableWorker).toHaveBeenCalledWith({
      correlationId: "correlation-id",
      traceId: "trace-id",
    });
    expect(writeLog).toHaveBeenCalledWith(
      "durable_worker.wake",
      expect.objectContaining({ outcome: "succeeded" }),
    );
  });

  it("preserva o corpo UTF-8 exato para deduplicação durável", async () => {
    const rawBody = `{
      "connection_id": "f50f0542-fdf2-4979-8865-d49a1aa52c93",
      "chat": { "id": "opaque-chat" },
      "identity": {
        "aliases": [{ "type": "simulator_user", "value": "opaque-user" }]
      },
      "message": {
        "id": "opaque-message",
        "kind": "text",
        "text": "Mensagem sintética"
      },
      "provider_extension": { "discarded_by_normalizer": true }
    }`;

    const response = await POST(request(rawBody));

    expect(response.status).toBe(202);
    expect(rpc).toHaveBeenCalledWith(
      "ingest_simulated_inbound",
      expect.objectContaining({ raw_body: rawBody }),
    );
  });

  it("retorna 202 e observa falha best-effort do wake", async () => {
    wakeDurableWorker.mockResolvedValue(false);

    const response = await POST(request());

    expect(response.status).toBe(202);
    expect(writeLog).toHaveBeenCalledWith(
      "durable_worker.wake",
      expect.objectContaining({ outcome: "failed" }),
    );
  });

  it("aguarda o orçamento curto do wake antes de concluir o 202", async () => {
    let releaseWake: (value: boolean) => void = () => undefined;
    wakeDurableWorker.mockReturnValue(
      new Promise<boolean>((resolve) => {
        releaseWake = resolve;
      }),
    );
    let settled = false;

    const responsePromise = POST(request()).then((response) => {
      settled = true;
      return response;
    });
    await vi.waitFor(() => expect(wakeDurableWorker).toHaveBeenCalledOnce());

    expect(settled).toBe(false);
    releaseWake(false);
    await expect(responsePromise).resolves.toMatchObject({ status: 202 });
  });

  it.each([
    {
      code: "40001",
      details: "provider event id was reused with a divergent payload",
      message: "Webhook replay conflict",
    },
    {
      code: "PGRST",
      details: '{"status":409}',
      message: '{"message":"Webhook replay conflict"}',
    },
  ])("mapeia replay divergente $code para 409", async (error) => {
    rpc.mockResolvedValue({ data: null, error });

    const response = await POST(request());

    expect(response.status).toBe(409);
    expect(wakeDurableWorker).not.toHaveBeenCalled();
  });

  it("mantém outros erros de domínio como 422", async () => {
    rpc.mockResolvedValue({
      data: null,
      error: { code: "22023", message: "invalid normalized event" },
    });

    const response = await POST(request());

    expect(response.status).toBe(422);
    expect(wakeDurableWorker).not.toHaveBeenCalled();
  });

  it("recusa content-type diferente de JSON antes do RPC", async () => {
    const invalid = new Request(
      "http://localhost/api/simulator/whatsapp/inbound",
      {
        body: "{}",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "text/plain",
        },
        method: "POST",
      },
    );
    const response = await POST(invalid);
    expect(response.status).toBe(400);
    expect(rpc).not.toHaveBeenCalled();
  });

  it("mede o corpo real sem depender de content-length", async () => {
    const oversized = new Request(
      "http://localhost/api/simulator/whatsapp/inbound",
      {
        body: JSON.stringify({ padding: "x".repeat(70 * 1024) }),
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        method: "POST",
      },
    );
    expect(oversized.headers.get("content-length")).toBeNull();
    const response = await POST(oversized);
    expect(response.status).toBe(413);
    expect(rpc).not.toHaveBeenCalled();
  });
});
