-- T06 review: retain the exact accepted simulator body and hash its bytes.

alter table private.webhook_inbox
  add column raw_body text,
  add column raw_body_hash text
    check (
      raw_body_hash is null
      or raw_body_hash ~ '^[0-9a-f]{64}$'
    ),
  add constraint webhook_inbox_raw_body_size_check
    check (
      raw_body is null
      or octet_length(raw_body) <= 65536
    );

update private.webhook_inbox
set
  raw_body = raw_payload::text,
  raw_body_hash = payload_hash
where raw_body is null;

comment on column private.webhook_inbox.raw_body is
  'Exact UTF-8 request body accepted by the simulator route; private and limited to 64 KiB.';
comment on column private.webhook_inbox.raw_body_hash is
  'SHA-256 of the exact UTF-8 request body, including fields discarded by normalization.';
comment on column private.webhook_inbox.raw_payload is
  'Parsed raw JSON object. raw_body is the byte-stable source used for replay conflict detection.';

create or replace function private.capture_webhook_raw_body()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  configured_body text := current_setting('app.t06_raw_body', true);
  configured_hash text := current_setting('app.t06_raw_body_hash', true);
begin
  if nullif(configured_body, '') is not null
    and configured_hash ~ '^[0-9a-f]{64}$'
  then
    new.raw_body := configured_body;
    new.raw_body_hash := configured_hash;
    new.raw_payload := configured_body::jsonb;
    new.payload_hash := configured_hash;
  else
    new.raw_body := new.raw_payload::text;
    new.raw_body_hash := new.payload_hash;
  end if;
  return new;
end;
$$;

revoke all on function private.capture_webhook_raw_body()
  from public, anon, authenticated, service_role;

create trigger webhook_inbox_capture_raw_body
before insert on private.webhook_inbox
for each row execute function private.capture_webhook_raw_body();

alter table private.webhook_inbox
  alter column raw_body set not null,
  alter column raw_body_hash set not null;

alter function private.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) rename to ingest_simulated_inbound_t06_normalized_base;

revoke all on function private.ingest_simulated_inbound_t06_normalized_base(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
  raw_request_body text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  provider_event_id_value text;
  raw_json_value jsonb;
  raw_hash_value text;
  existing_record private.webhook_inbox%rowtype;
  accepted_result jsonb;
  accepted_inbox_id uuid;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if raw_request_body is null
    or octet_length(raw_request_body) = 0
    or octet_length(raw_request_body) > 65536
  then
    raise exception 'raw webhook body must contain at most 65536 bytes'
      using errcode = '22023';
  end if;

  begin
    raw_json_value := raw_request_body::jsonb;
  exception when invalid_text_representation then
    raise exception 'raw webhook body is not valid JSON'
      using errcode = '22023';
  end;
  if jsonb_typeof(raw_json_value) <> 'object' then
    raise exception 'raw webhook body must be a JSON object'
      using errcode = '22023';
  end if;

  provider_event_id_value := nullif(
    left(btrim(coalesce(normalized_event ->> 'provider_message_id', '')), 500),
    ''
  );
  if provider_event_id_value is null then
    raise exception 'provider message identifier is required'
      using errcode = '22023';
  end if;
  raw_hash_value := encode(
    sha256(convert_to(raw_request_body, 'UTF8')),
    'hex'
  );

  perform set_config('app.t06_raw_body', raw_request_body, true);
  perform set_config('app.t06_raw_body_hash', raw_hash_value, true);

  perform pg_advisory_xact_lock(
    hashtextextended(
      'webhook-inbox:' || target_connection_id::text
        || ':' || provider_event_id_value,
      0
    )
  );

  select inbox.*
  into existing_record
  from private.webhook_inbox as inbox
  where inbox.connection_id = target_connection_id
    and inbox.provider_event_id = provider_event_id_value;

  if existing_record.id is not null then
    if existing_record.raw_body_hash <> raw_hash_value then
      raise sqlstate 'PGRST' using
        message = jsonb_build_object(
          'code', '40001',
          'message', 'Webhook replay conflict',
          'details', 'provider event id was reused with a divergent raw body',
          'hint', 'provider event ids must identify one immutable request body'
        )::text,
        detail = jsonb_build_object(
          'status', 409,
          'headers', jsonb_build_object()
        )::text;
    end if;
    return jsonb_build_object(
      'status', 'duplicate',
      'inbox_id', existing_record.id,
      'queue_message_id', existing_record.queue_message_id
    );
  end if;

  accepted_result := private.ingest_simulated_inbound_t06_normalized_base(
    target_connection_id,
    normalized_event,
    request_trace_id,
    request_correlation_id
  );
  accepted_inbox_id := (accepted_result ->> 'inbox_id')::uuid;

  update private.webhook_inbox
  set
    raw_body = raw_request_body,
    raw_body_hash = raw_hash_value,
    raw_payload = raw_json_value,
    payload_hash = raw_hash_value,
    updated_at = now()
  where id = accepted_inbox_id;

  return accepted_result;
end;
$$;

revoke all on function private.ingest_simulated_inbound(
  uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated, service_role;

drop function public.ingest_simulated_inbound(uuid, jsonb, uuid, uuid);

create function public.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
  raw_body text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.ingest_simulated_inbound(
    target_connection_id,
    normalized_event,
    raw_body,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.ingest_simulated_inbound(
  uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.ingest_simulated_inbound(
  uuid, jsonb, text, uuid, uuid
) to service_role;
