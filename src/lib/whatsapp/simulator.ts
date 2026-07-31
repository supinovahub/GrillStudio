import {
  providerAliasTypes,
  type NormalizedInboundEvent,
  type NormalizedProviderAlias,
  type WhatsappInboundAdapter,
  type WhatsappMessageKind,
} from "@/lib/whatsapp/contract";

type JsonObject = Record<string, unknown>;

export type SimulatorInboundPayload = {
  connection_id: string;
  chat: { id: string };
  identity: {
    aliases: Array<{ type: string; value: string }>;
    display_name?: string | null;
    phone_original?: string | null;
  };
  message: {
    id: string;
    kind?: string;
    occurred_at?: string;
    text?: string | null;
  };
};

function object(value: unknown, field: string): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${field} deve ser um objeto.`);
  }
  return value as JsonObject;
}

function text(
  value: unknown,
  field: string,
  maximum: number,
  required = true,
): string | null {
  if (value === null || value === undefined || value === "") {
    if (!required) return null;
    throw new Error(`${field} é obrigatório.`);
  }
  if (typeof value !== "string" || value.trim().length > maximum) {
    throw new Error(`${field} é inválido.`);
  }
  const normalized = value.trim();
  if (!normalized && required) {
    throw new Error(`${field} é obrigatório.`);
  }
  return normalized || null;
}

function aliases(value: unknown): NormalizedProviderAlias[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 20) {
    throw new Error("identity.aliases deve conter de 1 a 20 aliases.");
  }

  const seen = new Set<string>();
  return value.map((item, index) => {
    const candidate = object(item, `identity.aliases[${index}]`);
    const type = text(
      candidate.type,
      `identity.aliases[${index}].type`,
      40,
    );
    const aliasValue = text(
      candidate.value,
      `identity.aliases[${index}].value`,
      500,
    );
    if (
      !type ||
      !providerAliasTypes.includes(
        type as (typeof providerAliasTypes)[number],
      )
    ) {
      throw new Error(`identity.aliases[${index}].type não é suportado.`);
    }
    const key = `${type}:${aliasValue}`;
    if (seen.has(key)) {
      throw new Error("Aliases duplicados não são aceitos.");
    }
    seen.add(key);
    return {
      type: type as NormalizedProviderAlias["type"],
      value: aliasValue!,
    };
  });
}

function kind(value: unknown): WhatsappMessageKind {
  const candidate = value ?? "text";
  if (
    typeof candidate !== "string" ||
    !["text", "image", "document", "audio", "video", "unknown"].includes(
      candidate,
    )
  ) {
    throw new Error("message.kind não é suportado.");
  }
  return candidate as WhatsappMessageKind;
}

function occurredAt(value: unknown): string {
  if (value === undefined || value === null || value === "") {
    return new Date().toISOString();
  }
  if (typeof value !== "string") {
    throw new Error("message.occurred_at é inválido.");
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error("message.occurred_at é inválido.");
  }
  return parsed.toISOString();
}

export const simulatorInboundAdapter: WhatsappInboundAdapter<unknown> = {
  provider: "simulator",
  normalize(raw: unknown): NormalizedInboundEvent {
    const payload = object(raw, "payload");
    const chat = object(payload.chat, "chat");
    const identity = object(payload.identity, "identity");
    const message = object(payload.message, "message");
    const messageKind = kind(message.kind);
    const messageText = text(message.text, "message.text", 12_000, false);

    if (messageKind === "text" && !messageText) {
      throw new Error("message.text é obrigatório para mensagens de texto.");
    }

    return {
      provider: "simulator",
      provider_message_id: text(message.id, "message.id", 500)!,
      provider_chat_id: text(chat.id, "chat.id", 500)!,
      occurred_at: occurredAt(message.occurred_at),
      kind: messageKind,
      text: messageText,
      identity: {
        display_name: text(
          identity.display_name,
          "identity.display_name",
          160,
          false,
        ),
        phone_original: text(
          identity.phone_original,
          "identity.phone_original",
          80,
          false,
        ),
        aliases: aliases(identity.aliases),
      },
    };
  },
};

export function simulatorConnectionId(raw: unknown): string {
  const payload = object(raw, "payload");
  return text(payload.connection_id, "connection_id", 100)!;
}
