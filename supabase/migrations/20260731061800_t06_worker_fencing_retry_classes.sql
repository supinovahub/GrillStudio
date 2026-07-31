-- T06 review: fence outbound effects against their exact aggregate snapshot
-- and keep queue contention separate from the durable failure budget.

alter table private.webhook_inbox
  add column contention_count integer not null default 0
    check (contention_count >= 0);

alter table private.outbox_events
  add column contention_count integer not null default 0
    check (contention_count >= 0);

comment on column private.webhook_inbox.attempts is
  'Durable processing failures only. PGMQ read_ct and contention do not consume this budget.';
comment on column private.webhook_inbox.contention_count is
  'Predecessor or lease waits. Informational only and never a dead-letter budget.';
comment on column private.outbox_events.attempts is
  'Durable effect failures only. Dispatch, PGMQ read_ct and contention do not consume this budget.';
comment on column private.outbox_events.contention_count is
  'Predecessor or lease waits. Informational only and never a dead-letter budget.';

alter table private.processing_attempts
  drop constraint processing_attempts_state_check,
  add constraint processing_attempts_state_check
  check (
    state in (
      'claimed',
      'deferred',
      'succeeded',
      'retryable_failed',
      'dead_lettered',
      'suppressed',
      'replayed',
      'acknowledged'
    )
  );

