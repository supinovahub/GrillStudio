-- T06: short acceptance transactions and domain/outbox atomicity.

create table private.stream_sequences (
  organization_id uuid not null,
  operation_id uuid not null,
  stream_key text not null
    check (stream_key ~ '^[0-9a-f]{64}$'),
  next_sequence bigint not null default 1 check (next_sequence > 0),
  updated_at timestamptz not null default now(),
  primary key (organization_id, operation_id, stream_key),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

alter table private.webhook_inbox
  add column stream_key text not null
    check (stream_key ~ '^[0-9a-f]{64}$'),
  add column stream_sequence bigint not null
    check (stream_sequence > 0),
  add column queue_message_id bigint,
  add constraint webhook_inbox_stream_sequence_key
    unique (organization_id, operation_id, stream_key, stream_sequence);

create index webhook_inbox_stream_pending_idx
  on private.webhook_inbox (
    organization_id,
    operation_id,
    stream_key,
    stream_sequence
  )
  where status in ('accepted', 'processing');

revoke all on table private.stream_sequences
  from public, anon, authenticated;
grant all on table private.stream_sequences to service_role;

alter table public.messages
  drop constraint messages_status_check,
  add constraint messages_status_check
    check (status in ('received', 'queued', 'captured'));

create or replace function private.next_aggregate_sequence(
  target_organization_id uuid,
  target_operation_id uuid,
  target_aggregate_type text,
  target_aggregate_id uuid
)
returns bigint
language sql
security definer
set search_path = ''
as $$
  insert into private.aggregate_sequences (
    organization_id,
    operation_id,
    aggregate_type,
    aggregate_id,
    next_sequence
  )
  values (
    target_organization_id,
    target_operation_id,
    target_aggregate_type,
    target_aggregate_id,
    2
  )
  on conflict (
    organization_id,
    operation_id,
    aggregate_type,
    aggregate_id
  )
  do update
  set
    next_sequence = private.aggregate_sequences.next_sequence + 1,
    updated_at = now()
  returning next_sequence - 1;
$$;

revoke all on function private.next_aggregate_sequence(
  uuid, uuid, text, uuid
) from public, anon, authenticated, service_role;

alter function private.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) rename to process_simulated_inbound_t06_domain;

revoke all on function private.process_simulated_inbound_t06_domain(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  connection_record public.whatsapp_connections%rowtype;
  existing_record private.webhook_inbox%rowtype;
  accepted_record private.webhook_inbox%rowtype;
  provider_event_id_value text;
  provider_chat_id_value text;
  payload_hash_value text;
  stream_key_value text;
  sequence_value bigint;
  queue_id bigint;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if jsonb_typeof(normalized_event) <> 'object'
    or normalized_event ->> 'provider' <> 'simulator'
  then
    raise exception 'invalid normalized simulator event'
      using errcode = '22023';
  end if;

  provider_event_id_value := nullif(
    left(btrim(coalesce(normalized_event ->> 'provider_message_id', '')), 500),
    ''
  );
  provider_chat_id_value := nullif(
    left(btrim(coalesce(normalized_event ->> 'provider_chat_id', '')), 500),
    ''
  );
  if provider_event_id_value is null or provider_chat_id_value is null then
    raise exception 'provider message and chat identifiers are required'
      using errcode = '22023';
  end if;

  select connection.*
  into strict connection_record
  from public.whatsapp_connections as connection
  where connection.id = target_connection_id
  for share;

  if connection_record.adapter_type <> 'simulator'
    or not connection_record.is_test
    or connection_record.status <> 'active'
    or not connection_record.inbound_enabled
  then
    raise exception 'simulator connection is not available'
      using errcode = '42501';
  end if;

  payload_hash_value := encode(
    sha256(convert_to(normalized_event::text, 'UTF8')),
    'hex'
  );
  stream_key_value := encode(
    sha256(
      convert_to(
        target_connection_id::text || ':' || provider_chat_id_value,
        'UTF8'
      )
    ),
    'hex'
  );

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
    if existing_record.payload_hash <> payload_hash_value then
      raise sqlstate 'PGRST' using
        message = jsonb_build_object(
          'code', '40001',
          'message', 'Webhook replay conflict',
          'details', 'provider event id was reused with a divergent payload',
          'hint', 'provider event ids must identify one immutable payload'
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

  insert into private.stream_sequences (
    organization_id,
    operation_id,
    stream_key,
    next_sequence
  )
  values (
    connection_record.organization_id,
    connection_record.operation_id,
    stream_key_value,
    2
  )
  on conflict (organization_id, operation_id, stream_key)
  do update
  set
    next_sequence = private.stream_sequences.next_sequence + 1,
    updated_at = now()
  returning next_sequence - 1 into sequence_value;

  insert into private.webhook_inbox (
    organization_id,
    operation_id,
    connection_id,
    provider,
    provider_event_id,
    payload_hash,
    raw_payload,
    normalized_payload,
    stream_key,
    stream_sequence,
    trace_id,
    correlation_id
  )
  values (
    connection_record.organization_id,
    connection_record.operation_id,
    connection_record.id,
    'simulator',
    provider_event_id_value,
    payload_hash_value,
    normalized_event,
    normalized_event,
    stream_key_value,
    sequence_value,
    request_trace_id,
    request_correlation_id
  )
  returning * into strict accepted_record;

  select sent.msg_id
  into strict queue_id
  from pgmq.send(
    queue_name => 'inbound_whatsapp',
    msg => jsonb_build_object(
      'inbox_id', accepted_record.id,
      'organization_id', accepted_record.organization_id,
      'operation_id', accepted_record.operation_id,
      'stream_key', accepted_record.stream_key,
      'stream_sequence', accepted_record.stream_sequence,
      'trace_id', accepted_record.trace_id,
      'correlation_id', accepted_record.correlation_id
    )
  ) as sent(msg_id);

  update private.webhook_inbox
  set queue_message_id = queue_id
  where id = accepted_record.id;

  return jsonb_build_object(
    'status', 'accepted',
    'inbox_id', accepted_record.id,
    'queue_message_id', queue_id,
    'stream_sequence', accepted_record.stream_sequence
  );
end;
$$;

revoke all on function private.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function public.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
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
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) to service_role;

alter function private.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) rename to send_human_message_t05_sync_base;

