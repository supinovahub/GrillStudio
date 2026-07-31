import { describe, expect, it } from "vitest";

import {
  simulatorConnectionId,
  simulatorInboundAdapter,
} from "@/lib/whatsapp/simulator";

function payload() {
  return {
    connection_id: "f50f0542-fdf2-4979-8865-d49a1aa52c93",
    chat: { id: "opaque-chat-01" },
    identity: {
      aliases: [
        { type: "uazapi_lid", value: "opaque-lid-value" },
        { type: "uazapi_pn", value: "opaque-pn-value" },
        { type: "meta_bsuid", value: "opaque-bsuid-value" },
      ],
      display_name: "Lead sintético",
    },
    message: {
      id: "opaque-message-01",
      kind: "text",
      occurred_at: "2026-07-31T12:00:00.000Z",
      text: "Olá, quero saber mais.",
    },
  };
}

describe("simulatorInboundAdapter", () => {
  it("normaliza no contrato comum sem inventar telefone", () => {
    const raw = payload();
    expect(simulatorConnectionId(raw)).toBe(raw.connection_id);
    expect(simulatorInboundAdapter.normalize(raw)).toEqual({
      provider: "simulator",
      provider_message_id: "opaque-message-01",
      provider_chat_id: "opaque-chat-01",
      occurred_at: "2026-07-31T12:00:00.000Z",
      kind: "text",
      text: "Olá, quero saber mais.",
      identity: {
        aliases: raw.identity.aliases,
        display_name: "Lead sintético",
        phone_original: null,
      },
    });
  });

  it("preserva LID, PN e BSUID como identificadores opacos", () => {
    const normalized = simulatorInboundAdapter.normalize(payload());
    expect(normalized.identity.aliases.map((alias) => alias.value)).toEqual([
      "opaque-lid-value",
      "opaque-pn-value",
      "opaque-bsuid-value",
    ]);
  });

  it("recusa aliases duplicados e texto vazio", () => {
    const duplicated = payload();
    duplicated.identity.aliases.push(duplicated.identity.aliases[0]!);
    expect(() => simulatorInboundAdapter.normalize(duplicated)).toThrow(
      "Aliases duplicados",
    );

    const empty = payload();
    empty.message.text = "";
    expect(() => simulatorInboundAdapter.normalize(empty)).toThrow(
      "message.text é obrigatório",
    );
  });
});