create or replace function private.classify_worker_failure(
  error_sqlstate text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when error_sqlstate in (
      '40001',
      '40P01',
      '55P03',
      '57014'
    )
      or error_sqlstate like '08%'
      or error_sqlstate like '53%'
      or error_sqlstate like '57P%'
      then 'retryable'
    when error_sqlstate in (
      '23503',
      '23505',
      '23514',
      'PGRST'
    )
      then 'conflict'
    when error_sqlstate in (
      '22023',
      '22P02',
      '23502',
      '42501',
      'P0002'
    )
      then 'non_retryable'
    else 'unknown'
  end;
$$;

create or replace function private.worker_retry_delay_seconds(
  failure_attempt integer,
  maximum_delay integer default 300
)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  base_delay integer;
  jitter_ceiling integer;
begin
  base_delay := least(
    greatest(maximum_delay, 2),
    greatest(2, power(2, least(greatest(failure_attempt, 1), 8))::integer)
  );
  jitter_ceiling := greatest(1, ceil(base_delay * 0.25)::integer);
  return least(
    greatest(maximum_delay, 2),
    base_delay + floor(random() * (jitter_ceiling + 1))::integer
  );
end;
$$;

create or replace function private.worker_contention_delay_seconds(
  contention_attempt integer
)
returns integer
language sql
volatile
security invoker
set search_path = ''
as $$
  select least(
    15,
    2 + least(greatest(contention_attempt, 1), 8)
      + floor(random() * 4)::integer
  );
$$;

revoke all on function private.classify_worker_failure(text)
  from public, anon, authenticated, service_role;
revoke all on function private.worker_retry_delay_seconds(integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function private.worker_contention_delay_seconds(integer)
  from public, anon, authenticated, service_role;

-- Keep the previous implementations available for a surgical rollback, but
-- make every runtime caller resolve the new functions below.
alter function private.dispatch_outbox_events(integer)
  rename to dispatch_outbox_events_t06_read_ct_base;
alter function private.consume_inbound_whatsapp(integer, uuid, integer)
  rename to consume_inbound_whatsapp_t06_read_ct_base;
alter function private.consume_outbound_whatsapp(integer, uuid, integer)
  rename to consume_outbound_whatsapp_t06_read_ct_base;

revoke all on function private.dispatch_outbox_events_t06_read_ct_base(integer)
  from public, anon, authenticated, service_role;
revoke all on function private.consume_inbound_whatsapp_t06_read_ct_base(
  integer, uuid, integer
) from public, anon, authenticated, service_role;
revoke all on function private.consume_outbound_whatsapp_t06_read_ct_base(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

create function private.dispatch_outbox_events(
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

create function private.consume_inbound_whatsapp(
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
  leased_conversation_id uuid;
  lease_token_value uuid;
  aggregate_sequence_value bigint;
  payload_value jsonb;
  payload_hash_value text;
  error_state text;
  failure_class text;
  next_failure_attempt integer;
  contention_attempt integer;
begin
  if maximum_messages not between 1 and 100
    or visibility_seconds not between 5 and 3600
  then
    raise exception 'invalid worker bounds' using errcode = '22023';
  end if;

  for message_index in 1..maximum_messages loop
    queue_record := null;
    inbox_record := null;
    conversation_id_value := null;
    conversation_version := null;
    leased_conversation_id := null;
    lease_token_value := null;

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
      target_worker_id, greatest(inbox_record.attempts + 1, 1), 'claimed',
      inbox_record.trace_id, inbox_record.correlation_id
    );

    if inbox_record.status in ('processed', 'unsupported') then
      perform pgmq.archive('inbound_whatsapp', queue_record.msg_id);
      processed_count := processed_count + 1;
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
      update private.webhook_inbox
      set
        contention_count = contention_count + 1,
        updated_at = now()
      where id = inbox_record.id
      returning contention_count into strict contention_attempt;
      perform private.defer_queue_message(
        'inbound_whatsapp',
        queue_record.msg_id,
        private.worker_contention_delay_seconds(contention_attempt)
      );
      insert into private.processing_attempts (
        organization_id, operation_id, queue_name, queue_message_id,
        envelope_id, aggregate_type, aggregate_sequence, worker_id,
        attempt, state, error_class, error_code, trace_id, correlation_id
      )
      values (
        inbox_record.organization_id, inbox_record.operation_id,
        'inbound_whatsapp', queue_record.msg_id, inbox_record.id,
        'conversation_stream', inbox_record.stream_sequence,
        target_worker_id, greatest(inbox_record.attempts + 1, 1),
        'deferred', 'contention', 'predecessor_pending',
        inbox_record.trace_id, inbox_record.correlation_id
      );
      deferred_count := deferred_count + 1;
      continue;
    end if;

    begin
      update private.webhook_inbox
      set
        status = 'processing',
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
        leased_conversation_id := conversation_id_value;
        lease_token_value := private.acquire_conversation_lease(
          leased_conversation_id,
          target_worker_id,
          conversation_version,
          inbox_record.stream_sequence,
          visibility_seconds
        );
        if lease_token_value is null then
          update private.webhook_inbox
          set
            status = 'accepted',
            processing_started_at = null,
            contention_count = contention_count + 1,
            updated_at = now()
          where id = inbox_record.id
          returning contention_count into strict contention_attempt;
          perform private.defer_queue_message(
            'inbound_whatsapp',
            queue_record.msg_id,
            private.worker_contention_delay_seconds(contention_attempt)
          );
          insert into private.processing_attempts (
            organization_id, operation_id, queue_name, queue_message_id,
            envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
            worker_id, attempt, state, error_class, error_code,
            trace_id, correlation_id
          )
          values (
            inbox_record.organization_id, inbox_record.operation_id,
            'inbound_whatsapp', queue_record.msg_id, inbox_record.id,
            'conversation', leased_conversation_id,
            inbox_record.stream_sequence, target_worker_id,
            greatest(inbox_record.attempts + 1, 1), 'deferred',
            'contention', 'lease_unavailable',
            inbox_record.trace_id, inbox_record.correlation_id
          );
          deferred_count := deferred_count + 1;
          continue;
        end if;

        -- Extend visibility only after this claimant holds the aggregate
        -- fence. A competing reader cannot use read_ct as a failure signal.
        perform private.defer_queue_message(
          'inbound_whatsapp',
          queue_record.msg_id,
          visibility_seconds
        );
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
        processing_started_at = null,
        updated_at = now(),
        last_error_class = null,
        last_error_code = null
      where id = inbox_record.id;

      if lease_token_value is not null then
        perform private.release_conversation_lease(
          leased_conversation_id,
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
        target_worker_id, lease_token_value,
        greatest(inbox_record.attempts + 1, 1),
        'succeeded', inbox_record.trace_id, inbox_record.correlation_id
      );
      processed_count := processed_count + 1;
    exception when others then
      get stacked diagnostics error_state = returned_sqlstate;
      failure_class := private.classify_worker_failure(error_state);
      next_failure_attempt := inbox_record.attempts + 1;

      if failure_class = 'retryable'
        and next_failure_attempt < inbox_record.max_attempts
      then
        update private.webhook_inbox
        set
          status = 'accepted',
          attempts = next_failure_attempt,
          last_error_class = failure_class,
          last_error_code = left(error_state, 120),
          processing_started_at = null,
          updated_at = now()
        where id = inbox_record.id;
        perform private.defer_queue_message(
          'inbound_whatsapp',
          queue_record.msg_id,
          private.worker_retry_delay_seconds(next_failure_attempt, 300)
        );
        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, worker_id, attempt, state,
          error_class, error_code, trace_id, correlation_id
        )
        values (
          inbox_record.organization_id, inbox_record.operation_id,
          'inbound_whatsapp', queue_record.msg_id, inbox_record.id,
          target_worker_id, next_failure_attempt, 'retryable_failed',
          failure_class, left(error_state, 120),
          inbox_record.trace_id, inbox_record.correlation_id
        );
        deferred_count := deferred_count + 1;
      else
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
          next_failure_attempt,
          failure_class,
          left(error_state, 120),
          inbox_record.organization_id,
          inbox_record.operation_id,
          inbox_record.trace_id,
          inbox_record.correlation_id
        );
        update private.webhook_inbox
        set
          status = 'dead',
          attempts = next_failure_attempt,
          last_error_class = failure_class,
          last_error_code = left(error_state, 120),
          processing_started_at = null,
          updated_at = now()
        where id = inbox_record.id;
        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, worker_id, attempt, state,
          error_class, error_code, trace_id, correlation_id
        )
        values (
          inbox_record.organization_id, inbox_record.operation_id,
          'inbound_whatsapp', queue_record.msg_id, inbox_record.id,
          target_worker_id, next_failure_attempt, 'dead_lettered',
          failure_class, left(error_state, 120),
          inbox_record.trace_id, inbox_record.correlation_id
        );
        dead_count := dead_count + 1;
      end if;
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

create function private.consume_outbound_whatsapp(
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
  suppressed_count integer := 0;
  error_state text;
  failure_class text;
  next_failure_attempt integer;
  contention_attempt integer;
  preflight_failure text;
  actor_membership_active boolean;
  actor_operation_allowed boolean;
begin
  if maximum_messages not between 1 and 100
    or visibility_seconds not between 5 and 3600
  then
    raise exception 'invalid worker bounds' using errcode = '22023';
  end if;

  for message_index in 1..maximum_messages loop
    queue_record := null;
    event_record := null;
    message_record := null;
    conversation_record := null;
    connection_record := null;
    effect_record := null;
    lease_token_value := null;
    preflight_failure := null;
    actor_membership_active := false;
    actor_operation_allowed := false;

    select claimed.*
    into queue_record
    from pgmq.read(
      queue_name => 'outbound_whatsapp',
      vt => visibility_seconds,
      qty => 1,
      conditional => '{}'::jsonb
    ) as claimed
    limit 1;
    exit when queue_record.msg_id is null;

    select event.*
    into strict event_record
    from private.outbox_events as event
    where event.id = (queue_record.message ->> 'outbox_event_id')::uuid
    for update;

    insert into private.processing_attempts (
      organization_id, operation_id, queue_name, queue_message_id,
      envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
      worker_id, attempt, state, trace_id, correlation_id
    )
    values (
      event_record.organization_id, event_record.operation_id,
      'outbound_whatsapp', queue_record.msg_id, event_record.id,
      event_record.aggregate_type, event_record.aggregate_id,
      event_record.aggregate_sequence, target_worker_id,
      greatest(event_record.attempts + 1, 1), 'claimed',
      event_record.trace_id, event_record.correlation_id
    );

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
      update private.outbox_events
      set
        contention_count = contention_count + 1,
        updated_at = now()
      where id = event_record.id
      returning contention_count into strict contention_attempt;
      perform private.defer_queue_message(
        'outbound_whatsapp',
        queue_record.msg_id,
        private.worker_contention_delay_seconds(contention_attempt)
      );
      insert into private.processing_attempts (
        organization_id, operation_id, queue_name, queue_message_id,
        envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
        worker_id, attempt, state, error_class, error_code,
        trace_id, correlation_id
      )
      values (
        event_record.organization_id, event_record.operation_id,
        'outbound_whatsapp', queue_record.msg_id, event_record.id,
        event_record.aggregate_type, event_record.aggregate_id,
        event_record.aggregate_sequence, target_worker_id,
        greatest(event_record.attempts + 1, 1), 'deferred',
        'contention', 'predecessor_pending',
        event_record.trace_id, event_record.correlation_id
      );
      deferred_count := deferred_count + 1;
      continue;
    end if;

    begin
      select message.*
      into strict message_record
      from public.messages as message
      where message.id = (event_record.payload ->> 'message_id')::uuid
      for update;

      select conversation.*
      into strict conversation_record
      from public.conversations as conversation
      where conversation.id = message_record.conversation_id
      for update;

      select connection.*
      into strict connection_record
      from public.whatsapp_connections as connection
      where connection.id = message_record.connection_id
      for share;

      -- Deactivation also locks Conversation before Membership. Preserve that
      -- order, then hold both actor rows until the effect commits so an actor
      -- cannot be revoked between preflight and capture.
      select membership.status = 'active'
      into actor_membership_active
      from public.memberships as membership
      where membership.organization_id = event_record.organization_id
        and membership.id = message_record.created_by_membership_id
      for share;
      actor_membership_active := coalesce(actor_membership_active, false);

      perform membership_operation.membership_id
      from public.membership_operations as membership_operation
      where membership_operation.organization_id =
          event_record.organization_id
        and membership_operation.membership_id =
          message_record.created_by_membership_id
        and membership_operation.operation_id = event_record.operation_id
      for share;
      actor_operation_allowed := found;

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

      select effect.*
      into strict effect_record
      from private.effect_ledger as effect
      where effect.organization_id = event_record.organization_id
        and effect.operation_id = event_record.operation_id
        and effect.effect_key = event_record.idempotency_key
      for update;

      if effect_record.request_hash <> event_record.payload_hash then
        raise exception 'effect replay payload conflict'
          using errcode = '23505';
      end if;

      if effect_record.state = 'effect_recorded'
        or message_record.status = 'captured'
      then
        update private.effect_ledger
        set
          state = 'effect_recorded',
          response_hash = coalesce(
            response_hash,
            encode(
              sha256(convert_to(message_record.id::text, 'UTF8')),
              'hex'
            )
          ),
          recorded_at = coalesce(recorded_at, now()),
          updated_at = now()
        where id = effect_record.id;
        update private.outbox_events
        set
          status = 'completed',
          completed_at = coalesce(completed_at, now()),
          updated_at = now(),
          last_error_class = null,
          last_error_code = null
        where id = event_record.id;
        perform pgmq.archive('outbound_whatsapp', queue_record.msg_id);
        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
          worker_id, attempt, state, trace_id, correlation_id
        )
        values (
          event_record.organization_id, event_record.operation_id,
          'outbound_whatsapp', queue_record.msg_id, event_record.id,
          event_record.aggregate_type, event_record.aggregate_id,
          event_record.aggregate_sequence, target_worker_id,
          greatest(event_record.attempts + 1, 1), 'succeeded',
          event_record.trace_id, event_record.correlation_id
        );
        processed_count := processed_count + 1;
        continue;
      end if;

      if effect_record.state in ('request_started', 'outcome_unknown') then
        raise exception 'provider outcome requires reconciliation'
          using errcode = 'P0001';
      end if;

      -- No effect may start unless the canonical aggregate is still exactly
      -- the snapshot that authorized this command.
      if event_record.status not in ('published', 'processing') then
        preflight_failure := 'event_status_stale';
      elsif event_record.target_queue <> 'outbound_whatsapp'
        or event_record.event_type <> 'message.send_requested.v1'
        or event_record.aggregate_type <> 'conversation'
        or event_record.aggregate_id <> conversation_record.id
      then
        preflight_failure := 'event_contract_stale';
      elsif message_record.organization_id <> event_record.organization_id
        or message_record.operation_id <> event_record.operation_id
        or message_record.conversation_id <> event_record.aggregate_id
        or message_record.connection_id <> conversation_record.connection_id
        or message_record.id::text
          <> coalesce(event_record.payload ->> 'message_id', '')
        or message_record.conversation_id::text
          <> coalesce(event_record.payload ->> 'conversation_id', '')
        or message_record.connection_id::text
          <> coalesce(event_record.payload ->> 'connection_id', '')
      then
        preflight_failure := 'message_binding_stale';
      elsif message_record.direction <> 'outbound'
        or message_record.status <> 'queued'
        or message_record.created_by_type <> 'human'
        or message_record.created_by_membership_id is null
      then
        preflight_failure := 'message_status_stale';
      elsif conversation_record.organization_id
          <> event_record.organization_id
        or conversation_record.operation_id <> event_record.operation_id
        or conversation_record.version <> event_record.aggregate_version
      then
        preflight_failure := 'aggregate_version_stale';
      elsif conversation_record.status not in ('active', 'sleeping')
        or conversation_record.is_paused
        or conversation_record.pending_return
      then
        preflight_failure := 'conversation_status_stale';
      elsif conversation_record.ownership_type <> 'human'
        or conversation_record.assigned_membership_id
          is distinct from message_record.created_by_membership_id
      then
        preflight_failure := 'conversation_ownership_stale';
      elsif event_record.actor_type <> 'user'
        or event_record.actor_reference
          is distinct from message_record.created_by_membership_id::text
        or not actor_membership_active
        or not actor_operation_allowed
      then
        preflight_failure := 'actor_stale';
      elsif connection_record.organization_id
          <> event_record.organization_id
        or connection_record.operation_id <> event_record.operation_id
        or connection_record.id <> conversation_record.connection_id
        or connection_record.status <> 'active'
        or connection_record.adapter_type <> 'simulator'
        or not connection_record.is_test
      then
        preflight_failure := 'connection_stale';
      end if;

      if preflight_failure is not null then
        update private.effect_ledger
        set
          state = 'suppressed',
          updated_at = now()
        where id = effect_record.id
          and state = 'prepared';
        update private.outbox_events
        set
          status = 'completed',
          completed_at = now(),
          updated_at = now(),
          last_error_class = 'conflict',
          last_error_code = preflight_failure
        where id = event_record.id;

        perform pgmq.send(
          queue_name => 'reconciliation',
          msg => jsonb_build_object(
            'outbox_event_id', event_record.id,
            'organization_id', event_record.organization_id,
            'operation_id', event_record.operation_id,
            'aggregate_type', event_record.aggregate_type,
            'aggregate_id', event_record.aggregate_id,
            'aggregate_version', event_record.aggregate_version,
            'reason_code', preflight_failure,
            'trace_id', event_record.trace_id,
            'correlation_id', event_record.correlation_id
          )
        );
        perform pgmq.archive('outbound_whatsapp', queue_record.msg_id);

        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
          worker_id, attempt, state, error_class, error_code,
          trace_id, correlation_id
        )
        values (
          event_record.organization_id, event_record.operation_id,
          'outbound_whatsapp', queue_record.msg_id, event_record.id,
          event_record.aggregate_type, event_record.aggregate_id,
          event_record.aggregate_sequence, target_worker_id,
          greatest(event_record.attempts + 1, 1), 'suppressed',
          'conflict', preflight_failure,
          event_record.trace_id, event_record.correlation_id
        );

        insert into audit.audit_events (
          organization_id, operation_id, actor_user_id, action,
          target_type, target_id, before_state, after_state,
          trace_id, correlation_id
        )
        values (
          event_record.organization_id,
          event_record.operation_id,
          null,
          'message.outbound_suppressed',
          'message',
          message_record.id,
          jsonb_build_object(
            'status', message_record.status,
            'aggregate_version', event_record.aggregate_version
          ),
          jsonb_build_object(
            'status', message_record.status,
            'suppressed', true,
            'reason_code', preflight_failure,
            'egress_attempted', false,
            'current_version', conversation_record.version
          ),
          event_record.trace_id,
          event_record.correlation_id
        );
        suppressed_count := suppressed_count + 1;
        continue;
      end if;

      lease_token_value := private.acquire_conversation_lease(
        conversation_record.id,
        target_worker_id,
        event_record.aggregate_version,
        event_record.aggregate_sequence,
        visibility_seconds
      );
      if lease_token_value is null then
        update private.outbox_events
        set
          contention_count = contention_count + 1,
          updated_at = now()
        where id = event_record.id
        returning contention_count into strict contention_attempt;
        perform private.defer_queue_message(
          'outbound_whatsapp',
          queue_record.msg_id,
          private.worker_contention_delay_seconds(contention_attempt)
        );
        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
          worker_id, attempt, state, error_class, error_code,
          trace_id, correlation_id
        )
        values (
          event_record.organization_id, event_record.operation_id,
          'outbound_whatsapp', queue_record.msg_id, event_record.id,
          event_record.aggregate_type, event_record.aggregate_id,
          event_record.aggregate_sequence, target_worker_id,
          greatest(event_record.attempts + 1, 1), 'deferred',
          'contention', 'lease_unavailable',
          event_record.trace_id, event_record.correlation_id
        );
        deferred_count := deferred_count + 1;
        continue;
      end if;

      -- This claimant owns both the aggregate lease and the PGMQ visibility
      -- fence before the synthetic adapter records any effect.
      perform private.defer_queue_message(
        'outbound_whatsapp',
        queue_record.msg_id,
        visibility_seconds
      );
      update private.outbox_events
      set status = 'processing', updated_at = now()
      where id = event_record.id;
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
      where id = message_record.id
        and status = 'queued';
      if not found then
        raise exception 'message changed after outbound preflight'
          using errcode = '40001';
      end if;

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
        jsonb_build_object(
          'status', 'queued',
          'aggregate_version', event_record.aggregate_version
        ),
        jsonb_build_object(
          'status', 'captured',
          'adapter', 'simulator',
          'egress_attempted', false,
          'aggregate_version', event_record.aggregate_version
        ),
        event_record.trace_id,
        event_record.correlation_id
      );

      perform private.release_conversation_lease(
        conversation_record.id,
        lease_token_value
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
        lease_token_value, greatest(event_record.attempts + 1, 1),
        'succeeded', event_record.trace_id, event_record.correlation_id
      );
      processed_count := processed_count + 1;
    exception when others then
      get stacked diagnostics error_state = returned_sqlstate;
      failure_class := private.classify_worker_failure(error_state);
      next_failure_attempt := event_record.attempts + 1;

      if failure_class = 'retryable'
        and next_failure_attempt < event_record.max_attempts
      then
        update private.outbox_events
        set
          status = 'published',
          attempts = next_failure_attempt,
          last_error_class = failure_class,
          last_error_code = left(error_state, 120),
          updated_at = now()
        where id = event_record.id
          and status <> 'completed';
        perform private.defer_queue_message(
          'outbound_whatsapp',
          queue_record.msg_id,
          private.worker_retry_delay_seconds(next_failure_attempt, 300)
        );
        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
          worker_id, attempt, state, error_class, error_code,
          trace_id, correlation_id
        )
        values (
          event_record.organization_id, event_record.operation_id,
          'outbound_whatsapp', queue_record.msg_id, event_record.id,
          event_record.aggregate_type, event_record.aggregate_id,
          event_record.aggregate_sequence, target_worker_id,
          next_failure_attempt, 'retryable_failed',
          failure_class, left(error_state, 120),
          event_record.trace_id, event_record.correlation_id
        );
        deferred_count := deferred_count + 1;
      else
        if failure_class = 'unknown' then
          insert into private.effect_ledger (
            organization_id, operation_id, effect_key, effect_type,
            request_hash, state, trace_id, correlation_id, started_at
          )
          values (
            event_record.organization_id,
            event_record.operation_id,
            event_record.idempotency_key,
            event_record.event_type,
            event_record.payload_hash,
            'outcome_unknown',
            event_record.trace_id,
            event_record.correlation_id,
            now()
          )
          on conflict (organization_id, operation_id, effect_key)
          do update set
            state = case
              when private.effect_ledger.state = 'effect_recorded'
                then 'effect_recorded'
              else 'outcome_unknown'
            end,
            started_at = coalesce(private.effect_ledger.started_at, now()),
            updated_at = now();
        end if;

        perform private.dead_letter_queue_message(
          'outbound_whatsapp',
          queue_record.msg_id,
          event_record.id,
          event_record.idempotency_key,
          queue_record.message,
          next_failure_attempt,
          failure_class,
          left(error_state, 120),
          event_record.organization_id,
          event_record.operation_id,
          event_record.trace_id,
          event_record.correlation_id
        );
        update private.outbox_events
        set
          status = 'dead',
          attempts = next_failure_attempt,
          last_error_class = failure_class,
          last_error_code = left(error_state, 120),
          updated_at = now()
        where id = event_record.id;
        insert into private.processing_attempts (
          organization_id, operation_id, queue_name, queue_message_id,
          envelope_id, aggregate_type, aggregate_id, aggregate_sequence,
          worker_id, attempt, state, error_class, error_code,
          trace_id, correlation_id
        )
        values (
          event_record.organization_id, event_record.operation_id,
          'outbound_whatsapp', queue_record.msg_id, event_record.id,
          event_record.aggregate_type, event_record.aggregate_id,
          event_record.aggregate_sequence, target_worker_id,
          next_failure_attempt, 'dead_lettered',
          failure_class, left(error_state, 120),
          event_record.trace_id, event_record.correlation_id
        );
        dead_count := dead_count + 1;
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'processed', processed_count,
    'deferred', deferred_count,
    'dead_lettered', dead_count,
    'suppressed', suppressed_count,
    'worker_id', target_worker_id
  );
end;
$$;

revoke all on function private.consume_outbound_whatsapp(
  integer, uuid, integer
) from public, anon, authenticated, service_role;