revoke all on function private.send_human_message_t05_sync_base(
  uuid, bigint, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.send_human_message(
  target_conversation_id uuid,
  expected_version bigint,
  command_id uuid,
  message_text text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_result jsonb;
  message_record public.messages%rowtype;
  conversation_record public.conversations%rowtype;
  sequence_value bigint;
  payload_value jsonb;
  payload_hash_value text;
begin
  base_result := private.send_human_message_t05_sync_base(
    target_conversation_id,
    expected_version,
    command_id,
    message_text,
    request_trace_id,
    request_correlation_id
  );

  if base_result ->> 'status' = 'duplicate' then
    return base_result;
  end if;

  select message.*
  into strict message_record
  from public.messages as message
  where message.id = (base_result ->> 'message_id')::uuid
  for update;

  select conversation.*
  into strict conversation_record
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  -- The T05 base is reused for its exact authorization, version and
  -- pending_return semantics. Its simulator capture and audit row have not
  -- committed yet, so replace them atomically with the durable request.
  delete from private.simulator_outbound_captures
  where message_id = message_record.id;

  delete from audit.audit_events
  where action = 'message.outbound_captured'
    and target_type = 'message'
    and target_id = message_record.id
    and trace_id = request_trace_id
    and correlation_id = request_correlation_id;

  update public.messages
  set status = 'queued'
  where id = message_record.id
  returning * into strict message_record;

  sequence_value := private.next_aggregate_sequence(
    conversation_record.organization_id,
    conversation_record.operation_id,
    'conversation',
    conversation_record.id
  );
  payload_value := jsonb_build_object(
    'message_id', message_record.id,
    'conversation_id', conversation_record.id,
    'connection_id', conversation_record.connection_id
  );
  payload_hash_value := encode(
    sha256(convert_to(payload_value::text, 'UTF8')),
    'hex'
  );

  insert into private.outbox_events (
    organization_id,
    operation_id,
    event_type,
    aggregate_type,
    aggregate_id,
    aggregate_version,
    aggregate_sequence,
    actor_type,
    actor_reference,
    target_queue,
    idempotency_key,
    payload_hash,
    payload,
    trace_id,
    correlation_id
  )
  values (
    conversation_record.organization_id,
    conversation_record.operation_id,
    'message.send_requested.v1',
    'conversation',
    conversation_record.id,
    conversation_record.version,
    sequence_value,
    'user',
    message_record.created_by_membership_id::text,
    'outbound_whatsapp',
    'human-message:' || command_id::text,
    payload_hash_value,
    payload_value,
    request_trace_id,
    request_correlation_id
  );

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    conversation_record.organization_id,
    conversation_record.operation_id,
    auth.uid(),
    'message.send_requested',
    'message',
    message_record.id,
    jsonb_build_object(
      'expected_version', expected_version
    ),
    jsonb_build_object(
      'conversation_id', conversation_record.id,
      'status', 'queued',
      'adapter', 'simulator',
      'egress_attempted', false,
      'version', conversation_record.version
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'status', 'queued',
    'message_id', message_record.id,
    'conversation_id', conversation_record.id,
    'pending_return', false,
    'pending_cancelled', base_result -> 'pending_cancelled',
    'version', conversation_record.version
  );
end;
$$;

revoke all on function private.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function public.send_human_message(
  target_conversation_id uuid,
  expected_version bigint,
  command_id uuid,
  message_text text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.send_human_message(
    target_conversation_id,
    expected_version,
    command_id,
    message_text,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) from public, anon;
grant execute on function public.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) to authenticated;
