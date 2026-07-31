-- T06: redacted dead-letter alerts, ordered scheduled replay, and bounded
-- pg_cron history. No provider payload, message body, command text, or
-- return_message is exposed by these surfaces.

create table private.durable_processing_alerts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid,
  operation_id uuid,
  dead_letter_id uuid not null unique,
  scheduled_job_id uuid,
  source_queue text not null,
  severity text not null default 'action_required'
    check (severity in ('action_required', 'critical')),
  status text not null default 'open'
    check (status in ('open', 'resolved')),
  failure_class text not null
    check (char_length(failure_class) between 1 and 120),
  failure_code text not null
    check (char_length(failure_code) between 1 and 120),
  effect_key_hash text not null
    check (effect_key_hash ~ '^[0-9a-f]{64}$'),
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  foreign key (dead_letter_id)
    references private.dead_letters(id) on delete cascade,
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, operation_id, scheduled_job_id)
    references public.scheduled_jobs(organization_id, operation_id, id)
    on delete cascade,
  check (
    (organization_id is null and operation_id is null)
    or (organization_id is not null and operation_id is not null)
  ),
  check (
    (status = 'open' and resolved_at is null)
    or (status = 'resolved' and resolved_at is not null)
  )
);

create index durable_processing_alerts_open_idx
  on private.durable_processing_alerts (
    operation_id,
    created_at desc,
    id
  )
  where status = 'open';

revoke all on table private.durable_processing_alerts
  from public, anon, authenticated;
grant all on table private.durable_processing_alerts to service_role;

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
  scheduled_job_id_value uuid;
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

  if target_queue = 'scheduled_actions' then
    select job.id
    into scheduled_job_id_value
    from public.scheduled_jobs as job
    where job.id = target_envelope_id
      and job.organization_id = target_organization_id
      and job.operation_id = target_operation_id;
  end if;

  insert into private.durable_processing_alerts (
    organization_id,
    operation_id,
    dead_letter_id,
    scheduled_job_id,
    source_queue,
    severity,
    failure_class,
    failure_code,
    effect_key_hash,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    dead_letter_id,
    scheduled_job_id_value,
    target_queue,
    case
      when target_queue = 'scheduled_actions' then 'action_required'
      else 'critical'
    end,
    left(target_failure_class, 120),
    left(target_failure_code, 120),
    encode(sha256(convert_to(target_effect_key, 'UTF8')), 'hex'),
    target_trace_id,
    target_correlation_id
  )
  on conflict (dead_letter_id)
  do update set
    failure_class = excluded.failure_class,
    failure_code = excluded.failure_code,
    severity = excluded.severity;

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

