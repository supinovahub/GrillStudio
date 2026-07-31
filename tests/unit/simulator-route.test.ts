import { beforeEach, describe, expect, it, vi } from "vitest";

const { createAdminClient, getPreviewEnvironment, rpc } = vi.hoisted(() => {
  const rpc = vi.fn();
  return {
    createAdminClient: vi.fn(() => ({ rpc })),
    getPreviewEnvironment: vi.fn(),
    rpc,
  };
});

vi.mock("@/lib/environment", () => ({ getPreviewEnvironment }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient }));

import { POST } from "@/app/api/simulator/whatsapp/inbound/route";

const token = "synthetic-preview-route-token-000001";

function request() {
  return new Request("http://localhost/api/simulator/whatsapp/inbound", {
    body: JSON.stringify({
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
    }),
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
        target_connection_id: "f50f0542-fdf2-4979-8865-d49a1aa52c93",
      }),
    );
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
