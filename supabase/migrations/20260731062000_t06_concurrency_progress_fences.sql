-- T06 post-Preview concurrency, progress, and retention fences.

-- Reserve canonical artifacts with an update lock before the legacy
-- consumers try to mutate them. SKIP LOCKED turns duplicate physical queue
-- envelopes into bounded contention instead of a KEY SHARE -> UPDATE
-- conversion deadlock. Inbound also owns the stream row for the transaction,
-- which is the common fence used by replay below.
create or replace function private.reserve_valid_queue_batch(
  target_queue text,
  maximum_messages integer,
  visibility_seconds integer,
  target_worker_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  queue_record pgmq.message_record;
  envelope_id_value uuid;
  envelope_field text;
  artifact_exists boolean;
  artifact_locked boolean;
  stream_exists boolean;
  stream_locked boolean;
  inbox_organization_id uuid;
  inbox_operation_id uuid;
  inbox_stream_key text;
  artifact_aggregate_type text;
  artifact_aggregate_id uuid;
  artifact_aggregate_sequence bigint;
  artifact_attempts integer;
  artifact_trace_id uuid;
  artifact_correlation_id uuid;
  applied_contentions integer;
  valid_count integer := 0;
  quarantined_count integer := 0;
  deferred_count integer := 0;
  failure_code text;
begin
  if target_queue not in (
    'inbound_whatsapp',
    'outbound_whatsapp',
    'reconciliation'
  )
    or maximum_messages not between 1 and 100
    or visibility_seconds not between 5 and 3600
  then
    raise exception 'invalid queue reservation bounds'
      using errcode = '22023';
  end if;

  envelope_field := case
    when target_queue = 'inbound_whatsapp' then 'inbox_id'
    else 'outbox_event_id'
  end;

  for queue_record in
    select claimed.*
    from pgmq.read(
      queue_name => target_queue,
      vt => visibility_seconds,
      qty => maximum_messages,
      conditional => '{}'::jsonb
    ) as claimed
    order by claimed.msg_id
  loop
    envelope_id_value := null;
    artifact_exists := false;
    artifact_locked := false;
    stream_exists := false;
    stream_locked := false;
    inbox_organization_id := null;
    inbox_operation_id := null;
    inbox_stream_key := null;
    artifact_aggregate_type := null;
    artifact_aggregate_id := null;
    artifact_aggregate_sequence := null;
    artifact_attempts := 0;
    artifact_trace_id := null;
    artifact_correlation_id := null;
    applied_contentions := 0;
    failure_code := null;

    begin
      envelope_id_value :=
        (queue_record.message ->> envelope_field)::uuid;
    exception when invalid_text_representation then
      envelope_id_value := null;
    end;

    if envelope_id_value is null then
      failure_code := 'invalid_envelope';
    elsif target_queue = 'inbound_whatsapp' then
      select
        inbox.organization_id,
        inbox.operation_id,
        inbox.stream_key,
        inbox.attempts,
        inbox.trace_id,
        inbox.correlation_id
      into
        inbox_organization_id,
        inbox_operation_id,
        inbox_stream_key,
        artifact_attempts,
        artifact_trace_id,
        artifact_correlation_id
      from private.webhook_inbox as inbox
      where inbox.id = envelope_id_value;
      artifact_exists := found;

      if artifact_exists then
        select exists (
          select 1
          from private.stream_sequences as stream
          where stream.organization_id = inbox_organization_id
            and stream.operation_id = inbox_operation_id
            and stream.stream_key = inbox_stream_key
        )
        into stream_exists;

        if not stream_exists then
          failure_code := 'stream_fence_missing';
        else
          perform stream.stream_key
          from private.stream_sequences as stream
          where stream.organization_id = inbox_organization_id
            and stream.operation_id = inbox_operation_id
            and stream.stream_key = inbox_stream_key
          for update skip locked;
          stream_locked := found;

          if stream_locked then
            perform inbox.id
            from private.webhook_inbox as inbox
            where inbox.id = envelope_id_value
            for update skip locked;
            artifact_locked := found;
          end if;
        end if;
      end if;
    else
      select
        event.organization_id,
        event.operation_id,
        event.aggregate_type,
        event.aggregate_id,
        event.aggregate_sequence,
        event.attempts,
        event.trace_id,
        event.correlation_id
      into
        inbox_organization_id,
        inbox_operation_id,
        artifact_aggregate_type,
        artifact_aggregate_id,
        artifact_aggregate_sequence,
        artifact_attempts,
        artifact_trace_id,
        artifact_correlation_id
      from private.outbox_events as event
      where event.id = envelope_id_value;
      artifact_exists := found;

      if artifact_exists then
        perform event.id
        from private.outbox_events as event
        where event.id = envelope_id_value
        for update skip locked;
        artifact_locked := found;
      end if;
    end if;

    if failure_code is null and not artifact_exists then
      failure_code := 'artifact_missing';
    end if;

    if failure_code is not null then
      perform private.dead_letter_queue_message(
        target_queue,
        queue_record.msg_id,
        coalesce(envelope_id_value, gen_random_uuid()),
        'invalid-envelope:' || target_queue || ':'
          || queue_record.msg_id::text,
        jsonb_build_object(
          'queue_message_id', queue_record.msg_id,
          'envelope_id', envelope_id_value
        ),
        1,
        'non_retryable',
        failure_code,
        null,
        null,
        gen_random_uuid(),
        gen_random_uuid()
      );
      quarantined_count := quarantined_count + 1;
    elsif not artifact_locked then
      insert into private.processing_attempts (
        organization_id,
        operation_id,
        queue_name,
        queue_message_id,
        envelope_id,
        aggregate_type,
        aggregate_id,
        aggregate_sequence,
        worker_id,
        attempt,
        state,
        error_class,
        error_code,
        trace_id,
        correlation_id
      )
      values (
        inbox_organization_id,
        inbox_operation_id,
        target_queue,
        queue_record.msg_id,
        envelope_id_value,
        artifact_aggregate_type,
        artifact_aggregate_id,
        artifact_aggregate_sequence,
        target_worker_id,
        greatest(artifact_attempts + 1, 1),
        'deferred',
        'contention',
        'reservation_locked',
        artifact_trace_id,
        artifact_correlation_id
      );
      perform private.defer_queue_message(
        target_queue,
        queue_record.msg_id,
        private.worker_contention_delay_seconds(
          greatest(queue_record.read_ct, 1)
        )
      );
      deferred_count := deferred_count + 1;
    else
      with acknowledged as (
        update private.processing_attempts as attempt
        set state = 'acknowledged'
        where attempt.queue_name = target_queue
          and attempt.queue_message_id = queue_record.msg_id
          and attempt.envelope_id = envelope_id_value
          and attempt.state = 'deferred'
          and attempt.error_class = 'contention'
          and attempt.error_code = 'reservation_locked'
        returning 1
      )
      select count(*)::integer
      into applied_contentions
      from acknowledged;

      if applied_contentions > 0 then
        if target_queue = 'inbound_whatsapp' then
          update private.webhook_inbox
          set
            contention_count = contention_count + applied_contentions,
            updated_at = now()
          where id = envelope_id_value;
        else
          update private.outbox_events
          set
            contention_count = contention_count + applied_contentions,
            updated_at = now()
          where id = envelope_id_value;
        end if;
      end if;

      perform *
      from pgmq.set_vt(
        queue_name => target_queue,
        msg_id => queue_record.msg_id,
        vt => 0
      );
      valid_count := valid_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'valid', valid_count,
    'quarantined', quarantined_count,
    'deferred', deferred_count
  );