revoke all on function private.dead_letter_queue_message(
  text, bigint, uuid, text, jsonb, integer, text, text,
  uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.resolve_scheduled_processing_alert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('completed', 'cancelled')
    and old.status is distinct from new.status
  then
    update private.durable_processing_alerts
    set
      status = 'resolved',
      resolved_at = coalesce(resolved_at, now())
    where scheduled_job_id = new.id
      and status = 'open';
  end if;
  return null;
end;
$$;

revoke all on function private.resolve_scheduled_processing_alert()
  from public, anon, authenticated, service_role;

create trigger scheduled_jobs_resolve_processing_alert
after update of status on public.scheduled_jobs
for each row execute function private.resolve_scheduled_processing_alert();

alter function public.replay_dead_letter(
  uuid, uuid, uuid
) rename to replay_dead_letter_t06_base;

revoke all on function public.replay_dead_letter_t06_base(
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
  job_record public.scheduled_jobs%rowtype;
  effect_record private.effect_ledger%rowtype;
  queue_id bigint;
  later_sequence bigint;
begin
  select letter.*
  into strict letter_record
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id
  for update;

  if letter_record.source_queue <> 'scheduled_actions' then
    return public.replay_dead_letter_t06_base(
      target_dead_letter_id,
      request_trace_id,
      request_correlation_id
    );
  end if;

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
  if letter_record.status <> 'pending' then
    raise exception 'only pending dead letters can be replayed'
      using errcode = '23514';
  end if;

  select job.*
  into job_record
  from public.scheduled_jobs as job
  where job.id = letter_record.envelope_id
    and job.organization_id = letter_record.organization_id
    and job.operation_id = letter_record.operation_id
  for update;

  if job_record.id is null
    or job_record.target_queue <> 'scheduled_actions'
    or job_record.effect_key <> letter_record.effect_key
  then
    return jsonb_build_object(
      'status', 'rejected_artifact_conflict',
      'dead_letter_id', letter_record.id
    );
  end if;

  select effect.*
  into effect_record
  from private.effect_ledger as effect
  where effect.organization_id = job_record.organization_id
    and effect.operation_id = job_record.operation_id
    and effect.effect_key = job_record.effect_key
  for update;

  if effect_record.state = 'outcome_unknown' then
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
      job_record.organization_id,
      job_record.operation_id,
      auth.uid(),
      'dead_letter.replay_outcome_unknown_rejected',
      'dead_letter',
      letter_record.id,
      jsonb_build_object('status', letter_record.status),
      jsonb_build_object(
        'status', 'pending',
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

  if effect_record.state = 'effect_recorded'
    or exists (
      select 1
      from private.scheduled_job_executions as execution
      where execution.organization_id = job_record.organization_id
        and execution.operation_id = job_record.operation_id
        and execution.effect_key = job_record.effect_key
    )
  then
    update public.scheduled_jobs
    set
      status = 'completed',
      lease_token = null,
      lease_until = null,
      completed_at = coalesce(completed_at, now()),
      last_error_class = null,
      last_error_code = null,
      updated_at = now()
    where id = job_record.id;
    update private.dead_letters
    set status = 'resolved', resolved_at = now()
    where id = letter_record.id;

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
      job_record.organization_id,
      job_record.operation_id,
      auth.uid(),
      'dead_letter.reconciled',
      'dead_letter',
      letter_record.id,
      jsonb_build_object('status', letter_record.status),
      jsonb_build_object(
        'status', 'resolved',
        'reason', 'effect_already_recorded',
        'effect_key_preserved', true
      ),
      request_trace_id,
      request_correlation_id
    );

    return jsonb_build_object(
      'status', 'reconciled',
      'reason', 'effect_already_recorded',
      'dead_letter_id', letter_record.id
    );
  end if;

  select max(execution.aggregate_sequence)
  into later_sequence
  from private.scheduled_job_executions as execution
  where execution.organization_id = job_record.organization_id
    and execution.operation_id = job_record.operation_id
    and execution.aggregate_type = job_record.aggregate_type
    and execution.aggregate_id = job_record.aggregate_id
    and execution.aggregate_sequence > job_record.aggregate_sequence;

  if effect_record.state = 'suppressed'
    or later_sequence is not null
  then
    update private.effect_ledger
    set state = 'suppressed', updated_at = now()
    where id = effect_record.id
      and state <> 'effect_recorded';
    update public.scheduled_jobs
    set
      status = 'cancelled',
      lease_token = null,
      lease_until = null,
      last_error_class = 'conflict',
      last_error_code = 'stale_aggregate_order',
      updated_at = now()
    where id = job_record.id;
    update private.dead_letters
    set status = 'resolved', resolved_at = now()
    where id = letter_record.id;

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
      job_record.organization_id,
      job_record.operation_id,
      auth.uid(),
      'dead_letter.replay_stale_rejected',
      'dead_letter',
      letter_record.id,
      jsonb_build_object(
        'status', letter_record.status,
        'aggregate_sequence', job_record.aggregate_sequence
      ),
      jsonb_build_object(
        'status', 'resolved',
        'reason', 'later_effect_recorded',
        'later_sequence', later_sequence,
        'effect_key_preserved', true
      ),
      request_trace_id,
      request_correlation_id
    );

    return jsonb_build_object(
      'status', 'rejected_stale',
      'reason', 'later_effect_recorded',
      'dead_letter_id', letter_record.id
    );
  end if;

  if exists (
    select 1
    from public.scheduled_jobs as earlier
    where earlier.organization_id = job_record.organization_id
      and earlier.operation_id = job_record.operation_id
      and earlier.aggregate_type = job_record.aggregate_type
      and earlier.aggregate_id = job_record.aggregate_id
      and earlier.aggregate_sequence < job_record.aggregate_sequence
      and earlier.status in ('pending', 'leased', 'published')
  ) then
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
      job_record.organization_id,
      job_record.operation_id,
      auth.uid(),
      'dead_letter.replay_out_of_order_rejected',
      'dead_letter',
      letter_record.id,
      jsonb_build_object('status', letter_record.status),
      jsonb_build_object(
        'status', 'pending',
        'reason', 'earlier_effect_pending',
        'effect_key_preserved', true
      ),
      request_trace_id,
      request_correlation_id
    );

    return jsonb_build_object(
      'status', 'rejected_out_of_order',
      'reason', 'earlier_effect_pending',
      'dead_letter_id', letter_record.id
    );
  end if;

  select sent.msg_id into strict queue_id
  from pgmq.send(
    queue_name => 'scheduled_actions',
    msg => jsonb_build_object(
      'scheduled_job_id', job_record.id,
      'organization_id', job_record.organization_id,
      'operation_id', job_record.operation_id,
      'aggregate_type', job_record.aggregate_type,
      'aggregate_id', job_record.aggregate_id,
      'aggregate_version', job_record.aggregate_version,
      'aggregate_sequence', job_record.aggregate_sequence,
      'effect_key', job_record.effect_key,
      'trace_id', request_trace_id,
      'correlation_id', request_correlation_id
    )
  ) as sent(msg_id);

  update public.scheduled_jobs
  set
    status = 'published',
    lease_token = null,
    lease_until = null,
    queue_message_id = queue_id,
    published_at = now(),
    completed_at = null,
    attempts = 0,
    contention_count = 0,
    last_error_class = null,
    last_error_code = null,
    updated_at = now()
  where id = job_record.id;

  update private.dead_letters
  set
    status = 'replayed',
    replayed_at = now(),
    replayed_by_user_id = auth.uid(),
    replay_queue_message_id = queue_id
  where id = letter_record.id;

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
    job_record.organization_id,
    job_record.operation_id,
    auth.uid(),
    'dead_letter.replayed',
    'dead_letter',
    letter_record.id,
    jsonb_build_object(
      'status', letter_record.status,
      'source_queue', letter_record.source_queue,
      'aggregate_sequence', job_record.aggregate_sequence
    ),
    jsonb_build_object(
      'status', 'replayed',
      'effect_key_preserved', true,
      'queue_message_id', queue_id
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
  from public, anon, authenticated, service_role;
grant execute on function public.replay_dead_letter(uuid, uuid, uuid)
  to authenticated;

create or replace function public.get_durable_processing_alerts(
  target_operation_id uuid,
  maximum_alerts integer default 100
)
returns table (
  alert_id uuid,
  dead_letter_id uuid,
  scheduled_job_id uuid,
  source_queue text,
  severity text,
  status text,
  failure_class text,
  failure_code text,
  effect_key_hash text,
  trace_id uuid,
  correlation_id uuid,
  created_at timestamptz,
  resolved_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if maximum_alerts not between 1 and 500 then
    raise exception 'invalid alert result bound' using errcode = '22023';
  end if;
  if not private.is_service_role()
    and not private.has_membership_permission(
      target_operation_id,
      'manage_conversations'
    )
  then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;

  return query
  select
    alert.id,
    alert.dead_letter_id,
    alert.scheduled_job_id,
    alert.source_queue,
    alert.severity,
    alert.status,
    alert.failure_class,
    alert.failure_code,
    alert.effect_key_hash,
    alert.trace_id,
    alert.correlation_id,
    alert.created_at,
    alert.resolved_at
  from private.durable_processing_alerts as alert
  where alert.operation_id = target_operation_id
  order by
    case when alert.status = 'open' then 0 else 1 end,
    alert.created_at desc,
    alert.id
  limit maximum_alerts;
end;
$$;

revoke all on function public.get_durable_processing_alerts(uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.get_durable_processing_alerts(uuid, integer)
  to authenticated, service_role;

create or replace function private.prune_cron_job_run_details(
  retention_window interval default interval '7 days',
  maximum_rows integer default 25000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted_rows integer;
begin
  if retention_window < interval '1 day'
    or retention_window > interval '90 days'
    or maximum_rows not between 1 and 100000
  then
    raise exception 'invalid cron retention bounds'
      using errcode = '22023';
  end if;

  with doomed as (
    select run.runid
    from cron.job_run_details as run
    where run.status <> 'running'
      and coalesce(run.end_time, run.start_time)
        < now() - retention_window
    order by coalesce(run.end_time, run.start_time), run.runid
    for update skip locked
    limit maximum_rows
  )
  delete from cron.job_run_details as run
  using doomed
  where run.runid = doomed.runid;

  get diagnostics deleted_rows = row_count;
  return deleted_rows;
end;
$$;

revoke all on function private.prune_cron_job_run_details(interval, integer)
  from public, anon, authenticated, service_role;

create or replace function public.get_cron_runtime_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result_value jsonb;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'observed_at', now(),
    'retention_days', 7,
    'retained_runs', count(*),
    'oldest_retained_start_at', min(run.start_time),
    'failed_last_24h', count(*) filter (
      where run.status = 'failed'
        and run.start_time >= now() - interval '24 hours'
    ),
    'running_over_10m', count(*) filter (
      where run.status = 'running'
        and run.start_time < now() - interval '10 minutes'
    ),
    'jobs', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'job_name', job.jobname,
            'active', job.active,
            'last_status', latest.status,
            'last_started_at', latest.start_time,
            'last_finished_at', latest.end_time
          )
          order by job.jobname
        ),
        '[]'::jsonb
      )
      from cron.job as job
      left join lateral (
        select detail.status, detail.start_time, detail.end_time
        from cron.job_run_details as detail
        where detail.jobid = job.jobid
        order by detail.start_time desc, detail.runid desc
        limit 1
      ) as latest on true
      where job.jobname like 't06-%'
    )
  )
  into result_value
  from cron.job_run_details as run;

  return result_value;
end;
$$;

revoke all on function public.get_cron_runtime_health()
  from public, anon, authenticated, service_role;
grant execute on function public.get_cron_runtime_health()
  to service_role;

select cron.schedule(
  't06-cron-run-details-retention-hourly',
  '23 * * * *',
  $cron$select private.prune_cron_job_run_details(
    interval '7 days',
    25000
  );$cron$
);
