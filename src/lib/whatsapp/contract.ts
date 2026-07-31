export const providerAliasTypes = [
  "simulator_user",
  "uazapi_sender",
  "uazapi_lid",
  "uazapi_pn",
  "meta_bsuid",
  "meta_parent_bsuid",
  "meta_wa_id",
  "meta_username",
] as const;

export type ProviderAliasType = (typeof providerAliasTypes)[number];
export type WhatsappProvider = "simulator" | "uazapi" | "meta_cloud";
export type WhatsappMessageKind =
  | "text"
  | "image"
  | "document"
  | "audio"
  | "video"
  | "unknown";

export type NormalizedProviderAlias = {
  type: ProviderAliasType;
  value: string;
};

export type NormalizedInboundEvent = {
  provider: WhatsappProvider;
  provider_message_id: string;
  provider_chat_id: string;
  occurred_at: string;
  kind: WhatsappMessageKind;
  text: string | null;
  identity: {
    display_name: string | null;
    phone_original: string | null;
    aliases: NormalizedProviderAlias[];
  };
};

export interface WhatsappInboundAdapter<TRaw> {
  readonly provider: WhatsappProvider;
  normalize(raw: TRaw): NormalizedInboundEvent;
}

