-- T06: at-least-once workers, durable scheduler and authorized replay.

create or replace function private.acquire_conversation_lease(
  target_conversation_id uuid,
  target_worker_id uuid,
  target_expected_version bigint,
  target_sequence bigint,
  visibility_seconds integer
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  conversation_record public.conversations%rowtype;
  token_value uuid := gen_random_uuid();
begin
  select conversation.*
  into strict conversation_record
  from public.conversations as conversation
  where conversation.id = target_conversation_id
  for update;

  if conversation_record.version <> target_expected_version then
    raise exception 'conversation version changed before lease'
      using errcode = '40001';
  end if;

  delete from private.conversation_processing_leases
  where conversation_id = target_conversation_id
    and lease_until <= now();

  insert into private.conversation_processing_leases (
    conversation_id,
    organization_id,
    operation_id,
    worker_id,
    lease_token,
    expected_version,
    aggregate_sequence,
    lease_until
  )
  values (
    conversation_record.id,
    conversation_record.organization_id,
    conversation_record.operation_id,
    target_worker_id,
    token_value,
    target_expected_version,
    target_sequence,
    now() + make_interval(secs => visibility_seconds)
  )
  on conflict (conversation_id) do nothing;

  if not found then
    return null;
  end if;
  return token_value;
end;
$$;

create or replace function private.release_conversation_lease(
  target_conversation_id uuid,
  target_lease_token uuid
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with removed as (
    delete from private.conversation_processing_leases
    where conversation_id = target_conversation_id
      and lease_token = target_lease_token
    returning 1
  )
  select exists(select 1 from removed);
$$;

create or replace function private.defer_queue_message(
  target_queue text,
  target_message_id bigint,
  visibility_seconds integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform *
  from pgmq.set_vt(
    queue_name => target_queue,
    msg_id => target_message_id,
    vt => greatest(1, least(visibility_seconds, 3600))
  );
end;
$$;

create or replace function private.dead_letter_queue_message(
  target_queue text,
  target_message_id bigint,
  target_envelope_id uuid,
  target_effect_key text,
  target_envelope jsonb,
  target_attempts integer,
  target_failure_class text,
  target_failure_code text,
  target_organization_id uuid,
  target_operation_id uuid,
  target_trace_id uuid,
  target_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  dead_letter_id uuid;
begin
  insert into private.dead_letters (
    organization_id,
    operation_id,
    source_queue,
    source_message_id,
    envelope_id,
    effect_key,
    redacted_envelope,
    attempts,
    failure_class,
    failure_code,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    target_queue,
    target_message_id,
    target_envelope_id,
    target_effect_key,
    target_envelope,
    target_attempts,
    left(target_failure_class, 120),
    left(target_failure_code, 120),
    target_trace_id,
    target_correlation_id
  )
  on conflict (source_queue, source_message_id)
  do update set
    attempts = excluded.attempts,
    failure_class = excluded.failure_class,
    failure_code = excluded.failure_code
  returning id into dead_letter_id;

  perform pgmq.send(
    queue_name => 'dead_letter',
    msg => jsonb_build_object(
      'dead_letter_id', dead_letter_id,
      'source_queue', target_queue,
      'envelope_id', target_envelope_id,
      'trace_id', target_trace_id,
      'correlation_id', target_correlation_id
    )
  );
  perform pgmq.archive(target_queue, target_message_id);
  return dead_letter_id;
end;
$$;

revoke all on function private.acquire_conversation_lease(
  uuid, uuid, bigint, bigint, integer
) from public, anon, authenticated, service_role;
revoke all on function private.release_conversation_lease(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.defer_queue_message(text, bigint, integer)
  from public, anon, authenticated, service_role;
revoke all on function private.dead_letter_queue_message(
  text, bigint, uuid, text, jsonb, integer, text, text,
  uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.consume_inbound_whatsapp(
  maximum_messages integer default 10,
  target_worker_id uuid default gen_random_uuid(),
  visibility_seconds integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  queue_record pgmq.message_record;
  inbox_record private.webhook_inbox%rowtype;
  result_value jsonb;
  processed_count integer := 0;
  deferred_count integer := 0;
  dead_count integer := 0;
  conversation_id_value uuid;
  conversation_version bigint;
  lease_token_value uuid;
  aggregate_sequence_value bigint;
  payload_value jsonb;
  payload_hash_value text;
  error_state text;
  error_message text;
  retry_seconds integer;
begin
  if maximum_messages not between 1 and 100
    or visibility_seconds not between 5 and 3600
  then
    raise exception 'invalid worker bounds' using errcode = '22023';
  end if;

  for message_index in 1..maximum_messages loop
    queue_record := null;
    select claimed.*
    into queue_record
    from pgmq.read(
      queue_name => 'inbound_whatsapp',
      vt => visibility_seconds,
      qty => 1,
      conditional => '{}'::jsonb
    ) as claimed
    limit 1;
    exit when queue_record.msg_id is null;

    begin
      select inbox.*
      into strict inbox_record
      from private.webhook_inbox as inbox
      where inbox.id = (queue_record.message ->> 'inbox_id')::uuid
      for update;

      insert into private.processing_attempts (
        organization_id, operation_id, queue_name, queue_message_id,
        envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
        worker_id, attempt, state, trace_id, correlation_id
      )
      values (
        inbox_record.organization_id, inbox_record.operation_id,
        'inbound_whatsapp', queue_record.msg_id, inbox_record.id,
        'conversation_stream', null, inbox_record.stream_sequence,
        target_worker_id, queue_record.read_ct, 'claimed',
        inbox_record.trace_id, inbox_record.correlation_id
      );

      if inbox_record.status in ('processed', 'unsupported') then
        perform pgmq.archive('inbound_whatsapp', queue_record.msg_id);
        processed_count := processed_count + 1;
        continue;
      end if;

      if queue_record.read_ct > inbox_record.max_attempts then
        perform private.dead_letter_queue_message(
          'inbound_whatsapp',
          queue_record.msg_id,
          inbox_record.id,
          'webhook:' || inbox_record.connection_id::text
            || ':' || inbox_record.provider_event_id,
          jsonb_build_object(
            'inbox_id', inbox_record.id,
            'organization_id', inbox_record.organization_id,
            'operation_id', inbox_record.operation_id,
            'stream_key', inbox_record.stream_key,
            'stream_sequence', inbox_record.stream_sequence,
            'trace_id', inbox_record.trace_id,
            'correlation_id', inbox_record.correlation_id
          ),
          queue_record.read_ct,
          'attempts_exhausted',
          'max_attempts',
          inbox_record.organization_id,
          inbox_record.operation_id,
          inbox_record.trace_id,
          inbox_record.correlation_id
        );
        update private.webhook_inbox
        set
          status = 'dead',
          attempts = queue_record.read_ct,
          last_error_class = 'attempts_exhausted',
          last_error_code = 'max_attempts',
          updated_at = now()
        where id = inbox_record.id;
        dead_count := dead_count + 1;
        continue;
      end if;

      if exists (
        select 1
        from private.webhook_inbox as earlier
        where earlier.organization_id = inbox_record.organization_id
          and earlier.operation_id = inbox_record.operation_id
          and earlier.stream_key = inbox_record.stream_key
          and earlier.stream_sequence < inbox_record.stream_sequence
          and earlier.status in ('accepted', 'processing')
      ) then
        perform private.defer_queue_message(
          'inbound_whatsapp',
          queue_record.msg_id,
          2
        );
        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, aggregate_type, aggregate_sequence, worker_id,
          attempt, state, trace_id, correlation_id
        )
        values (
          inbox_record.organization_id, inbox_record.operation_id,
          'inbound_whatsapp', queue_record.msg_id, inbox_record.id,
          'conversation_stream', inbox_record.stream_sequence,
          target_worker_id, queue_record.read_ct, 'deferred',
          inbox_record.trace_id, inbox_record.correlation_id
        );
        deferred_count := deferred_count + 1;
        continue;
      end if;

      update private.webhook_inbox
      set
        status = 'processing',
        attempts = queue_record.read_ct,
        processing_started_at = now(),
        updated_at = now()
      where id = inbox_record.id;

      select conversation.id, conversation.version
      into conversation_id_value, conversation_version
      from public.conversations as conversation
      where conversation.connection_id = inbox_record.connection_id
        and conversation.provider_chat_id =
          inbox_record.normalized_payload ->> 'provider_chat_id'
        and conversation.status in ('active', 'sleeping')
      for update;

      if conversation_id_value is not null then
        lease_token_value := private.acquire_conversation_lease(
          conversation_id_value,
          target_worker_id,
          conversation_version,
          inbox_record.stream_sequence,
          visibility_seconds
        );
        if lease_token_value is null then
          raise exception 'conversation lease unavailable'
            using errcode = '55P03';
        end if;
      end if;

      result_value := private.process_simulated_inbound_t06_domain(
        inbox_record.connection_id,
        inbox_record.normalized_payload,
        inbox_record.trace_id,
        inbox_record.correlation_id
      );

      conversation_id_value := nullif(
        result_value ->> 'conversation_id',
        ''
      )::uuid;
      if result_value ->> 'status' = 'received'
        and conversation_id_value is not null
      then
        aggregate_sequence_value := private.next_aggregate_sequence(
          inbox_record.organization_id,
          inbox_record.operation_id,
          'conversation',
          conversation_id_value
        );
        payload_value := jsonb_build_object(
          'inbox_id', inbox_record.id,
          'message_id', (result_value ->> 'message_id')::uuid,
          'conversation_id', conversation_id_value
        );
        payload_hash_value := encode(
          sha256(convert_to(payload_value::text, 'UTF8')),
          'hex'
        );

        insert into private.outbox_events (
          organization_id, operation_id, event_type,
          aggregate_type, aggregate_id, aggregate_version,
          aggregate_sequence, actor_type, actor_reference,
          target_queue, idempotency_key, payload_hash, payload,
          trace_id, correlation_id, causation_id
        )
        values (
          inbox_record.organization_id,
          inbox_record.operation_id,
          'whatsapp.message.received.v1',
          'conversation',
          conversation_id_value,
          (result_value ->> 'version')::bigint,
          aggregate_sequence_value,
          'provider',
          inbox_record.provider,
          'reconciliation',
          'inbound-message:' || (result_value ->> 'message_id'),
          payload_hash_value,
          payload_value,
          inbox_record.trace_id,
          inbox_record.correlation_id,
          inbox_record.id
        )
        on conflict (
          organization_id,
          operation_id,
          idempotency_key
        ) do nothing;
      end if;

      update private.webhook_inbox
      set
        status = case
          when result_value ->> 'status' = 'requires_review'
            then 'unsupported'
          else 'processed'
        end,
        processed_at = now(),
        updated_at = now(),
        last_error_class = null,
        last_error_code = null
      where id = inbox_record.id;

      if lease_token_value is not null then
        perform private.release_conversation_lease(
          conversation_id_value,
          lease_token_value
        );
      end if;
      perform pgmq.archive('inbound_whatsapp', queue_record.msg_id);
      insert into private.processing_attempts (
        organization_id, operation_id, queue_name, queue_message_id,
        envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
        worker_id, lease_token, attempt, state, trace_id, correlation_id
      )
      values (
        inbox_record.organization_id, inbox_record.operation_id,
        'inbound_whatsapp', queue_record.msg_id, inbox_record.id,
        'conversation', conversation_id_value, inbox_record.stream_sequence,
        target_worker_id, lease_token_value, queue_record.read_ct,
        'succeeded', inbox_record.trace_id, inbox_record.correlation_id
      );
      processed_count := processed_count + 1;
    exception when others then
      get stacked diagnostics
        error_state = returned_sqlstate,
        error_message = message_text;
      retry_seconds := least(
        300,
        greatest(2, power(2, least(queue_record.read_ct, 8))::integer)
      );
      update private.webhook_inbox
      set
        status = 'accepted',
        attempts = greatest(attempts, queue_record.read_ct),
        last_error_class = left(error_state, 120),
        last_error_code = left(error_state, 120),
        processing_started_at = null,
        updated_at = now()
      where id = (queue_record.message ->> 'inbox_id')::uuid;
      perform private.defer_queue_message(
        'inbound_whatsapp',
        queue_record.msg_id,
        retry_seconds
      );
      insert into private.processing_attempts (
        organization_id, operation_id, queue_name, queue_message_id,
        envelope_id, worker_id, attempt, state,
        error_class, error_code, trace_id, correlation_id
      )
      select
        inbox.organization_id, inbox.operation_id, 'inbound_whatsapp',
        queue_record.msg_id, inbox.id, target_worker_id,
        queue_record.read_ct, 'retryable_failed',
        left(error_state, 120), left(error_state, 120),
        inbox.trace_id, inbox.correlation_id
      from private.webhook_inbox as inbox
      where inbox.id = (queue_record.message ->> 'inbox_id')::uuid;
      deferred_count := deferred_count + 1;
    end;
  end loop;

  return jsonb_build_object(
    'processed', processed_count,
    'deferred', deferred_count,
    'dead_lettered', dead_count,
    'worker_id', target_worker_id
  );
end;
$$;

revoke all on function private.consume_inbound_whatsapp(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

create or replace function private.dispatch_outbox_events(
  maximum_events integer default 50
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_record private.outbox_events%rowtype;
  queue_id bigint;
  dispatched integer := 0;
begin
  if maximum_events not between 1 and 500 then
    raise exception 'invalid dispatcher bound' using errcode = '22023';
  end if;

  for event_record in
    select event.*
    from private.outbox_events as event
    where event.status = 'pending'
      and not exists (
        select 1
        from private.outbox_events as earlier
        where earlier.organization_id = event.organization_id
          and earlier.operation_id = event.operation_id
          and earlier.aggregate_type = event.aggregate_type
          and earlier.aggregate_id = event.aggregate_id
          and earlier.aggregate_sequence < event.aggregate_sequence
          and earlier.status in ('pending', 'published', 'processing')
      )
    order by event.created_at, event.id
    for update skip locked
    limit maximum_events
  loop
    select sent.msg_id into strict queue_id
    from pgmq.send(
      queue_name => event_record.target_queue,
      msg => jsonb_build_object(
        'outbox_event_id', event_record.id,
        'organization_id', event_record.organization_id,
        'operation_id', event_record.operation_id,
        'aggregate_type', event_record.aggregate_type,
        'aggregate_id', event_record.aggregate_id,
        'aggregate_version', event_record.aggregate_version,
        'aggregate_sequence', event_record.aggregate_sequence,
        'effect_key', event_record.idempotency_key,
        'trace_id', event_record.trace_id,
        'correlation_id', event_record.correlation_id
      )
    ) as sent(msg_id);

    update private.outbox_events
    set
      status = 'published',
      queue_message_id = queue_id,
      attempts = attempts + 1,
      published_at = now(),
      updated_at = now()
    where id = event_record.id;
    dispatched := dispatched + 1;
  end loop;
  return dispatched;
end;
$$;

revoke all on function private.dispatch_outbox_events(integer)
  from public, anon, authenticated, service_role;

create or replace function private.consume_outbound_whatsapp(
  maximum_messages integer default 10,
  target_worker_id uuid default gen_random_uuid(),
  visibility_seconds integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  queue_record pgmq.message_record;
  event_record private.outbox_events%rowtype;
  message_record public.messages%rowtype;
  conversation_record public.conversations%rowtype;
  connection_record public.whatsapp_connections%rowtype;
  effect_record private.effect_ledger%rowtype;
  lease_token_value uuid;
  processed_count integer := 0;
  deferred_count integer := 0;
  dead_count integer := 0;
  error_state text;
begin
  if maximum_messages not between 1 and 100
    or visibility_seconds not between 5 and 3600
  then
    raise exception 'invalid worker bounds' using errcode = '22023';
  end if;

  for message_index in 1..maximum_messages loop
    queue_record := null;
    select claimed.* into queue_record
    from pgmq.read(
      queue_name => 'outbound_whatsapp',
      vt => visibility_seconds,
      qty => 1,
      conditional => '{}'::jsonb
    ) as claimed
    limit 1;
    exit when queue_record.msg_id is null;

    begin
      select event.* into strict event_record
      from private.outbox_events as event
      where event.id = (queue_record.message ->> 'outbox_event_id')::uuid
      for update;

      if event_record.status = 'completed' then
        perform pgmq.archive('outbound_whatsapp', queue_record.msg_id);
        processed_count := processed_count + 1;
        continue;
      end if;

      if exists (
        select 1
        from private.outbox_events as earlier
        where earlier.organization_id = event_record.organization_id
          and earlier.operation_id = event_record.operation_id
          and earlier.aggregate_type = event_record.aggregate_type
          and earlier.aggregate_id = event_record.aggregate_id
          and earlier.aggregate_sequence < event_record.aggregate_sequence
          and earlier.status in ('pending', 'published', 'processing')
      ) then
        perform private.defer_queue_message(
          'outbound_whatsapp', queue_record.msg_id, 2
        );
        deferred_count := deferred_count + 1;
        continue;
      end if;

      if queue_record.read_ct > event_record.max_attempts then
        perform private.dead_letter_queue_message(
          'outbound_whatsapp',
          queue_record.msg_id,
          event_record.id,
          event_record.idempotency_key,
          queue_record.message,
          queue_record.read_ct,
          'attempts_exhausted',
          'max_attempts',
          event_record.organization_id,
          event_record.operation_id,
          event_record.trace_id,
          event_record.correlation_id
        );
        update private.outbox_events
        set
          status = 'dead',
          attempts = queue_record.read_ct,
          last_error_class = 'attempts_exhausted',
          last_error_code = 'max_attempts',
          updated_at = now()
        where id = event_record.id;
        dead_count := dead_count + 1;
        continue;
      end if;

      select message.* into strict message_record
      from public.messages as message
      where message.id = (event_record.payload ->> 'message_id')::uuid
      for update;
      select conversation.* into strict conversation_record
      from public.conversations as conversation
      where conversation.id = message_record.conversation_id
      for update;
      select connection.* into strict connection_record
      from public.whatsapp_connections as connection
      where connection.id = message_record.connection_id
      for share;

      if connection_record.adapter_type <> 'simulator'
        or not connection_record.is_test
      then
        raise exception 'real provider egress is disabled'
          using errcode = '42501';
      end if;

      lease_token_value := private.acquire_conversation_lease(
        conversation_record.id,
        target_worker_id,
        conversation_record.version,
        event_record.aggregate_sequence,
        visibility_seconds
      );
      if lease_token_value is null then
        raise exception 'conversation lease unavailable'
          using errcode = '55P03';
      end if;

      insert into private.effect_ledger (
        organization_id, operation_id, effect_key, effect_type,
        request_hash, state, trace_id, correlation_id
      )
      values (
        event_record.organization_id, event_record.operation_id,
        event_record.idempotency_key, event_record.event_type,
        event_record.payload_hash, 'prepared',
        event_record.trace_id, event_record.correlation_id
      )
      on conflict (organization_id, operation_id, effect_key)
      do nothing;

      select effect.* into strict effect_record
      from private.effect_ledger as effect
      where effect.organization_id = event_record.organization_id
        and effect.operation_id = event_record.operation_id
        and effect.effect_key = event_record.idempotency_key
      for update;

      if effect_record.request_hash <> event_record.payload_hash then
        raise exception 'effect replay payload conflict'
          using errcode = '23505';
      end if;
      if effect_record.state = 'outcome_unknown' then
        raise exception 'provider outcome requires reconciliation'
          using errcode = 'P0001';
      end if;
      if effect_record.state = 'effect_recorded'
        or message_record.status = 'captured'
      then
        update private.outbox_events
        set status = 'completed', completed_at = now(), updated_at = now()
        where id = event_record.id;
        perform private.release_conversation_lease(
          conversation_record.id, lease_token_value
        );
        perform pgmq.archive('outbound_whatsapp', queue_record.msg_id);
        processed_count := processed_count + 1;
        continue;
      end if;

      update private.effect_ledger
      set
        state = 'request_started',
        started_at = coalesce(started_at, now()),
        updated_at = now()
      where id = effect_record.id;

      insert into private.simulator_outbound_captures (
        organization_id, operation_id, connection_id, conversation_id,
        message_id, provider_chat_id, command_payload
      )
      values (
        message_record.organization_id,
        message_record.operation_id,
        message_record.connection_id,
        message_record.conversation_id,
        message_record.id,
        conversation_record.provider_chat_id,
        jsonb_build_object(
          'kind', message_record.kind,
          'text', message_record.body,
          'adapter', 'simulator'
        )
      )
      on conflict (message_id) do nothing;

      update public.messages
      set status = 'captured'
      where id = message_record.id;
      update private.effect_ledger
      set
        state = 'effect_recorded',
        response_hash = encode(
          sha256(convert_to(message_record.id::text, 'UTF8')),
          'hex'
        ),
        recorded_at = now(),
        updated_at = now()
      where id = effect_record.id;
      update private.outbox_events
      set
        status = 'completed',
        completed_at = now(),
        updated_at = now(),
        last_error_class = null,
        last_error_code = null
      where id = event_record.id;

      insert into audit.audit_events (
        organization_id, operation_id, actor_user_id, action,
        target_type, target_id, before_state, after_state,
        trace_id, correlation_id
      )
      values (
        event_record.organization_id,
        event_record.operation_id,
        null,
        'message.outbound_captured',
        'message',
        message_record.id,
        jsonb_build_object('status', 'queued'),
        jsonb_build_object(
          'status', 'captured',
          'adapter', 'simulator',
          'egress_attempted', false
        ),
        event_record.trace_id,
        event_record.correlation_id
      );

      perform private.release_conversation_lease(
        conversation_record.id, lease_token_value
      );
      perform pgmq.archive('outbound_whatsapp', queue_record.msg_id);
      insert into private.processing_attempts (
        organization_id, operation_id, queue_name, queue_message_id,
        envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
        worker_id, lease_token, attempt, state, trace_id, correlation_id
      )
      values (
        event_record.organization_id, event_record.operation_id,
        'outbound_whatsapp', queue_record.msg_id, event_record.id,
        event_record.aggregate_type, event_record.aggregate_id,
        event_record.aggregate_sequence, target_worker_id,
        lease_token_value, queue_record.read_ct, 'succeeded',
        event_record.trace_id, event_record.correlation_id
      );
      processed_count := processed_count + 1;
    exception when others then
      get stacked diagnostics error_state = returned_sqlstate;
      update private.outbox_events
      set
        status = 'published',
        last_error_class = left(error_state, 120),
        last_error_code = left(error_state, 120),
        updated_at = now()
      where id = (queue_record.message ->> 'outbox_event_id')::uuid
        and status <> 'completed';
      perform private.defer_queue_message(
        'outbound_whatsapp',
        queue_record.msg_id,
        least(300, greatest(2, power(2, least(queue_record.read_ct, 8))::integer))
      );
      deferred_count := deferred_count + 1;
    end;
  end loop;

  return jsonb_build_object(
    'processed', processed_count,
    'deferred', deferred_count,
    'dead_lettered', dead_count,
    'worker_id', target_worker_id
  );
end;
$$;

revoke all on function private.consume_outbound_whatsapp(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

create or replace function private.consume_reconciliation(
  maximum_messages integer default 50
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  queue_record pgmq.message_record;
  event_id_value uuid;
  consumed integer := 0;
begin
  for message_index in 1..greatest(1, least(maximum_messages, 500)) loop
    queue_record := null;
    select claimed.* into queue_record
    from pgmq.read(
      queue_name => 'reconciliation',
      vt => 30,
      qty => 1,
      conditional => '{}'::jsonb
    ) as claimed
    limit 1;
    exit when queue_record.msg_id is null;
    event_id_value := (queue_record.message ->> 'outbox_event_id')::uuid;
    update private.outbox_events
    set status = 'completed', completed_at = now(), updated_at = now()
    where id = event_id_value
      and status <> 'completed';
    perform pgmq.archive('reconciliation', queue_record.msg_id);
    consumed := consumed + 1;
  end loop;
  return consumed;
end;
$$;

revoke all on function private.consume_reconciliation(integer)
  from public, anon, authenticated, service_role;

create or replace function private.dispatch_due_scheduled_jobs(
  maximum_jobs integer default 100
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_record public.scheduled_jobs%rowtype;
  queue_id bigint;
  dispatched integer := 0;
begin
  for job_record in
    select job.*
    from public.scheduled_jobs as job
    where job.status = 'pending'
      and job.run_at <= now()
    order by job.run_at, job.id
    for update skip locked
    limit greatest(1, least(maximum_jobs, 500))
  loop
    update public.scheduled_jobs
    set
      status = 'leased',
      lease_token = gen_random_uuid(),
      lease_until = now() + interval '30 seconds',
      attempts = attempts + 1,
      updated_at = now()
    where id = job_record.id
    returning * into strict job_record;

    select sent.msg_id into strict queue_id
    from pgmq.send(
      queue_name => job_record.target_queue,
      msg => jsonb_build_object(
        'scheduled_job_id', job_record.id,
        'organization_id', job_record.organization_id,
        'operation_id', job_record.operation_id,
        'aggregate_type', job_record.aggregate_type,
        'aggregate_id', job_record.aggregate_id,
        'aggregate_version', job_record.aggregate_version,
        'trace_id', job_record.trace_id,
        'correlation_id', job_record.correlation_id
      )
    ) as sent(msg_id);

    update public.scheduled_jobs
    set
      status = 'published',
      lease_token = null,
      lease_until = null,
      queue_message_id = queue_id,
      published_at = now(),
      updated_at = now()
    where id = job_record.id;
    dispatched := dispatched + 1;
  end loop;
  return dispatched;
end;
$$;

create or replace function private.recover_durable_processing()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  inbox_record private.webhook_inbox%rowtype;
  queue_id bigint;
  recovered_inbox integer := 0;
  recovered_jobs integer := 0;
begin
  for inbox_record in
    select inbox.*
    from private.webhook_inbox as inbox
    where (
      inbox.status = 'processing'
      and inbox.processing_started_at < now() - interval '2 minutes'
    )
    order by inbox.accepted_at
    for update skip locked
    limit 100
  loop
    select sent.msg_id into strict queue_id
    from pgmq.send(
      queue_name => 'inbound_whatsapp',
      msg => jsonb_build_object(
        'inbox_id', inbox_record.id,
        'organization_id', inbox_record.organization_id,
        'operation_id', inbox_record.operation_id,
        'stream_key', inbox_record.stream_key,
        'stream_sequence', inbox_record.stream_sequence,
        'trace_id', inbox_record.trace_id,
        'correlation_id', inbox_record.correlation_id
      )
    ) as sent(msg_id);
    update private.webhook_inbox
    set
      status = 'accepted',
      processing_started_at = null,
      queue_message_id = queue_id,
      updated_at = now()
    where id = inbox_record.id;
    recovered_inbox := recovered_inbox + 1;
  end loop;

  update public.scheduled_jobs
  set
    status = 'pending',
    lease_token = null,
    lease_until = null,
    updated_at = now(),
    last_error_class = 'lease_expired',
    last_error_code = 'scheduler_recovery'
  where status = 'leased'
    and lease_until <= now();
  get diagnostics recovered_jobs = row_count;

  return jsonb_build_object(
    'inbox', recovered_inbox,
    'scheduled_jobs', recovered_jobs
  );
end;
$$;

create or replace function private.run_durable_workers(
  maximum_messages integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  inbound_result jsonb;
  outbound_result jsonb;
  first_dispatch integer;
  second_dispatch integer;
  reconciled integer;
begin
  -- The renamed T05 domain function keeps its service-role guard. Cron has no
  -- request JWT, so this private/revoked worker installs a transaction-local
  -- service claim before invoking it.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );
  first_dispatch := private.dispatch_outbox_events(maximum_messages * 2);
  inbound_result := private.consume_inbound_whatsapp(
    maximum_messages,
    gen_random_uuid(),
    30
  );
  second_dispatch := private.dispatch_outbox_events(maximum_messages * 2);
  outbound_result := private.consume_outbound_whatsapp(
    maximum_messages,
    gen_random_uuid(),
    30
  );
  reconciled := private.consume_reconciliation(maximum_messages * 2);
  return jsonb_build_object(
    'inbound', inbound_result,
    'outbound', outbound_result,
    'outbox_dispatched', first_dispatch + second_dispatch,
    'reconciled', reconciled
  );
end;
$$;

revoke all on function private.dispatch_due_scheduled_jobs(integer)
  from public, anon, authenticated, service_role;
revoke all on function private.recover_durable_processing()
  from public, anon, authenticated, service_role;
revoke all on function private.run_durable_workers(integer)
  from public, anon, authenticated, service_role;

create or replace function public.run_durable_workers(
  maximum_messages integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;
  return private.run_durable_workers(maximum_messages);
end;
$$;

revoke all on function public.run_durable_workers(integer)
  from public, anon, authenticated, service_role;
grant execute on function public.run_durable_workers(integer)
  to service_role;

create or replace function public.replay_dead_letter(
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
  queue_id bigint;
begin
  select letter.*
  into strict letter_record
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id
  for update;

  if not private.has_membership_permission(
    letter_record.operation_id,
    'manage_conversations'
  ) then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;
  if letter_record.status = 'replayed' then
    return jsonb_build_object(
      'status', 'duplicate',
      'dead_letter_id', letter_record.id,
      'queue_message_id', letter_record.replay_queue_message_id
    );
  end if;

  if letter_record.source_queue = 'inbound_whatsapp' then
    select sent.msg_id into strict queue_id
    from pgmq.send(
      queue_name => letter_record.source_queue,
      msg => letter_record.redacted_envelope
    ) as sent(msg_id);
    update private.webhook_inbox
    set
      status = 'accepted',
      attempts = 0,
      queue_message_id = queue_id,
      processing_started_at = null,
      processed_at = null,
      last_error_class = null,
      last_error_code = null,
      updated_at = now()
    where id = letter_record.envelope_id;
  else
    update private.outbox_events
    set
      status = 'pending',
      attempts = 0,
      queue_message_id = null,
      published_at = null,
      completed_at = null,
      last_error_class = null,
      last_error_code = null,
      updated_at = now()
    where id = letter_record.envelope_id;
    queue_id := null;
  end if;

  update private.dead_letters
  set
    status = 'replayed',
    replayed_at = now(),
    replayed_by_user_id = auth.uid(),
    replay_queue_message_id = queue_id
  where id = letter_record.id;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    letter_record.organization_id,
    letter_record.operation_id,
    auth.uid(),
    'dead_letter.replayed',
    'dead_letter',
    letter_record.id,
    jsonb_build_object(
      'status', letter_record.status,
      'source_queue', letter_record.source_queue,
      'effect_key_hash', md5(letter_record.effect_key)
    ),
    jsonb_build_object(
      'status', 'replayed',
      'effect_key_preserved', true
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'status', 'replayed',
    'dead_letter_id', letter_record.id,
    'queue_message_id', queue_id
  );
end;
$$;

revoke all on function public.replay_dead_letter(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.replay_dead_letter(uuid, uuid, uuid)
  to authenticated;

-- SQL Cron is only a durable wake/recovery safety net. The request path also
-- makes an authenticated best-effort call to the short Edge worker.
select cron.schedule(
  't06-scheduled-jobs-1s',
  '* * * * * *',
  'select private.dispatch_due_scheduled_jobs(100);'
);
select cron.schedule(
  't06-worker-recovery-5s',
  '*/5 * * * * *',
  'select private.run_durable_workers(25);'
);
select cron.schedule(
  't06-reconciliation-1m',
  '0 * * * * *',
  'select private.recover_durable_processing();'
);
