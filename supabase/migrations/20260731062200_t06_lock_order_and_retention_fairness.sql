-- T06 final concurrency and bounded-maintenance corrections.

-- Acceptance and inbound processing must acquire the stream fence before the
-- connection row. The worker already owns Stream -> Inbox -> Domain, while
-- the previous acceptance body used Connection -> Stream and relied on a
-- deadlock retry wrapper. Read an unlocked connection snapshot only to derive
-- the stream identity, own the stream row, and then lock and revalidate the
-- connection before accepting the envelope.
create or replace function private.ingest_simulated_inbound_t06_normalized_base(
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
  connection_snapshot public.whatsapp_connections%rowtype;
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
  into strict connection_snapshot
  from public.whatsapp_connections as connection
  where connection.id = target_connection_id;

  if connection_snapshot.adapter_type <> 'simulator'
    or not connection_snapshot.is_test
    or connection_snapshot.status <> 'active'
    or not connection_snapshot.inbound_enabled
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

  insert into private.stream_sequences (
    organization_id,
    operation_id,
    stream_key,
    next_sequence
  )
  values (
    connection_snapshot.organization_id,
    connection_snapshot.operation_id,
    stream_key_value,
    1
  )
  on conflict (organization_id, operation_id, stream_key)
  do update
  set next_sequence = private.stream_sequences.next_sequence;

  select connection.*
  into strict connection_record
  from public.whatsapp_connections as connection
  where connection.id = target_connection_id
  for share;

  if connection_record.organization_id
      is distinct from connection_snapshot.organization_id
    or connection_record.operation_id
      is distinct from connection_snapshot.operation_id
    or connection_record.adapter_type <> 'simulator'
    or not connection_record.is_test
    or connection_record.status <> 'active'
    or not connection_record.inbound_enabled
  then
    raise exception 'simulator connection changed during acceptance'
      using errcode = '40001';
  end if;

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

  update private.stream_sequences
  set
    next_sequence = next_sequence + 1,
    updated_at = now()
  where organization_id = connection_record.organization_id
    and operation_id = connection_record.operation_id
    and stream_key = stream_key_value
  returning next_sequence - 1 into strict sequence_value;

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

revoke all on function private.ingest_simulated_inbound_t06_normalized_base(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;

-- The corrected lock order is the concurrency control. Do not hide a lock
-- inversion behind retries or deadlock_timeout.
create or replace function private.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
  raw_request_body text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.ingest_simulated_inbound_t06_acceptance_base(
    target_connection_id,
    normalized_event,
    raw_request_body,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function private.ingest_simulated_inbound(
  uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated, service_role;

create index infrastructure_durable_alert_resolutions_dead_letter_idx
  on private.infrastructure_durable_alert_resolutions (dead_letter_id);

-- Bound expiry by dead-letter rows, not only by parent Inbox rows. This also
-- bounds the one-to-one alert updates fired by the status transition.
create or replace function private.prune_durable_sensitive_material(
  maximum_rows integer default 5000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_letters integer := 0;
  purged_inbox integer := 0;
  purged_letters integer := 0;
begin
  if maximum_rows not between 1 and 25000 then
    raise exception 'invalid durable retention bound'
      using errcode = '22023';
  end if;

  with expiring_letters as (
    select letter.id
    from private.dead_letters as letter
    join private.webhook_inbox as inbox
      on inbox.id = letter.envelope_id
      and letter.source_queue = 'inbound_whatsapp'
    left join private.durable_retention_policies as policy
      on policy.organization_id = inbox.organization_id
      and policy.operation_id = inbox.operation_id
    where letter.status = 'pending'
      and inbox.status = 'dead'
      and inbox.raw_payload_purged_at is null
      and coalesce(inbox.processed_at, inbox.updated_at)
        < now() - coalesce(
          policy.webhook_raw_retention,
          interval '24 hours'
        )
    order by
      coalesce(inbox.processed_at, inbox.updated_at),
      inbox.id,
      letter.created_at,
      letter.id
    for update of letter skip locked
    limit maximum_rows
  )
  update private.dead_letters as letter
  set
    status = 'resolved',
    resolved_at = coalesce(letter.resolved_at, now()),
    resolution_reason = 'payload_expired'
  from expiring_letters
  where letter.id = expiring_letters.id;
  get diagnostics expired_letters = row_count;

  with doomed as (
    select inbox.id
    from private.webhook_inbox as inbox
    left join private.durable_retention_policies as policy
      on policy.organization_id = inbox.organization_id
      and policy.operation_id = inbox.operation_id
    where inbox.status in ('processed', 'unsupported', 'dead')
      and inbox.raw_payload_purged_at is null
      and coalesce(inbox.processed_at, inbox.updated_at)
        < now() - coalesce(
          policy.webhook_raw_retention,
          interval '24 hours'
        )
      and (
        inbox.status <> 'dead'
        or not exists (
          select 1
          from private.dead_letters as pending_letter
          where pending_letter.source_queue = 'inbound_whatsapp'
            and pending_letter.envelope_id = inbox.id
            and pending_letter.status = 'pending'
        )
      )
    order by coalesce(inbox.processed_at, inbox.updated_at), inbox.id
    for update of inbox skip locked
    limit maximum_rows
  )
  update private.webhook_inbox as inbox
  set
    raw_body = null,
    raw_payload = '{}'::jsonb,
    normalized_payload = '{}'::jsonb,
    raw_payload_purged_at = now(),
    updated_at = now()
  from doomed
  where inbox.id = doomed.id;
  get diagnostics purged_inbox = row_count;

  with doomed as (
    select letter.id
    from private.dead_letters as letter
    left join private.durable_retention_policies as policy
      on policy.organization_id = letter.organization_id
      and policy.operation_id = letter.operation_id
    where letter.status in ('replayed', 'resolved')
      and coalesce(
        letter.resolved_at,
        letter.replayed_at,
        letter.created_at
      ) < now() - coalesce(
        policy.resolved_dead_letter_retention,
        interval '30 days'
      )
    order by coalesce(
      letter.resolved_at,
      letter.replayed_at,
      letter.created_at
    ), letter.id
    for update of letter skip locked
    limit maximum_rows
  )
  delete from private.dead_letters as letter
  using doomed
  where letter.id = doomed.id;
  get diagnostics purged_letters = row_count;

  return jsonb_build_object(
    'raw_webhooks_purged', purged_inbox,
    'pending_replays_expired', expired_letters,
    'resolved_dead_letters_purged', purged_letters
  );
end;
$$;

revoke all on function private.prune_durable_sensitive_material(integer)
  from public, anon, authenticated, service_role;

create table private.durable_maintenance_cursors (
  maintenance_key text primary key,
  next_offset integer not null check (next_offset between 0 and 4),
  updated_at timestamptz not null default now()
);

revoke all on table private.durable_maintenance_cursors
  from public, anon, authenticated, service_role;

-- A persisted cursor rotates the first queue across cron invocations. The
-- first pass gives every queue its fair share; the second redistributes quota
-- left idle by empty queues without exceeding the global bound.
create or replace function private.prune_t06_queue_archives(
  retention_window interval default interval '7 days',
  maximum_rows integer default 25000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  archive_tables constant text[] := array[
    'a_inbound_whatsapp',
    'a_outbound_whatsapp',
    'a_scheduled_actions',
    'a_reconciliation',
    'a_dead_letter'
  ];
  archive_table text;
  table_index integer;
  start_offset integer;
  queue_quota integer;
  base_quota integer;
  remainder integer;
  remaining_rows integer;
  deleted_for_queue integer;
  existing_for_queue integer;
  deleted_total integer := 0;
  result_value jsonb := jsonb_build_object(
    'a_inbound_whatsapp', 0,
    'a_outbound_whatsapp', 0,
    'a_scheduled_actions', 0,
    'a_reconciliation', 0,
    'a_dead_letter', 0
  );
begin
  if retention_window < interval '1 day'
    or retention_window > interval '90 days'
    or maximum_rows not between 1 and 100000
  then
    raise exception 'invalid queue archive retention bounds'
      using errcode = '22023';
  end if;

  insert into private.durable_maintenance_cursors (
    maintenance_key,
    next_offset
  )
  values ('t06_queue_archives', 0)
  on conflict (maintenance_key) do nothing;

  select cursor.next_offset
  into strict start_offset
  from private.durable_maintenance_cursors as cursor
  where cursor.maintenance_key = 't06_queue_archives'
  for update;

  update private.durable_maintenance_cursors
  set
    next_offset = (start_offset + 1) % cardinality(archive_tables),
    updated_at = now()
  where maintenance_key = 't06_queue_archives';

  base_quota := maximum_rows / cardinality(archive_tables);
  remainder := maximum_rows % cardinality(archive_tables);

  for table_index in 0..cardinality(archive_tables) - 1 loop
    archive_table := archive_tables[
      ((start_offset + table_index) % cardinality(archive_tables)) + 1
    ];
    queue_quota := base_quota
      + case when table_index < remainder then 1 else 0 end;

    if queue_quota = 0 then
      continue;
    end if;

    execute format(
      $sql$
        with doomed as (
          select archive.msg_id
          from pgmq.%I as archive
          where archive.archived_at < now() - $1
          order by archive.archived_at, archive.msg_id
          for update skip locked
          limit $2
        )
        delete from pgmq.%I as archive
        using doomed
        where archive.msg_id = doomed.msg_id
      $sql$,
      archive_table,
      archive_table
    )
    using retention_window, queue_quota;
    get diagnostics deleted_for_queue = row_count;

    deleted_total := deleted_total + deleted_for_queue;
    result_value := jsonb_set(
      result_value,
      array[archive_table],
      to_jsonb(deleted_for_queue),
      true
    );
  end loop;

  remaining_rows := maximum_rows - deleted_total;
  if remaining_rows > 0 then
    for table_index in 0..cardinality(archive_tables) - 1 loop
      exit when remaining_rows = 0;
      archive_table := archive_tables[
        ((start_offset + table_index) % cardinality(archive_tables)) + 1
      ];

      execute format(
        $sql$
          with doomed as (
            select archive.msg_id
            from pgmq.%I as archive
            where archive.archived_at < now() - $1
            order by archive.archived_at, archive.msg_id
            for update skip locked
            limit $2
          )
          delete from pgmq.%I as archive
          using doomed
          where archive.msg_id = doomed.msg_id
        $sql$,
        archive_table,
        archive_table
      )
      using retention_window, remaining_rows;
      get diagnostics deleted_for_queue = row_count;

      existing_for_queue :=
        coalesce((result_value ->> archive_table)::integer, 0);
      deleted_total := deleted_total + deleted_for_queue;
      remaining_rows := remaining_rows - deleted_for_queue;
      result_value := jsonb_set(
        result_value,
        array[archive_table],
        to_jsonb(existing_for_queue + deleted_for_queue),
        true
      );
    end loop;
  end if;

  return result_value || jsonb_build_object('total', deleted_total);
end;
$$;

revoke all on function private.prune_t06_queue_archives(
  interval, integer
) from public, anon, authenticated, service_role;

-- Binding mismatches identify a forged or stale physical queue message. They
-- are evidence to resolve, never an instruction to republish the canonical
-- outbox event.
alter function public.replay_dead_letter(uuid, uuid, uuid)
  rename to replay_dead_letter_t06_nonreplayable_base;

revoke all on function public.replay_dead_letter_t06_nonreplayable_base(
  uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create function public.replay_dead_letter(
  target_dead_letter_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  letter_record private.dead_letters%rowtype;
begin
  select letter.*
  into strict letter_record
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id
  for update;

  if letter_record.operation_id is null
    or not private.has_membership_permission(
      letter_record.operation_id,
      'manage_conversations'
    )
  then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;

  if letter_record.source_queue = 'reconciliation'
    and letter_record.failure_code = 'queue_binding_mismatch'
  then
    if letter_record.status = 'pending' then
      update private.dead_letters
      set
        status = 'resolved',
        resolved_at = now(),
        resolution_reason = 'non_replayable_queue_binding_mismatch'
      where id = letter_record.id;
    end if;

    insert into audit.audit_events (
      organization_id,
      operation_id,
      actor_user_id,
      action,
      target_type,
      target_id,
      before_state,
      after_state,
      trace_id,
      correlation_id
    )
    values (
      letter_record.organization_id,
      letter_record.operation_id,
      auth.uid(),
      'dead_letter.replay_binding_mismatch_rejected',
      'dead_letter',
      letter_record.id,
      jsonb_build_object(
        'status', letter_record.status,
        'source_queue', letter_record.source_queue,
        'failure_code', letter_record.failure_code
      ),
      jsonb_build_object(
        'status', 'resolved',
        'reason', 'queue_binding_mismatch',
        'event_republished', false
      ),
      request_trace_id,
      request_correlation_id
    );

    return jsonb_build_object(
      'status', 'rejected_non_replayable',
      'reason', 'queue_binding_mismatch',
      'dead_letter_id', letter_record.id
    );
  end if;

  return public.replay_dead_letter_t06_nonreplayable_base(
    target_dead_letter_id,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

revoke all on function public.replay_dead_letter(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.replay_dead_letter(uuid, uuid, uuid)
  to authenticated;

-- Preserve the wrapper's quarantine accounting even when a mixed batch also
-- contains valid canonical reconciliation messages.
create or replace function private.consume_reconciliation_detailed(
  maximum_messages integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  queue_record pgmq.message_record;
  event_id_value uuid;
  event_record private.outbox_events%rowtype;
  valid_count integer := 0;
  mismatch_count integer := 0;
  base_result jsonb;
begin
  if maximum_messages not between 1 and 100 then
    raise exception 'invalid reconciliation worker bound'
      using errcode = '22023';
  end if;

  for queue_record in
    select claimed.*
    from pgmq.read(
      queue_name => 'reconciliation',
      vt => 30,
      qty => maximum_messages,
      conditional => '{}'::jsonb
    ) as claimed
    order by claimed.msg_id
  loop
    event_id_value := null;
    event_record := null;

    begin
      event_id_value :=
        (queue_record.message ->> 'outbox_event_id')::uuid;
    exception when invalid_text_representation then
      event_id_value := null;
    end;

    if event_id_value is not null then
      select event.*
      into event_record
      from private.outbox_events as event
      where event.id = event_id_value;
    end if;

    if event_record.id is not null
      and event_record.status <> 'completed'
      and (
        event_record.target_queue <> 'reconciliation'
        or event_record.queue_message_id is distinct from queue_record.msg_id
      )
    then
      perform private.dead_letter_queue_message(
        'reconciliation',
        queue_record.msg_id,
        event_record.id,
        event_record.idempotency_key,
        jsonb_build_object(
          'queue_message_id', queue_record.msg_id,
          'outbox_event_id', event_record.id
        ),
        greatest(queue_record.read_ct, 1),
        'non_retryable',
        'queue_binding_mismatch',
        event_record.organization_id,
        event_record.operation_id,
        event_record.trace_id,
        event_record.correlation_id
      );
      mismatch_count := mismatch_count + 1;
    else
      perform *
      from pgmq.set_vt(
        queue_name => 'reconciliation',
        msg_id => queue_record.msg_id,
        vt => 0
      );
      valid_count := valid_count + 1;
    end if;
  end loop;

  if valid_count = 0 then
    return jsonb_build_object(
      'processed', 0,
      'deferred', 0,
      'dead_lettered', mismatch_count,
      'quarantined', mismatch_count
    );
  end if;

  base_result :=
    private.consume_reconciliation_detailed_t06_binding_base(valid_count);
  base_result := jsonb_set(
    base_result,
    '{dead_lettered}',
    to_jsonb(
      coalesce((base_result ->> 'dead_lettered')::integer, 0)
        + mismatch_count
    )
  );
  return jsonb_set(
    base_result,
    '{quarantined}',
    to_jsonb(
      coalesce((base_result ->> 'quarantined')::integer, 0)
        + mismatch_count
    )
  );
end;
$$;

revoke all on function private.consume_reconciliation_detailed(integer)
  from public, anon, authenticated, service_role;