end;
$$;

revoke all on function private.reserve_valid_queue_batch(
  text, integer, integer, uuid
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
  reservation jsonb;
  base_result jsonb;
  contention_result jsonb;
  valid_count integer;
  quarantined_count integer;
  reserved_deferred_count integer;
  requeued_count integer;
begin
  reservation := private.reserve_valid_queue_batch(
    'inbound_whatsapp',
    maximum_messages,
    visibility_seconds,
    target_worker_id
  );
  valid_count := (reservation ->> 'valid')::integer;
  quarantined_count := (reservation ->> 'quarantined')::integer;
  reserved_deferred_count := (reservation ->> 'deferred')::integer;

  if valid_count = 0 then
    return jsonb_build_object(
      'processed', 0,
      'deferred', reserved_deferred_count,
      'dead_lettered', quarantined_count,
      'worker_id', target_worker_id
    );
  end if;

  base_result := private.consume_inbound_whatsapp_t06_fenced_base(
    valid_count,
    target_worker_id,
    visibility_seconds
  );
  contention_result :=
    private.normalize_worker_contention(target_worker_id);
  requeued_count :=
    coalesce((contention_result ->> 'requeued_from_dead')::integer, 0);

  base_result := jsonb_set(
    base_result,
    '{dead_lettered}',
    to_jsonb(
      coalesce((base_result ->> 'dead_lettered')::integer, 0)
        + quarantined_count
        - requeued_count
    )
  );
  return jsonb_set(
    base_result,
    '{deferred}',
    to_jsonb(
      coalesce((base_result ->> 'deferred')::integer, 0)
        + reserved_deferred_count
        + requeued_count
    )
  );
end;
$$;

revoke all on function private.consume_inbound_whatsapp(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

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
  reservation jsonb;
  base_result jsonb;
  contention_result jsonb;
  valid_count integer;
  quarantined_count integer;
  reserved_deferred_count integer;
  requeued_count integer;
begin
  reservation := private.reserve_valid_queue_batch(
    'outbound_whatsapp',
    maximum_messages,
    visibility_seconds,
    target_worker_id
  );
  valid_count := (reservation ->> 'valid')::integer;
  quarantined_count := (reservation ->> 'quarantined')::integer;
  reserved_deferred_count := (reservation ->> 'deferred')::integer;

  if valid_count = 0 then
    return jsonb_build_object(
      'processed', 0,
      'deferred', reserved_deferred_count,
      'dead_lettered', quarantined_count,
      'suppressed', 0,
      'worker_id', target_worker_id
    );
  end if;

  base_result := private.consume_outbound_whatsapp_t06_fenced_base(
    valid_count,
    target_worker_id,
    visibility_seconds
  );
  contention_result :=
    private.normalize_worker_contention(target_worker_id);
  requeued_count :=
    coalesce((contention_result ->> 'requeued_from_dead')::integer, 0);

  base_result := jsonb_set(
    base_result,
    '{dead_lettered}',
    to_jsonb(
      coalesce((base_result ->> 'dead_lettered')::integer, 0)
        + quarantined_count
        - requeued_count
    )
  );
  return jsonb_set(
    base_result,
    '{deferred}',
    to_jsonb(
      coalesce((base_result ->> 'deferred')::integer, 0)
        + reserved_deferred_count
        + requeued_count
    )
  );
end;
$$;

revoke all on function private.consume_outbound_whatsapp(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

-- Replays share the same stream row with inbound consumption. Once this row
-- is held, N+1 either committed before replay (and the inner stale check sees
-- it) or cannot begin until replay N commits.
alter function public.replay_dead_letter(uuid, uuid, uuid)
  rename to replay_dead_letter_t06_stream_fenced_base;

revoke all on function public.replay_dead_letter_t06_stream_fenced_base(
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
  inbox_record private.webhook_inbox%rowtype;
  event_record private.outbox_events%rowtype;
  effect_record private.effect_ledger%rowtype;
begin
  select letter.*
  into strict letter_record
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id;

  if letter_record.operation_id is null
    or not private.has_membership_permission(
      letter_record.operation_id,
      'manage_conversations'
    )
  then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;

  if letter_record.source_queue = 'inbound_whatsapp' then
    select inbox.*
    into inbox_record
    from private.webhook_inbox as inbox
    where inbox.id = letter_record.envelope_id;

    if inbox_record.id is not null then
      perform stream.stream_key
      from private.stream_sequences as stream
      where stream.organization_id = inbox_record.organization_id
        and stream.operation_id = inbox_record.operation_id
        and stream.stream_key = inbox_record.stream_key
      for update;
    end if;
  elsif letter_record.source_queue in (
    'outbound_whatsapp',
    'reconciliation'
  ) then
    select event.*
    into event_record
    from private.outbox_events as event
    where event.id = letter_record.envelope_id
    for update;

    if event_record.id is not null then
      select effect.*
      into effect_record
      from private.effect_ledger as effect
      where effect.organization_id = event_record.organization_id
        and effect.operation_id = event_record.operation_id
        and effect.effect_key = event_record.idempotency_key
      for update;

      if effect_record.state in ('request_started', 'outcome_unknown') then
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
          'dead_letter.replay_outcome_unknown_rejected',
          'dead_letter',
          letter_record.id,
          jsonb_build_object('status', letter_record.status),
          jsonb_build_object(
            'status', letter_record.status,
            'reason', 'effect_outcome_requires_reconciliation',
            'effect_key_preserved', true
          ),
          request_trace_id,
          request_correlation_id
        );

        return jsonb_build_object(
          'status', 'rejected_outcome_unknown',
          'reason', 'effect_outcome_requires_reconciliation',
          'dead_letter_id', letter_record.id
        );
      end if;
    end if;
  end if;

  return public.replay_dead_letter_t06_stream_fenced_base(
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

-- Reconciliation is a real consumer, not an unconditional ACK. A valid
-- published event completes idempotently; impossible states are quarantined;
-- transient database failures back off and consume their own durable budget.
create or replace function private.consume_reconciliation_detailed(
  maximum_messages integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  reservation jsonb;
  reservation_worker_id uuid := gen_random_uuid();
  queue_record pgmq.message_record;
  event_record private.outbox_events%rowtype;
  valid_count integer;
  quarantined_count integer;
  reserved_deferred_count integer;
  processed_count integer := 0;
  deferred_count integer := 0;
  dead_count integer := 0;
  next_failure_attempt integer;
  contention_attempt integer;
  error_state text;
  failure_class text;
  semantic_failure text;
begin
  if maximum_messages not between 1 and 100 then
    raise exception 'invalid reconciliation worker bound'
      using errcode = '22023';
  end if;

  reservation := private.reserve_valid_queue_batch(
    'reconciliation',
    maximum_messages,
    30,
    reservation_worker_id
  );
  valid_count := (reservation ->> 'valid')::integer;
  quarantined_count := (reservation ->> 'quarantined')::integer;
  reserved_deferred_count := (reservation ->> 'deferred')::integer;
  deferred_count := reserved_deferred_count;
  dead_count := quarantined_count;

  for message_index in 1..valid_count loop
    queue_record := null;
    event_record := null;
    semantic_failure := null;

    select claimed.*
    into queue_record
    from pgmq.read(
      queue_name => 'reconciliation',
      vt => 30,
      qty => 1,
      conditional => '{}'::jsonb
    ) as claimed
    limit 1;
    exit when queue_record.msg_id is null;

    select event.*
    into strict event_record
    from private.outbox_events as event
    where event.id =
      (queue_record.message ->> 'outbox_event_id')::uuid
    for update;

    insert into private.processing_attempts (
      organization_id,
      operation_id,
      queue_name,
      queue_message_id,
      envelope_id,
      aggregate_type,
      aggregate_id,
      aggregate_sequence,
      worker_id,
      attempt,
      state,
      trace_id,
      correlation_id
    )
    values (
      event_record.organization_id,
      event_record.operation_id,
      'reconciliation',
      queue_record.msg_id,
      event_record.id,
      event_record.aggregate_type,
      event_record.aggregate_id,
      event_record.aggregate_sequence,
      null,
      greatest(event_record.attempts + 1, 1),
      'claimed',
      event_record.trace_id,
      event_record.correlation_id
    );

    if event_record.status = 'completed' then
      perform pgmq.archive('reconciliation', queue_record.msg_id);
      insert into private.processing_attempts (
        organization_id,
        operation_id,
        queue_name,
        queue_message_id,
        envelope_id,
        aggregate_type,
        aggregate_id,
        aggregate_sequence,
        attempt,
        state,
        trace_id,
        correlation_id
      )
      values (
        event_record.organization_id,
        event_record.operation_id,
        'reconciliation',
        queue_record.msg_id,
        event_record.id,
        event_record.aggregate_type,
        event_record.aggregate_id,
        event_record.aggregate_sequence,
        greatest(event_record.attempts + 1, 1),
        'acknowledged',
        event_record.trace_id,
        event_record.correlation_id
      );
      processed_count := processed_count + 1;
      continue;
    elsif event_record.status not in ('published', 'processing') then
      semantic_failure := 'reconciliation_state_' || event_record.status;
    end if;

    if semantic_failure is not null then
      next_failure_attempt := event_record.attempts + 1;
      perform private.dead_letter_queue_message(
        'reconciliation',
        queue_record.msg_id,
        event_record.id,
        event_record.idempotency_key,
        jsonb_build_object(
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
        ),
        next_failure_attempt,
        'non_retryable',
        semantic_failure,
        event_record.organization_id,
        event_record.operation_id,
        event_record.trace_id,
        event_record.correlation_id
      );
      update private.outbox_events
      set
        status = 'dead',
        attempts = next_failure_attempt,
        last_error_class = 'non_retryable',
        last_error_code = semantic_failure,
        updated_at = now()
      where id = event_record.id;
      insert into private.processing_attempts (
        organization_id,
        operation_id,
        queue_name,
        queue_message_id,
        envelope_id,
        aggregate_type,
        aggregate_id,
        aggregate_sequence,
        attempt,
        state,
        error_class,
        error_code,
        trace_id,
        correlation_id
      )
      values (
        event_record.organization_id,
        event_record.operation_id,
        'reconciliation',
        queue_record.msg_id,
        event_record.id,
        event_record.aggregate_type,
        event_record.aggregate_id,
        event_record.aggregate_sequence,
        next_failure_attempt,
        'dead_lettered',
        'non_retryable',
        semantic_failure,
        event_record.trace_id,
        event_record.correlation_id
      );
      dead_count := dead_count + 1;
      continue;
    end if;

    begin
      update private.outbox_events
      set
        status = 'completed',
        completed_at = now(),
        last_error_class = null,
        last_error_code = null,
        updated_at = now()
      where id = event_record.id;
      perform pgmq.archive('reconciliation', queue_record.msg_id);
      insert into private.processing_attempts (
        organization_id,
        operation_id,
        queue_name,
        queue_message_id,
        envelope_id,
        aggregate_type,
        aggregate_id,
        aggregate_sequence,
        attempt,
        state,
        trace_id,
        correlation_id
      )
      values (
        event_record.organization_id,
        event_record.operation_id,
        'reconciliation',
        queue_record.msg_id,
        event_record.id,
        event_record.aggregate_type,
        event_record.aggregate_id,
        event_record.aggregate_sequence,
        greatest(event_record.attempts + 1, 1),
        'succeeded',
        event_record.trace_id,
        event_record.correlation_id
      );
      processed_count := processed_count + 1;
    exception when others then
      get stacked diagnostics error_state = returned_sqlstate;
      failure_class := private.classify_worker_failure(error_state);

      if failure_class = 'contention' then
        update private.outbox_events
        set
          contention_count = contention_count + 1,
          last_error_class = 'contention',
          last_error_code = left(error_state, 120),
          updated_at = now()
        where id = event_record.id
        returning contention_count into strict contention_attempt;
        perform private.defer_queue_message(
          'reconciliation',
          queue_record.msg_id,
          private.worker_contention_delay_seconds(contention_attempt)
        );
        insert into private.processing_attempts (
          organization_id,
          operation_id,
          queue_name,
          queue_message_id,
          envelope_id,
          aggregate_type,
          aggregate_id,
          aggregate_sequence,
          attempt,
          state,
          error_class,
          error_code,
          trace_id,
          correlation_id
        )
        values (
          event_record.organization_id,
          event_record.operation_id,
          'reconciliation',
          queue_record.msg_id,
          event_record.id,
          event_record.aggregate_type,
          event_record.aggregate_id,
          event_record.aggregate_sequence,
          greatest(event_record.attempts + 1, 1),
          'deferred',
          'contention',
          left(error_state, 120),
          event_record.trace_id,
          event_record.correlation_id
        );
        deferred_count := deferred_count + 1;
      else
        next_failure_attempt := event_record.attempts + 1;

        if failure_class = 'retryable'
          and next_failure_attempt < event_record.max_attempts
        then
          update private.outbox_events
          set
            attempts = next_failure_attempt,
            last_error_class = failure_class,
            last_error_code = left(error_state, 120),
            updated_at = now()
          where id = event_record.id;
          perform private.defer_queue_message(
            'reconciliation',
            queue_record.msg_id,
            private.worker_retry_delay_seconds(next_failure_attempt, 300)
          );
          insert into private.processing_attempts (
            organization_id,
            operation_id,
            queue_name,
            queue_message_id,
            envelope_id,
            aggregate_type,
            aggregate_id,
            aggregate_sequence,
            attempt,
            state,
            error_class,
            error_code,
            trace_id,
            correlation_id
          )
          values (
            event_record.organization_id,
            event_record.operation_id,
            'reconciliation',
            queue_record.msg_id,
            event_record.id,
            event_record.aggregate_type,
            event_record.aggregate_id,
            event_record.aggregate_sequence,
            next_failure_attempt,
            'retryable_failed',
            failure_class,
            left(error_state, 120),
            event_record.trace_id,
            event_record.correlation_id
          );
          deferred_count := deferred_count + 1;
        else
          perform private.dead_letter_queue_message(
            'reconciliation',
            queue_record.msg_id,
            event_record.id,
            event_record.idempotency_key,
            jsonb_build_object(
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
            ),
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
            organization_id,
            operation_id,
            queue_name,
            queue_message_id,
            envelope_id,
            aggregate_type,
            aggregate_id,
            aggregate_sequence,
            attempt,
            state,
            error_class,
            error_code,
            trace_id,
            correlation_id
          )
          values (
            event_record.organization_id,
            event_record.operation_id,
            'reconciliation',
            queue_record.msg_id,
            event_record.id,
            event_record.aggregate_type,
            event_record.aggregate_id,
            event_record.aggregate_sequence,
            next_failure_attempt,
            'dead_lettered',
            failure_class,
            left(error_state, 120),
            event_record.trace_id,
            event_record.correlation_id
          );
          dead_count := dead_count + 1;
        end if;
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'processed', processed_count,
    'deferred', deferred_count,
    'dead_lettered', dead_count,
    'quarantined', quarantined_count
  );
end;
$$;

revoke all on function private.consume_reconciliation_detailed(integer)
  from public, anon, authenticated, service_role;

create or replace function private.consume_reconciliation(
  maximum_messages integer default 50
)
returns integer
language sql
security definer
set search_path = ''
as $$
  select coalesce(
    (
      private.consume_reconciliation_detailed(maximum_messages)
        ->> 'processed'
    )::integer,
    0
  );
$$;

revoke all on function private.consume_reconciliation(integer)
  from public, anon, authenticated, service_role;

-- One wake performs a constant amount of work per iteration. Dispatch is kept
-- at one item because the dispatcher intentionally exposes only the earliest
-- incomplete sequence of an aggregate.
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
  scheduled_result jsonb;
  outbound_iteration jsonb;
  reconciliation_iteration jsonb;
  dispatched_iteration integer;
  dispatched_total integer := 0;
  outbound_processed integer := 0;
  outbound_deferred integer := 0;
  outbound_dead integer := 0;
  outbound_suppressed integer := 0;
  reconciliation_processed integer := 0;
  reconciliation_deferred integer := 0;
  reconciliation_dead integer := 0;
  dead_signal_count integer := 0;
  iteration_progress integer;
begin
  if maximum_messages not between 1 and 100 then
    raise exception 'invalid worker bound' using errcode = '22023';
  end if;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );

  inbound_result := private.consume_inbound_whatsapp(
    maximum_messages,
    gen_random_uuid(),
    30
  );
  scheduled_result := private.consume_scheduled_actions(
    maximum_messages,
    gen_random_uuid(),
    30
  );

  for drain_iteration in 1..maximum_messages loop
    dispatched_iteration := private.dispatch_outbox_events(1);
    outbound_iteration := private.consume_outbound_whatsapp(
      1,
      gen_random_uuid(),
      30
    );
    reconciliation_iteration :=
      private.consume_reconciliation_detailed(1);

    dispatched_total := dispatched_total + dispatched_iteration;
    outbound_processed := outbound_processed
      + coalesce((outbound_iteration ->> 'processed')::integer, 0);
    outbound_deferred := outbound_deferred
      + coalesce((outbound_iteration ->> 'deferred')::integer, 0);
    outbound_dead := outbound_dead
      + coalesce((outbound_iteration ->> 'dead_lettered')::integer, 0);
    outbound_suppressed := outbound_suppressed
      + coalesce((outbound_iteration ->> 'suppressed')::integer, 0);
    reconciliation_processed := reconciliation_processed
      + coalesce(
        (reconciliation_iteration ->> 'processed')::integer,
        0
      );
    reconciliation_deferred := reconciliation_deferred
      + coalesce(
        (reconciliation_iteration ->> 'deferred')::integer,
        0
      );
    reconciliation_dead := reconciliation_dead
      + coalesce(
        (reconciliation_iteration ->> 'dead_lettered')::integer,
        0
      );

    iteration_progress :=
      dispatched_iteration
      + coalesce((outbound_iteration ->> 'processed')::integer, 0)
      + coalesce((outbound_iteration ->> 'deferred')::integer, 0)
      + coalesce((outbound_iteration ->> 'dead_lettered')::integer, 0)
      + coalesce((outbound_iteration ->> 'suppressed')::integer, 0)
      + coalesce(
        (reconciliation_iteration ->> 'processed')::integer,
        0
      )
      + coalesce(
        (reconciliation_iteration ->> 'deferred')::integer,
        0
      )
      + coalesce(
        (reconciliation_iteration ->> 'dead_lettered')::integer,
        0
      );
    exit when iteration_progress = 0;
  end loop;

  dead_signal_count := private.consume_dead_letter_signals(
    least(maximum_messages * 4, 500)
  );

  return jsonb_build_object(
    'inbound', inbound_result,
    'scheduled', scheduled_result,
    'outbound', jsonb_build_object(
      'processed', outbound_processed,
      'deferred', outbound_deferred,
      'dead_lettered', outbound_dead,
      'suppressed', outbound_suppressed
    ),
    'reconciliation', jsonb_build_object(
      'processed', reconciliation_processed,
      'deferred', reconciliation_deferred,
      'dead_lettered', reconciliation_dead
    ),
    'outbox_dispatched', dispatched_total,
    'reconciled', reconciliation_processed,
    'dead_letter_signals', dead_signal_count
  );
end;
$$;

revoke all on function private.run_durable_workers(integer)
  from public, anon, authenticated, service_role;

-- Raw ingress material includes the normalized provider payload. It follows
-- the same bounded policy as the exact body, including terminal dead inboxes.
drop index private.webhook_inbox_raw_retention_idx;
create index webhook_inbox_raw_retention_idx
  on private.webhook_inbox (
    (coalesce(processed_at, updated_at)),
    id
  )
  where status in ('processed', 'unsupported', 'dead')
    and raw_payload_purged_at is null;

create or replace function private.prune_durable_sensitive_material(
  maximum_rows integer default 5000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  purged_inbox integer := 0;
  purged_letters integer := 0;
begin
  if maximum_rows not between 1 and 25000 then
    raise exception 'invalid durable retention bound'
      using errcode = '22023';
  end if;

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
    'resolved_dead_letters_purged', purged_letters
  );
end;
$$;

revoke all on function private.prune_durable_sensitive_material(integer)
  from public, anon, authenticated, service_role;

-- PGMQ archives are operational history, not the canonical business log.
-- Delete at most maximum_rows across the fixed T06 archive allowlist.
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
  archive_table text;
  deleted_for_queue integer;
  deleted_total integer := 0;
  remaining_rows integer := maximum_rows;
  result_value jsonb := '{}'::jsonb;
begin
  if retention_window < interval '1 day'
    or retention_window > interval '90 days'
    or maximum_rows not between 1 and 100000
  then
    raise exception 'invalid queue archive retention bounds'
      using errcode = '22023';
  end if;

  foreach archive_table in array array[
    'a_inbound_whatsapp',
    'a_outbound_whatsapp',
    'a_scheduled_actions',
    'a_reconciliation',
    'a_dead_letter'
  ]
  loop
    exit when remaining_rows = 0;

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

    deleted_total := deleted_total + deleted_for_queue;
    remaining_rows := remaining_rows - deleted_for_queue;
    result_value := jsonb_set(
      result_value,
      array[archive_table],
      to_jsonb(deleted_for_queue),
      true
    );
  end loop;

  return result_value || jsonb_build_object('total', deleted_total);
end;
$$;

revoke all on function private.prune_t06_queue_archives(
  interval, integer
) from public, anon, authenticated, service_role;

select cron.schedule(
  't06-pgmq-archive-retention-hourly',
  '47 * * * *',
  $cron$
    select private.prune_t06_queue_archives(
      interval '7 days',
      25000
    );
  $cron$
);

-- Infrastructure alerts cannot be owned by a tenant, so a service-only
-- administrative action is required to acknowledge them and start the same
-- resolved dead-letter retention clock used by tenant alerts.
alter table private.durable_processing_alerts
  add column resolution_source text
    check (
      resolution_source is null
      or resolution_source in ('artifact', 'service_role')
    ),
  add column resolution_trace_id uuid,
  add column resolution_correlation_id uuid;

create or replace function private.resolve_dead_letter_processing_alert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('replayed', 'resolved')
    and old.status is distinct from new.status
  then
    update private.durable_processing_alerts
    set
      status = 'resolved',
      resolved_at = coalesce(resolved_at, now()),
      resolution_source = coalesce(resolution_source, 'artifact')
    where dead_letter_id = new.id
      and status = 'open';
  end if;
  return null;
end;
$$;

revoke all on function private.resolve_dead_letter_processing_alert()
  from public, anon, authenticated, service_role;

create or replace function public.resolve_infrastructure_durable_alert(
  target_alert_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  alert_record private.durable_processing_alerts%rowtype;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select alert.*
  into strict alert_record
  from private.durable_processing_alerts as alert
  where alert.id = target_alert_id
    and alert.organization_id is null
    and alert.operation_id is null
  for update;

  if alert_record.status = 'resolved' then
    return jsonb_build_object(
      'status', 'duplicate',
      'alert_id', alert_record.id,
      'dead_letter_id', alert_record.dead_letter_id
    );
  end if;

  update private.durable_processing_alerts
  set
    status = 'resolved',
    resolved_at = now(),
    resolution_source = 'service_role',
    resolution_trace_id = request_trace_id,
    resolution_correlation_id = request_correlation_id
  where id = alert_record.id;

  update private.dead_letters
  set
    status = 'resolved',
    resolved_at = coalesce(resolved_at, now())
  where id = alert_record.dead_letter_id
    and status = 'pending';

  return jsonb_build_object(
    'status', 'resolved',
    'alert_id', alert_record.id,
    'dead_letter_id', alert_record.dead_letter_id
  );
end;
$$;

revoke all on function public.resolve_infrastructure_durable_alert(
  uuid, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.resolve_infrastructure_durable_alert(
  uuid, uuid, uuid
) to service_role;
