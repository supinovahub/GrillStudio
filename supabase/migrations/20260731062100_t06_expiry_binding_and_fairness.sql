-- T06 expiry, queue binding, and retention fairness corrections.

alter table private.dead_letters
  add column resolution_reason text
    check (
      resolution_reason is null
      or char_length(resolution_reason) between 1 and 120
    );

-- A dead inbound whose payload reaches the retention boundary is no longer
-- replayable. Resolve its pending letter first so the later payload purge
-- cannot create a replay loop with an empty normalized envelope.
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

  with expiring_inbox as (
    select inbox.id
    from private.webhook_inbox as inbox
    left join private.durable_retention_policies as policy
      on policy.organization_id = inbox.organization_id
      and policy.operation_id = inbox.operation_id
    where inbox.status = 'dead'
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
  update private.dead_letters as letter
  set
    status = 'resolved',
    resolved_at = coalesce(letter.resolved_at, now()),
    resolution_reason = 'payload_expired'
  from expiring_inbox
  where letter.source_queue = 'inbound_whatsapp'
    and letter.envelope_id = expiring_inbox.id
    and letter.status = 'pending';
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

alter function public.replay_dead_letter(uuid, uuid, uuid)
  rename to replay_dead_letter_t06_payload_expiry_base;

revoke all on function public.replay_dead_letter_t06_payload_expiry_base(
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

  if letter_record.status = 'resolved'
    and letter_record.resolution_reason = 'payload_expired'
  then
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
      'dead_letter.replay_expired_rejected',
      'dead_letter',
      letter_record.id,
      jsonb_build_object(
        'status', letter_record.status,
        'resolution_reason', letter_record.resolution_reason
      ),
      jsonb_build_object(
        'status', 'resolved',
        'reason', 'payload_expired',
        'effect_key_preserved', true
      ),
      request_trace_id,
      request_correlation_id
    );

    return jsonb_build_object(
      'status', 'rejected_expired',
      'reason', 'payload_expired',
      'dead_letter_id', letter_record.id
    );
  end if;

  return public.replay_dead_letter_t06_payload_expiry_base(
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

-- Reconciliation may acknowledge any already-completed event, including a
-- suppression signal. A live event is mutable only when this exact physical
-- queue message is the canonical publication for target_queue=reconciliation.
alter function private.consume_reconciliation_detailed(integer)
  rename to consume_reconciliation_detailed_t06_binding_base;

revoke all on function
  private.consume_reconciliation_detailed_t06_binding_base(integer)
  from public, anon, authenticated, service_role;

create function private.consume_reconciliation_detailed(
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
  return jsonb_set(
    base_result,
    '{dead_lettered}',
    to_jsonb(
      coalesce((base_result ->> 'dead_lettered')::integer, 0)
        + mismatch_count
    )
  );
end;
$$;

revoke all on function private.consume_reconciliation_detailed(integer)
  from public, anon, authenticated, service_role;

-- Divide each run across all five archive tables. The starting table rotates
-- so very small manual bounds do not permanently privilege the first queue.
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
  deleted_for_queue integer;
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

  base_quota := maximum_rows / cardinality(archive_tables);
  remainder := maximum_rows % cardinality(archive_tables);
  start_offset :=
    floor(extract(epoch from clock_timestamp()))::bigint
      % cardinality(archive_tables);

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

  return result_value || jsonb_build_object('total', deleted_total);
end;
$$;

revoke all on function private.prune_t06_queue_archives(
  interval, integer
) from public, anon, authenticated, service_role;

-- A deadlock can be selected while atomic acceptance holds Stream and PGMQ
-- in the reverse order of a worker transaction. Retry only transactional
-- concurrency classes; each failed subtransaction is fully rolled back.
alter function private.ingest_simulated_inbound(
  uuid, jsonb, text, uuid, uuid
) rename to ingest_simulated_inbound_t06_acceptance_base;

revoke all on function private.ingest_simulated_inbound_t06_acceptance_base(
  uuid, jsonb, text, uuid, uuid
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
  retry_number integer;
begin
  for retry_number in 1..3 loop
    begin
      return private.ingest_simulated_inbound_t06_acceptance_base(
        target_connection_id,
        normalized_event,
        raw_request_body,
        request_trace_id,
        request_correlation_id
      );
    exception
      when deadlock_detected
        or serialization_failure
        or lock_not_available
      then
        if retry_number = 3 then
          raise;
        end if;
        perform pg_sleep(0.01 * retry_number);
    end;
  end loop;

  raise exception 'unreachable inbound retry state'
    using errcode = 'XX000';
end;
$$;

revoke all on function private.ingest_simulated_inbound(
  uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated, service_role;

create table private.infrastructure_durable_alert_resolutions (
  alert_id uuid primary key,
  dead_letter_id uuid not null,
  resolution_trace_id uuid not null,
  resolution_correlation_id uuid not null,
  resolved_at timestamptz not null default now(),
  foreign key (alert_id)
    references private.durable_processing_alerts(id) on delete cascade,
  foreign key (dead_letter_id)
    references private.dead_letters(id) on delete cascade
);

comment on table private.infrastructure_durable_alert_resolutions is
  'Redacted service-only audit of null-organization durable alert resolution.';

revoke all on table private.infrastructure_durable_alert_resolutions
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
  if target_alert_id is null
    or request_trace_id is null
    or request_correlation_id is null
  then
    raise exception 'alert, trace, and correlation identifiers are required'
      using errcode = '22023';
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
    resolved_at = coalesce(resolved_at, now()),
    resolution_reason = coalesce(
      resolution_reason,
      'service_acknowledged'
    )
  where id = alert_record.dead_letter_id
    and status = 'pending';

  insert into private.infrastructure_durable_alert_resolutions (
    alert_id,
    dead_letter_id,
    resolution_trace_id,
    resolution_correlation_id
  )
  values (
    alert_record.id,
    alert_record.dead_letter_id,
    request_trace_id,
    request_correlation_id
  )
  on conflict (alert_id) do nothing;

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
