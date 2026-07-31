-- T07 slice (c): durable capacity commands, deterministic response batches,
-- and provider-owned message revisions.  The T06 scheduler only emits a
-- command row; a separate cron transaction owns every capacity mutation.

alter table private.operation_capacity_effects
  add column request_payload jsonb,
  add column request_hash text,
  add column backlog_id uuid,
  add constraint operation_capacity_effects_request_payload_check
    check (
      request_payload is null
      or jsonb_typeof(request_payload) = 'object'
    ),
  add constraint operation_capacity_effects_request_hash_check
    check (
      request_hash is null
      or request_hash ~ '^[0-9a-f]{64}$'
    ),
  add constraint operation_capacity_effects_backlog_tenant_fkey
    foreign key (organization_id, operation_id, backlog_id)
    references private.operation_capacity_backlog(
      organization_id,
      operation_id,
      id
    );

alter table private.operation_capacity_backlog
  add column admitted_effect_id uuid,
  add constraint operation_capacity_backlog_admitted_effect_fkey
    foreign key (admitted_effect_id)
    references private.operation_capacity_effects(id);

alter table private.operation_capacity_state
  add column high_demand_recovery_since timestamptz;

create table private.operation_capacity_commands (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  scheduled_job_id uuid,
  conversation_id uuid,
  backlog_id uuid,
  command_type text not null
    check (
      command_type in (
        'maintenance',
        'drain_backlog',
        'resume_pending_return',
        'sleep',
        'close_response_batch',
        'ready_response_batch'
      )
    ),
  payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload) = 'object'),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  effect_key text not null
    check (char_length(effect_key) between 1 and 500),
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'applied', 'cancelled', 'failed')),
  run_at timestamptz not null,
  attempts integer not null default 0 check (attempts >= 0),
  last_error_code text
    check (
      last_error_code is null
      or char_length(last_error_code) between 1 and 120
    ),
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  applied_at timestamptz,
  unique (organization_id, operation_id, effect_key),
  unique (scheduled_job_id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, operation_id, scheduled_job_id)
    references public.scheduled_jobs(organization_id, operation_id, id)
    on delete cascade,
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade,
  foreign key (organization_id, operation_id, backlog_id)
    references private.operation_capacity_backlog(
      organization_id,
      operation_id,
      id
    ) on delete cascade,
  check (
    (status = 'applied' and applied_at is not null)
    or (status <> 'applied' and applied_at is null)
  )
);

create index operation_capacity_commands_due_idx
  on private.operation_capacity_commands (
    run_at,
    organization_id,
    operation_id,
    id
  )
  where status = 'pending';

create index operation_capacity_commands_operation_idx
  on private.operation_capacity_commands (
    operation_id,
    status,
    run_at,
    id
  );

revoke all on table private.operation_capacity_commands
  from public, anon, authenticated, service_role;

create or replace function private.capacity_request_payload(
  target_operation_id uuid,
  target_conversation_id uuid,
  command_type text,
  target_admission_kind text,
  target_backlog_kind text,
  target_source_message_id uuid,
  observed_at timestamptz,
  target_actor_membership_id uuid,
  target_reason text
)
returns jsonb
language sql
immutable
security invoker
set search_path = ''
as $$
  select jsonb_strip_nulls(
    jsonb_build_object(
      'operation_id', target_operation_id,
      'conversation_id', target_conversation_id,
      'command_type', command_type,
      'admission_kind', target_admission_kind,
      'backlog_kind', target_backlog_kind,
      'source_message_id', target_source_message_id,
      'observed_at', observed_at,
      'actor_membership_id', target_actor_membership_id,
      'reason', target_reason
    )
  );
$$;

create or replace function private.sha256_json(target_payload jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select encode(
    sha256(convert_to(target_payload::text, 'UTF8')),
    'hex'
  );
$$;

revoke all on function private.capacity_request_payload(
  uuid, uuid, text, text, text, uuid, timestamptz, uuid, text
) from public, anon, authenticated, service_role;
revoke all on function private.sha256_json(jsonb)
  from public, anon, authenticated, service_role;

-- A stable effect key produces one persisted choice in the requested band.
drop function private.capacity_delay_seconds(text, boolean);

create function private.capacity_delay_seconds(
  target_effect_key text,
  target_delay_class text,
  high_demand boolean
)
returns integer
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  lower_bound integer;
  upper_bound integer;
  sample bigint;
begin
  if nullif(target_effect_key, '') is null then
    raise exception 'delay effect key is required' using errcode = '22023';
  end if;
  if target_delay_class not in ('short', 'normal', 'long') then
    raise exception 'invalid artificial delay class'
      using errcode = '22023';
  end if;

  if high_demand then
    lower_bound := 0;
    upper_bound := 5;
  elsif target_delay_class = 'short' then
    lower_bound := 4;
    upper_bound := 12;
  elsif target_delay_class = 'normal' then
    lower_bound := 12;
    upper_bound := 35;
  else
    lower_bound := 25;
    upper_bound := 60;
  end if;

  sample := (
    'x' || substr(
      encode(sha256(convert_to(target_effect_key, 'UTF8')), 'hex'),
      1,
      15
    )
  )::bit(60)::bigint;
  return lower_bound + (sample % (upper_bound - lower_bound + 1))::integer;
end;
$$;

revoke all on function private.capacity_delay_seconds(
  text, text, boolean
) from public, anon, authenticated, service_role;

-- Delayed inbound work itself is high demand even after slots fall below 25.
create or replace function private.capacity_refresh_operation_state(
  target_operation_id uuid,
  observed_at timestamptz,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns private.operation_capacity_state
language plpgsql
security definer
set search_path = ''
as $$
declare
  state_record private.operation_capacity_state%rowtype;
  active_count integer;
  delayed_inbound_exists boolean;
  inbound_waiting_exists boolean;
  previous_automatic_paused boolean;
  demand_triggered boolean;
  recovery_since_value timestamptz;
  high_demand_value boolean;
begin
  select state.*
  into strict state_record
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id
  for update;

  previous_automatic_paused := state_record.automatic_proactive_paused;

  select count(*)::integer
  into active_count
  from private.conversation_capacity_slots as slot
  where slot.operation_id = target_operation_id;

  select exists (
    select 1
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = target_operation_id
      and backlog.status = 'waiting'
      and backlog.backlog_kind in (
        'urgent_call',
        'sleeping_return',
        'active_reply',
        'new_inbound'
      )
      and backlog.arrived_at <= observed_at - interval '2 minutes'
  )
  into delayed_inbound_exists;

  select exists (
    select 1
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = target_operation_id
      and backlog.status = 'waiting'
      and backlog.backlog_kind in (
        'urgent_call',
        'sleeping_return',
        'active_reply',
        'new_inbound'
      )
  )
  into inbound_waiting_exists;

  demand_triggered := active_count >= 25 or delayed_inbound_exists;
  recovery_since_value := case
    when demand_triggered or inbound_waiting_exists then null
    when state_record.high_demand
      then coalesce(state_record.high_demand_recovery_since, observed_at)
    else null
  end;
  high_demand_value := demand_triggered
    or (
      state_record.high_demand
      and (
        recovery_since_value is null
        or recovery_since_value > observed_at - interval '5 minutes'
      )
    );

  update private.operation_capacity_state
  set
    automatic_proactive_paused = case
      when demand_triggered then true
      when automatic_proactive_paused
        and active_count < 10
        and below_ten_since is not null
        and below_ten_since <= observed_at - interval '5 minutes'
        and not delayed_inbound_exists
        and not high_demand_value
        then false
      else automatic_proactive_paused
    end,
    automatic_pause_reason = case
      when demand_triggered then 'high_demand'
      when automatic_proactive_paused
        and active_count < 10
        and below_ten_since is not null
        and below_ten_since <= observed_at - interval '5 minutes'
        and not delayed_inbound_exists
        and not high_demand_value
        then null
      else automatic_pause_reason
    end,
    automatic_paused_at = case
      when demand_triggered
        then coalesce(automatic_paused_at, observed_at)
      when automatic_proactive_paused
        and active_count < 10
        and below_ten_since is not null
        and below_ten_since <= observed_at - interval '5 minutes'
        and not delayed_inbound_exists
        and not high_demand_value
        then null
      else automatic_paused_at
    end,
    high_demand = high_demand_value,
    high_demand_since = case
      when high_demand_value
        then coalesce(high_demand_since, observed_at)
      else null
    end,
    high_demand_recovery_since = recovery_since_value,
    below_ten_since = case
      when active_count < 10 then coalesce(below_ten_since, observed_at)
      else null
    end,
    inbound_backlog_clear_since = case
      when inbound_waiting_exists then null
      else coalesce(inbound_backlog_clear_since, observed_at)
    end,
    updated_at = observed_at,
    version = version + 1
  where operation_id = target_operation_id
  returning * into strict state_record;

  if state_record.automatic_proactive_paused
    is distinct from previous_automatic_paused
  then
    insert into audit.audit_events (
      organization_id, operation_id, actor_user_id, action,
      target_type, target_id, before_state, after_state,
      trace_id, correlation_id
    )
    values (
      state_record.organization_id,
      target_operation_id,
      null,
      case
        when state_record.automatic_proactive_paused
          then 'operation.proactive_capacity_paused_automatically'
        else 'operation.proactive_capacity_resumed_automatically'
      end,
      'operation',
      target_operation_id,
      jsonb_build_object(
        'automatic_proactive_paused', previous_automatic_paused
      ),
      jsonb_build_object(
        'automatic_proactive_paused',
          state_record.automatic_proactive_paused,
        'manual_proactive_paused',
          state_record.manual_proactive_paused,
        'reason', state_record.automatic_pause_reason,
        'active_slots', active_count,
        'delayed_inbound_exists', delayed_inbound_exists
      ),
      request_trace_id,
      request_correlation_id
    );
  end if;

  return state_record;
end;
$$;

revoke all on function private.capacity_refresh_operation_state(
  uuid, timestamptz, uuid, uuid
) from public, anon, authenticated, service_role;

-- Preserve slice (b) as the mutation implementation and put a request/hash
-- and canonical-head fence in front of every call site.
alter function private.apply_operation_capacity_command(
  uuid, uuid, text, text, text, uuid, timestamptz, text,
  uuid, text, uuid, uuid
) rename to apply_operation_capacity_command_t07_b_base;

revoke all on function private.apply_operation_capacity_command_t07_b_base(
  uuid, uuid, text, text, text, uuid, timestamptz, text,
  uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.apply_operation_capacity_command(
  target_operation_id uuid,
  target_conversation_id uuid,
  command_type text,
  target_admission_kind text,
  target_backlog_kind text,
  target_source_message_id uuid,
  observed_at timestamptz,
  target_effect_key text,
  target_actor_membership_id uuid,
  target_reason text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  state_record private.operation_capacity_state%rowtype;
  effect_record private.operation_capacity_effects%rowtype;
  backlog_record private.operation_capacity_backlog%rowtype;
  request_payload_value jsonb;
  request_hash_value text;
  result_value jsonb;
begin
  select state.*
  into strict state_record
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id
  for update;

  if command_type in (
    'admit_inbound',
    'admit_proactive',
    'admit_backlog',
    'finalize_return',
    'opt_out',
    'sleep'
  ) then
    request_payload_value := private.capacity_request_payload(
      target_operation_id,
      target_conversation_id,
      command_type,
      target_admission_kind,
      target_backlog_kind,
      target_source_message_id,
      observed_at,
      target_actor_membership_id,
      target_reason
    );
    request_hash_value := private.sha256_json(request_payload_value);

    select effect.*
    into effect_record
    from private.operation_capacity_effects as effect
    where effect.organization_id = state_record.organization_id
      and effect.operation_id = target_operation_id
      and effect.effect_key = target_effect_key
    for update;

    if effect_record.id is not null then
      if effect_record.request_hash is distinct from request_hash_value
        or effect_record.request_payload is distinct from request_payload_value
      then
        raise exception 'capacity effect replay conflict'
          using errcode = '23505';
      end if;
      return jsonb_build_object(
        'status', 'duplicate',
        'outcome', effect_record.outcome,
        'conversation_id', effect_record.conversation_id
      );
    end if;
  end if;

  if command_type = 'admit_backlog' then
    select backlog.*
    into backlog_record
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = target_operation_id
      and backlog.status = 'waiting'
      and backlog.eligible_at <= observed_at
    order by
      backlog.priority_class,
      backlog.fifo_sequence,
      backlog.id
    limit 1
    for update;

    if backlog_record.id is null
      or backlog_record.conversation_id is distinct from target_conversation_id
      or backlog_record.backlog_kind is distinct from target_backlog_kind
      or (
        target_source_message_id is not null
        and backlog_record.source_message_id
          is distinct from target_source_message_id
      )
    then
      raise exception 'backlog admission is not the eligible canonical head'
        using errcode = '55000';
    end if;
  end if;

  result_value :=
    private.apply_operation_capacity_command_t07_b_base(
      target_operation_id,
      target_conversation_id,
      command_type,
      target_admission_kind,
      target_backlog_kind,
      target_source_message_id,
      observed_at,
      target_effect_key,
      target_actor_membership_id,
      target_reason,
      request_trace_id,
      request_correlation_id
    );

  if request_hash_value is not null then
    update private.operation_capacity_effects
    set
      request_payload = request_payload_value,
      request_hash = request_hash_value,
      backlog_id = backlog_record.id
    where organization_id = state_record.organization_id
      and operation_id = target_operation_id
      and effect_key = target_effect_key
    returning * into strict effect_record;
  end if;

  if command_type = 'admit_backlog'
    and result_value ->> 'outcome' = 'admitted'
  then
    update private.operation_capacity_backlog
    set
      status = 'admitted',
      admitted_at = observed_at,
      cancelled_at = null,
      admitted_effect_id = effect_record.id,
      updated_at = observed_at
    where id = backlog_record.id;
  end if;

  return result_value;
end;
$$;

revoke all on function private.apply_operation_capacity_command(
  uuid, uuid, text, text, text, uuid, timestamptz, text,
  uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

update private.operation_capacity_effects
set
  request_payload = jsonb_build_object(
    'legacy_effect_id', id,
    'operation_id', operation_id,
    'conversation_id', conversation_id,
    'command_type', command_type,
    'legacy_payload_unavailable', true
  ),
  request_hash = private.sha256_json(
    jsonb_build_object(
      'legacy_effect_id', id,
      'operation_id', operation_id,
      'conversation_id', conversation_id,
      'command_type', command_type,
      'legacy_payload_unavailable', true
    )
  )
where request_payload is null or request_hash is null;

alter table private.operation_capacity_effects
  alter column request_payload set default '{}'::jsonb,
  alter column request_payload set not null,
  alter column request_hash set default
    '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
  alter column request_hash set not null;

-- A response batch remains unique until it is consumed.  "ready" is not a
-- loophole for opening a second batch and every chosen delay is persisted.
alter table private.pedro_response_batches
  drop constraint pedro_response_batches_status_check,
  drop constraint pedro_response_batches_check3,
  add column delay_due_at timestamptz,
  add column processing_at timestamptz,
  add column completed_at timestamptz,
  add column consumed_at timestamptz,
  add column processing_worker_id uuid,
  add column processing_lease_token uuid,
  add column processing_lease_until timestamptz,
  add column processing_input_version bigint
    check (
      processing_input_version is null
      or processing_input_version > 0
    ),
  add column processing_input_hash text
    check (
      processing_input_hash is null
      or processing_input_hash ~ '^[0-9a-f]{64}$'
    ),
  add column processing_claim_count integer not null default 0
    check (processing_claim_count >= 0),
  add column superseded_by_batch_id uuid,
  add column response_effect_key text
    check (
      response_effect_key is null
      or char_length(response_effect_key) between 1 and 500
    ),
  add constraint pedro_response_batches_status_check
    check (
      status in (
        'collecting',
        'delaying',
        'ready',
        'processing',
        'completed',
        'consumed',
        'cancelled'
      )
    ),
  add constraint pedro_response_batches_due_order_check
    check (
      grouping_due_at >= last_inbound_at
      and grouping_due_at <= grouping_deadline_at
      and (
        delay_due_at is null
        or delay_due_at >= grouping_due_at
      )
    ),
  add constraint pedro_response_batches_lifecycle_check
    check (
      (
        status = 'collecting'
        and delay_seconds is null
        and delay_due_at is null
        and ready_at is null
        and processing_at is null
        and completed_at is null
        and consumed_at is null
        and cancelled_at is null
      )
      or (
        status = 'delaying'
        and delay_seconds is not null
        and delay_due_at is not null
        and ready_at is null
        and processing_at is null
        and completed_at is null
        and consumed_at is null
        and cancelled_at is null
      )
      or (
        status = 'ready'
        and delay_seconds is not null
        and delay_due_at is not null
        and ready_at is not null
        and processing_at is null
        and completed_at is null
        and consumed_at is null
        and cancelled_at is null
      )
      or (
        status = 'processing'
        and ready_at is not null
        and processing_at is not null
        and processing_worker_id is not null
        and processing_lease_token is not null
        and processing_lease_until is not null
        and processing_input_version is not null
        and processing_input_hash is not null
        and processing_claim_count > 0
        and completed_at is null
        and consumed_at is null
        and cancelled_at is null
      )
      or (
        status = 'completed'
        and ready_at is not null
        and processing_at is not null
        and processing_worker_id is not null
        and processing_lease_token is not null
        and processing_lease_until is not null
        and processing_input_version is not null
        and processing_input_hash is not null
        and processing_claim_count > 0
        and completed_at is not null
        and consumed_at is null
        and cancelled_at is null
      )
      or (
        status = 'consumed'
        and ready_at is not null
        and processing_at is not null
        and processing_worker_id is not null
        and processing_lease_token is not null
        and processing_lease_until is not null
        and processing_input_version is not null
        and processing_input_hash is not null
        and processing_claim_count > 0
        and completed_at is not null
        and consumed_at is not null
        and cancelled_at is null
      )
      or (
        status = 'cancelled'
        and consumed_at is null
        and cancelled_at is not null
      )
    ),
  add constraint pedro_response_batches_superseded_fkey
    foreign key (superseded_by_batch_id)
    references private.pedro_response_batches(id)
    on delete set null;

drop index private.pedro_response_batches_one_open_conversation;

create unique index pedro_response_batches_one_open_conversation
  on private.pedro_response_batches (conversation_id)
  where status in (
    'collecting',
    'delaying',
    'ready',
    'processing',
    'completed'
  );

create index pedro_response_batches_delay_due_idx
  on private.pedro_response_batches (
    operation_id,
    delay_due_at,
    id
  )
  where status = 'delaying';

create index pedro_response_batches_worker_claim_idx
  on private.pedro_response_batches (
    operation_id,
    status,
    processing_lease_until,
    ready_at,
    id
  )
  where status in ('ready', 'processing', 'completed');

alter table public.messages
  add column provider_revision_occurred_at timestamptz,
  add column provider_revision_event_id text
    check (
      provider_revision_event_id is null
      or char_length(provider_revision_event_id) between 1 and 500
    ),
  add column provider_revision_kind text
    check (
      provider_revision_kind is null
      or provider_revision_kind in ('edit', 'delete')
    ),
  add constraint messages_provider_revision_watermark_check
    check (
      (
        provider_revision_occurred_at is null
        and provider_revision_event_id is null
        and provider_revision_kind is null
      )
      or (
        provider_revision_occurred_at is not null
        and provider_revision_event_id is not null
        and provider_revision_kind is not null
      )
    );

alter table private.provider_message_revisions
  add column is_applied boolean not null default true,
  add column stale_reason text
    check (
      stale_reason is null
      or stale_reason in (
        'older_provider_time',
        'deleted_message_is_terminal'
      )
    ),
  add constraint provider_message_revisions_application_check
    check (
      (is_applied and stale_reason is null)
      or (not is_applied and stale_reason is not null)
    );

create or replace function private.schedule_t07_job(
  target_organization_id uuid,
  target_operation_id uuid,
  target_job_type text,
  target_aggregate_type text,
  target_aggregate_id uuid,
  target_run_at timestamptz,
  target_dedupe_key text,
  target_payload jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_id_value uuid;
begin
  insert into public.scheduled_jobs (
    organization_id,
    operation_id,
    job_type,
    aggregate_type,
    aggregate_id,
    target_queue,
    run_at,
    dedupe_key,
    payload,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    target_job_type,
    target_aggregate_type,
    target_aggregate_id,
    'scheduled_actions',
    target_run_at,
    target_dedupe_key,
    target_payload,
    request_trace_id,
    request_correlation_id
  )
  on conflict (
    organization_id,
    operation_id,
    dedupe_key
  ) where status in ('pending', 'leased', 'published')
  do update
  set
    run_at = least(public.scheduled_jobs.run_at, excluded.run_at),
    payload = excluded.payload,
    updated_at = now()
  returning id into strict job_id_value;

  return job_id_value;
end;
$$;

revoke all on function private.schedule_t07_job(
  uuid, uuid, text, text, uuid, timestamptz, text, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.response_delay_class_for_message(
  target_message_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when message.kind in ('image', 'document', 'audio', 'video') then 'long'
    when char_length(coalesce(message.body, '')) <= 80 then 'short'
    when char_length(coalesce(message.body, '')) <= 500 then 'normal'
    else 'long'
  end
  from public.messages as message
  where message.id = target_message_id;
$$;

create or replace function private.max_response_delay_class(
  first_class text,
  second_class text
)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  if first_class not in ('short', 'normal', 'long')
    or second_class not in ('short', 'normal', 'long')
  then
    raise exception 'invalid response delay class' using errcode = '22023';
  end if;
  if first_class = 'long' or second_class = 'long' then
    return 'long';
  elsif first_class = 'normal' or second_class = 'normal' then
    return 'normal';
  end if;
  return 'short';
end;
$$;

revoke all on function private.response_delay_class_for_message(uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.max_response_delay_class(text, text)
  from public, anon, authenticated, service_role;

create or replace function private.rollover_response_batch(
  target_batch_id uuid,
  target_message_id uuid,
  observed_at timestamptz,
  target_delay_class text,
  target_include_message boolean,
  target_reason text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_batch private.pedro_response_batches%rowtype;
  new_batch private.pedro_response_batches%rowtype;
  anchor_at timestamptz;
  has_included_messages boolean;
begin
  if target_delay_class not in ('short', 'normal', 'long')
    or nullif(btrim(coalesce(target_reason, '')), '') is null
  then
    raise exception 'invalid response batch rollover'
      using errcode = '22023';
  end if;

  select batch.*
  into strict old_batch
  from private.pedro_response_batches as batch
  where batch.id = target_batch_id
  for update;

  if old_batch.status in ('consumed', 'cancelled') then
    return null;
  end if;

  select exists (
    select 1
    from private.pedro_response_batch_messages as batch_message
    join public.messages as message
      on message.id = batch_message.message_id
    where batch_message.batch_id = old_batch.id
      and batch_message.included
      and message.deleted_at is null
  ) or target_include_message
  into has_included_messages;

  update private.pedro_response_batches
  set
    status = 'cancelled',
    cancelled_at = now(),
    trace_id = request_trace_id,
    correlation_id = request_correlation_id,
    updated_at = now(),
    version = version + 1
  where id = old_batch.id;

  if not has_included_messages then
    return null;
  end if;

  anchor_at := greatest(observed_at, old_batch.last_inbound_at, now());
  insert into private.pedro_response_batches (
    organization_id,
    operation_id,
    conversation_id,
    status,
    opened_at,
    last_inbound_at,
    grouping_due_at,
    grouping_deadline_at,
    delay_class,
    trace_id,
    correlation_id
  )
  values (
    old_batch.organization_id,
    old_batch.operation_id,
    old_batch.conversation_id,
    'collecting',
    anchor_at,
    anchor_at,
    anchor_at + interval '10 seconds',
    anchor_at + interval '30 seconds',
    private.max_response_delay_class(
      old_batch.delay_class,
      target_delay_class
    ),
    request_trace_id,
    request_correlation_id
  )
  returning * into strict new_batch;

  insert into private.pedro_response_batch_messages (
    batch_id,
    message_id,
    organization_id,
    operation_id,
    conversation_id,
    observed_at,
    revision,
    included
  )
  select
    new_batch.id,
    message.id,
    new_batch.organization_id,
    new_batch.operation_id,
    new_batch.conversation_id,
    batch_message.observed_at,
    message.revision,
    true
  from private.pedro_response_batch_messages as batch_message
  join public.messages as message
    on message.id = batch_message.message_id
  where batch_message.batch_id = old_batch.id
    and batch_message.included
    and message.deleted_at is null;

  if target_include_message then
    insert into private.pedro_response_batch_messages (
      batch_id,
      message_id,
      organization_id,
      operation_id,
      conversation_id,
      observed_at,
      revision,
      included
    )
    select
      new_batch.id,
      message.id,
      message.organization_id,
      message.operation_id,
      message.conversation_id,
      observed_at,
      message.revision,
      message.deleted_at is null
    from public.messages as message
    where message.id = target_message_id
    on conflict (batch_id, message_id)
    do update
    set
      observed_at = greatest(
        private.pedro_response_batch_messages.observed_at,
        excluded.observed_at
      ),
      revision = excluded.revision,
      included = excluded.included;
  end if;

  update private.pedro_response_batches
  set superseded_by_batch_id = new_batch.id
  where id = old_batch.id;

  perform private.schedule_t07_job(
    new_batch.organization_id,
    new_batch.operation_id,
    't07.close_response_batch',
    'pedro_response_batch',
    new_batch.id,
    new_batch.grouping_due_at,
    't07:batch:close:' || new_batch.id::text
      || ':v' || new_batch.version::text,
    jsonb_build_object(
      'batch_id', new_batch.id,
      'rollover_reason', left(btrim(target_reason), 120)
    ),
    request_trace_id,
    request_correlation_id
  );

  return new_batch.id;
end;
$$;

revoke all on function private.rollover_response_batch(
  uuid, uuid, timestamptz, text, boolean, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.record_inbound_response_batch(
  target_message_id uuid,
  observed_at timestamptz,
  target_delay_class text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  message_record public.messages%rowtype;
  batch_record private.pedro_response_batches%rowtype;
  next_due timestamptz;
  successor_batch_id uuid;
begin
  if target_delay_class not in ('short', 'normal', 'long') then
    raise exception 'invalid response delay class' using errcode = '22023';
  end if;

  select message.*
  into strict message_record
  from public.messages as message
  where message.id = target_message_id
  for update;

  if message_record.direction <> 'inbound'
    or message_record.created_by_type <> 'provider'
  then
    raise exception 'only provider inbound can enter Pedro batch'
      using errcode = '23514';
  end if;

  select batch.*
  into batch_record
  from private.pedro_response_batches as batch
  where batch.conversation_id = message_record.conversation_id
    and batch.status in (
      'collecting',
      'delaying',
      'ready',
      'processing',
      'completed'
    )
  for update;

  if batch_record.id is null then
    insert into private.pedro_response_batches (
      organization_id,
      operation_id,
      conversation_id,
      status,
      opened_at,
      last_inbound_at,
      grouping_due_at,
      grouping_deadline_at,
      delay_class,
      trace_id,
      correlation_id
    )
    values (
      message_record.organization_id,
      message_record.operation_id,
      message_record.conversation_id,
      'collecting',
      observed_at,
      observed_at,
      observed_at + interval '10 seconds',
      observed_at + interval '30 seconds',
      target_delay_class,
      request_trace_id,
      request_correlation_id
    )
    returning * into strict batch_record;
  elsif batch_record.status <> 'collecting'
    or batch_record.grouping_deadline_at < now()
    or observed_at > batch_record.grouping_deadline_at
  then
    successor_batch_id := private.rollover_response_batch(
      batch_record.id,
      message_record.id,
      observed_at,
      target_delay_class,
      true,
      'new inbound superseded pending response',
      request_trace_id,
      request_correlation_id
    );
    return successor_batch_id;
  else
    next_due := least(
      observed_at + interval '10 seconds',
      batch_record.grouping_deadline_at
    );
    update private.pedro_response_batches
    set
      last_inbound_at = greatest(last_inbound_at, observed_at),
      grouping_due_at = least(
        grouping_deadline_at,
        greatest(grouping_due_at, last_inbound_at, next_due)
      ),
      delay_class = private.max_response_delay_class(
        delay_class,
        target_delay_class
      ),
      trace_id = request_trace_id,
      correlation_id = request_correlation_id,
      updated_at = observed_at,
      version = version + 1
    where id = batch_record.id
    returning * into strict batch_record;
  end if;

  insert into private.pedro_response_batch_messages (
    batch_id,
    message_id,
    organization_id,
    operation_id,
    conversation_id,
    observed_at,
    revision,
    included
  )
  values (
    batch_record.id,
    message_record.id,
    message_record.organization_id,
    message_record.operation_id,
    message_record.conversation_id,
    observed_at,
    message_record.revision,
    message_record.deleted_at is null
  )
  on conflict (batch_id, message_id)
  do update
  set
    observed_at = excluded.observed_at,
    revision = excluded.revision,
    included = excluded.included;

  perform private.schedule_t07_job(
    batch_record.organization_id,
    batch_record.operation_id,
    't07.close_response_batch',
    'pedro_response_batch',
    batch_record.id,
    batch_record.grouping_due_at,
    't07:batch:close:' || batch_record.id::text
      || ':v' || batch_record.version::text,
    jsonb_build_object('batch_id', batch_record.id),
    request_trace_id,
    request_correlation_id
  );

  return batch_record.id;
end;
$$;

revoke all on function private.record_inbound_response_batch(
  uuid, timestamptz, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.collect_provider_inbound_for_pedro()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.direction = 'inbound'
    and new.created_by_type = 'provider'
  then
    perform private.record_inbound_response_batch(
      new.id,
      coalesce(new.provider_occurred_at, new.created_at),
      private.response_delay_class_for_message(new.id),
      gen_random_uuid(),
      gen_random_uuid()
    );
  end if;
  return new;
end;
$$;

revoke all on function private.collect_provider_inbound_for_pedro()
  from public, anon, authenticated, service_role;

create trigger messages_collect_provider_inbound_for_pedro
after insert on public.messages
for each row execute function private.collect_provider_inbound_for_pedro();

create or replace function private.guard_provider_message_original()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.direction = 'inbound'
    and old.created_by_type = 'provider'
    and (
      new.body is distinct from old.body
      or new.revision is distinct from old.revision
      or new.edited_at is distinct from old.edited_at
      or new.deleted_at is distinct from old.deleted_at
    )
    and current_setting(
      'grillstudio.provider_revision_write',
      true
    ) is distinct from 'on'
  then
    raise exception 'provider message original is immutable'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_provider_message_original()
  from public, anon, authenticated, service_role;

create trigger messages_guard_provider_original
before update of body, revision, edited_at, deleted_at
on public.messages
for each row execute function private.guard_provider_message_original();

create or replace function private.apply_provider_message_revision(
  target_organization_id uuid,
  target_operation_id uuid,
  target_connection_id uuid,
  target_provider_event_id text,
  target_provider_message_id text,
  target_revision_kind text,
  target_revised_body text,
  target_provider_occurred_at timestamptz,
  target_payload_hash text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  message_record public.messages%rowtype;
  existing_revision private.provider_message_revisions%rowtype;
  batch_record private.pedro_response_batches%rowtype;
  next_revision integer;
  apply_revision boolean := true;
  stale_reason_value text;
  successor_batch_id uuid;
begin
  if target_revision_kind not in ('edit', 'delete')
    or target_provider_occurred_at is null
    or target_payload_hash !~ '^[0-9a-f]{64}$'
    or (
      target_revision_kind = 'edit'
      and target_revised_body is null
    )
    or (
      target_revision_kind = 'delete'
      and target_revised_body is not null
    )
  then
    raise exception 'invalid provider revision payload'
      using errcode = '22023';
  end if;

  -- The target Message is the serialization fence for provider revisions.
  -- Concurrent delivery of the same provider event therefore rechecks dedupe
  -- after the first transaction commits instead of leaking a unique error.
  select message.*
  into strict message_record
  from public.messages as message
  where message.organization_id = target_organization_id
    and message.operation_id = target_operation_id
    and message.connection_id = target_connection_id
    and message.provider_message_id = target_provider_message_id
  for update;

  if message_record.direction <> 'inbound'
    or message_record.created_by_type <> 'provider'
  then
    raise exception 'only provider inbound can be revised'
      using errcode = '23514';
  end if;

  select revision.*
  into existing_revision
  from private.provider_message_revisions as revision
  where revision.connection_id = target_connection_id
    and revision.provider_event_id = target_provider_event_id;

  if existing_revision.id is not null then
    if existing_revision.payload_hash <> target_payload_hash
      or existing_revision.revision_kind <> target_revision_kind
      or existing_revision.target_provider_message_id
        <> target_provider_message_id
      or existing_revision.revised_body
        is distinct from target_revised_body
      or existing_revision.provider_occurred_at
        <> target_provider_occurred_at
    then
      raise exception 'provider revision replay conflict'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status', 'duplicate',
      'message_id', existing_revision.target_message_id,
      'revision', existing_revision.revision_number,
      'applied', existing_revision.is_applied
    );
  end if;

  next_revision := message_record.revision + 1;
  if target_provider_occurred_at
    < message_record.provider_revision_occurred_at
  then
    apply_revision := false;
    stale_reason_value := 'older_provider_time';
  elsif target_revision_kind = 'edit'
    and (
      message_record.deleted_at is not null
      or message_record.provider_revision_kind = 'delete'
    )
  then
    apply_revision := false;
    stale_reason_value := 'deleted_message_is_terminal';
  end if;

  insert into private.provider_message_revisions (
    organization_id,
    operation_id,
    connection_id,
    provider_event_id,
    target_message_id,
    target_provider_message_id,
    revision_kind,
    revision_number,
    revised_body,
    payload_hash,
    provider_occurred_at,
    is_applied,
    stale_reason,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    target_connection_id,
    target_provider_event_id,
    message_record.id,
    target_provider_message_id,
    target_revision_kind,
    next_revision,
    target_revised_body,
    target_payload_hash,
    target_provider_occurred_at,
    apply_revision,
    stale_reason_value,
    request_trace_id,
    request_correlation_id
  );

  perform set_config(
    'grillstudio.provider_revision_write',
    'on',
    true
  );

  update public.messages
  set
    revision = next_revision,
    edited_at = case
      when apply_revision and target_revision_kind = 'edit'
        then target_provider_occurred_at
      else edited_at
    end,
    deleted_at = case
      when apply_revision and target_revision_kind = 'delete'
        then target_provider_occurred_at
      else deleted_at
    end,
    provider_revision_occurred_at = case
      when apply_revision then target_provider_occurred_at
      else provider_revision_occurred_at
    end,
    provider_revision_event_id = case
      when apply_revision then target_provider_event_id
      else provider_revision_event_id
    end,
    provider_revision_kind = case
      when apply_revision then target_revision_kind
      else provider_revision_kind
    end
  where id = message_record.id;

  perform set_config(
    'grillstudio.provider_revision_write',
    'off',
    true
  );

  update private.pedro_response_batch_messages
  set
    revision = case when apply_revision then next_revision else revision end,
    observed_at = case
      when apply_revision and target_revision_kind = 'edit' then now()
      else observed_at
    end,
    included = case
      when not apply_revision then included
      when target_revision_kind = 'delete' then false
      else true
    end
  where message_id = message_record.id;

  if apply_revision then
    select batch.*
    into batch_record
    from private.pedro_response_batches as batch
    join private.pedro_response_batch_messages as batch_message
      on batch_message.batch_id = batch.id
    where batch_message.message_id = message_record.id
      and batch.status in (
        'collecting',
        'delaying',
        'ready',
        'processing',
        'completed'
      )
    for update of batch;

    if batch_record.id is not null
      and target_revision_kind = 'edit'
      and batch_record.status = 'collecting'
      and batch_record.grouping_deadline_at >= now()
    then
      update private.pedro_response_batches
      set
        last_inbound_at = greatest(last_inbound_at, now()),
        grouping_due_at = least(
          grouping_deadline_at,
          greatest(grouping_due_at, now() + interval '10 seconds')
        ),
        trace_id = request_trace_id,
        correlation_id = request_correlation_id,
        updated_at = now(),
        version = version + 1
      where id = batch_record.id
      returning * into strict batch_record;

      perform private.schedule_t07_job(
        batch_record.organization_id,
        batch_record.operation_id,
        't07.close_response_batch',
        'pedro_response_batch',
        batch_record.id,
        batch_record.grouping_due_at,
        't07:batch:close:' || batch_record.id::text
          || ':v' || batch_record.version::text,
        jsonb_build_object(
          'batch_id', batch_record.id,
          'reset_by_revision', next_revision
        ),
        request_trace_id,
        request_correlation_id
      );
    elsif batch_record.id is not null
      and (
        target_revision_kind = 'edit'
        or batch_record.status <> 'collecting'
      )
    then
      successor_batch_id := private.rollover_response_batch(
        batch_record.id,
        message_record.id,
        now(),
        private.response_delay_class_for_message(message_record.id),
        target_revision_kind = 'edit',
        'provider revision superseded pending response',
        request_trace_id,
        request_correlation_id
      );
    elsif batch_record.id is not null
      and target_revision_kind = 'delete'
      and not exists (
        select 1
        from private.pedro_response_batch_messages as batch_message
        where batch_message.batch_id = batch_record.id
          and batch_message.included
      )
    then
      perform private.cancel_response_batch(
        batch_record.operation_id,
        batch_record.id,
        'all inbound messages were deleted before processing',
        request_trace_id,
        request_correlation_id
      );
    end if;
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
    target_organization_id,
    target_operation_id,
    null,
    case
      when not apply_revision then 'message.provider_revision_ignored'
      when target_revision_kind = 'edit'
        then 'message.provider_edited'
      else 'message.provider_deleted'
    end,
    'message',
    message_record.id,
    jsonb_build_object('revision', message_record.revision),
    jsonb_build_object(
      'revision', next_revision,
      'applied', apply_revision,
      'stale_reason', stale_reason_value,
      'provider_event_id_hash', encode(
        sha256(convert_to(target_provider_event_id, 'UTF8')),
        'hex'
      )
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'status', case when apply_revision then 'applied' else 'stale' end,
    'message_id', message_record.id,
    'revision', next_revision,
    'deleted', apply_revision and target_revision_kind = 'delete',
    'successor_batch_id', successor_batch_id,
    'stale_reason', stale_reason_value
  );
end;
$$;

revoke all on function private.apply_provider_message_revision(
  uuid, uuid, uuid, text, text, text, text, timestamptz,
  text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.message_active_body(
  target_message_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when message.deleted_at is not null then null
    else coalesce(
      (
        select revision.revised_body
        from private.provider_message_revisions as revision
        where revision.target_message_id = message.id
          and revision.revision_kind = 'edit'
          and revision.is_applied
        order by
          revision.provider_occurred_at desc,
          revision.revision_number desc
        limit 1
      ),
      message.body
    )
  end
  from public.messages as message
  where message.id = target_message_id;
$$;

revoke all on function private.message_active_body(uuid)
  from public, anon, authenticated, service_role;

alter function private.get_conversation_detail(uuid)
  rename to get_conversation_detail_t07_original;

revoke all on function private.get_conversation_detail_t07_original(uuid)
  from public, anon, authenticated, service_role;

create function private.get_conversation_detail(
  target_conversation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result_value jsonb;
  active_messages jsonb;
begin
  result_value :=
    private.get_conversation_detail_t07_original(target_conversation_id);

  select coalesce(
    jsonb_agg(
      item
      || jsonb_build_object(
        'body',
          private.message_active_body((item ->> 'id')::uuid),
        'revision', message.revision,
        'edited_at', message.edited_at,
        'deleted_at', message.deleted_at
      )
      order by ordinal
    ),
    '[]'::jsonb
  )
  into active_messages
  from jsonb_array_elements(result_value -> 'messages')
    with ordinality as element(item, ordinal)
  join public.messages as message
    on message.id = (item ->> 'id')::uuid;

  return jsonb_set(
    result_value,
    '{messages}',
    active_messages,
    true
  );
end;
$$;

revoke all on function private.get_conversation_detail(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.get_conversation_detail(
  target_conversation_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.get_conversation_detail(target_conversation_id);
$$;

revoke all on function public.get_conversation_detail(uuid)
  from public, anon, service_role;
grant execute on function public.get_conversation_detail(uuid)
  to authenticated;

create or replace function private.enqueue_capacity_command(
  target_organization_id uuid,
  target_operation_id uuid,
  target_scheduled_job_id uuid,
  target_conversation_id uuid,
  target_backlog_id uuid,
  target_command_type text,
  target_payload jsonb,
  target_effect_key text,
  target_run_at timestamptz,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  snapshot_record private.operation_capacity_commands%rowtype;
  command_record private.operation_capacity_commands%rowtype;
  request_hash_value text;
begin
  request_hash_value := private.sha256_json(
    jsonb_build_object(
      'organization_id', target_organization_id,
      'operation_id', target_operation_id,
      'scheduled_job_id', target_scheduled_job_id,
      'conversation_id', target_conversation_id,
      'backlog_id', target_backlog_id,
      'command_type', target_command_type,
      'payload', target_payload
    )
  );

  insert into private.operation_capacity_commands (
    organization_id,
    operation_id,
    scheduled_job_id,
    conversation_id,
    backlog_id,
    command_type,
    payload,
    request_hash,
    effect_key,
    run_at,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    target_scheduled_job_id,
    target_conversation_id,
    target_backlog_id,
    target_command_type,
    target_payload,
    request_hash_value,
    target_effect_key,
    target_run_at,
    request_trace_id,
    request_correlation_id
  )
  on conflict (organization_id, operation_id, effect_key)
  do update
  set
    status = case
      when private.operation_capacity_commands.status = 'failed'
        then 'pending'
      else private.operation_capacity_commands.status
    end,
    run_at = case
      when private.operation_capacity_commands.status = 'failed'
        then excluded.run_at
      when private.operation_capacity_commands.status = 'pending'
        then least(
          private.operation_capacity_commands.run_at,
          excluded.run_at
        )
      else private.operation_capacity_commands.run_at
    end,
    attempts = case
      when private.operation_capacity_commands.status = 'failed' then 0
      else private.operation_capacity_commands.attempts
    end,
    last_error_code = case
      when private.operation_capacity_commands.status = 'failed' then null
      else private.operation_capacity_commands.last_error_code
    end,
    updated_at = case
      when private.operation_capacity_commands.status = 'failed' then now()
      else private.operation_capacity_commands.updated_at
    end;

  select command.*
  into strict command_record
  from private.operation_capacity_commands as command
  where command.organization_id = target_organization_id
    and command.operation_id = target_operation_id
    and command.effect_key = target_effect_key;

  if command_record.request_hash <> request_hash_value
    or command_record.command_type <> target_command_type
    or command_record.payload <> target_payload
  then
    raise exception 'capacity command replay conflict'
      using errcode = '23505';
  end if;

  return command_record.id;
end;
$$;

revoke all on function private.enqueue_capacity_command(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, text,
  timestamptz, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.emit_capacity_command_from_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_record public.scheduled_jobs%rowtype;
  command_type_value text;
  conversation_id_value uuid;
  backlog_id_value uuid;
  next_run_at timestamptz;
begin
  select job.*
  into strict job_record
  from public.scheduled_jobs as job
  where job.id = new.scheduled_job_id;

  command_type_value := case job_record.job_type
    when 't07.capacity_maintenance' then 'maintenance'
    when 't07.close_response_batch' then 'close_response_batch'
    when 't07.ready_response_batch' then 'ready_response_batch'
    when 't07.sleep_conversation' then 'sleep'
    when 't07.drain_backlog' then 'drain_backlog'
    when 't07.resume_pending_return' then 'resume_pending_return'
    else null
  end;

  if command_type_value is null then
    return new;
  end if;

  begin
    conversation_id_value :=
      nullif(job_record.payload ->> 'conversation_id', '')::uuid;
    backlog_id_value :=
      nullif(job_record.payload ->> 'backlog_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'invalid T07 scheduled job payload'
      using errcode = '22023';
  end;

  perform private.enqueue_capacity_command(
    job_record.organization_id,
    job_record.operation_id,
    job_record.id,
    conversation_id_value,
    backlog_id_value,
    command_type_value,
    job_record.payload
      || jsonb_build_object(
        'scheduled_effect_key', job_record.effect_key,
        'scheduled_run_at', job_record.run_at
      ),
    't07:capacity-command:' || job_record.effect_key,
    now(),
    job_record.trace_id,
    job_record.correlation_id
  );

  if job_record.job_type = 't07.capacity_maintenance' then
    next_run_at := greatest(now(), job_record.run_at) + interval '5 seconds';
    perform private.schedule_t07_job(
      job_record.organization_id,
      job_record.operation_id,
      't07.capacity_maintenance',
      'operation_capacity',
      job_record.operation_id,
      next_run_at,
      't07:capacity-maintenance:' || job_record.operation_id::text
        || ':after:' || job_record.id::text,
      jsonb_build_object('operation_id', job_record.operation_id),
      gen_random_uuid(),
      job_record.correlation_id
    );
  end if;

  return new;
end;
$$;

revoke all on function private.emit_capacity_command_from_job()
  from public, anon, authenticated, service_role;

create trigger scheduled_job_executions_emit_capacity_command
after insert on private.scheduled_job_executions
for each row execute function private.emit_capacity_command_from_job();

create or replace function private.seed_operation_capacity_maintenance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.schedule_t07_job(
    new.organization_id,
    new.id,
    't07.capacity_maintenance',
    'operation_capacity',
    new.id,
    now(),
    't07:capacity-maintenance:' || new.id::text || ':initial',
    jsonb_build_object('operation_id', new.id),
    gen_random_uuid(),
    gen_random_uuid()
  );
  return new;
end;
$$;

revoke all on function private.seed_operation_capacity_maintenance()
  from public, anon, authenticated, service_role;

create trigger operations_seed_capacity_maintenance
after insert on public.operations
for each row execute function private.seed_operation_capacity_maintenance();

select private.schedule_t07_job(
  operation.organization_id,
  operation.id,
  't07.capacity_maintenance',
  'operation_capacity',
  operation.id,
  now(),
  't07:capacity-maintenance:' || operation.id::text || ':initial',
  jsonb_build_object('operation_id', operation.id),
  gen_random_uuid(),
  gen_random_uuid()
)
from public.operations as operation;

create or replace function private.process_capacity_command(
  target_command_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  command_record private.operation_capacity_commands%rowtype;
  state_record private.operation_capacity_state%rowtype;
  backlog_record private.operation_capacity_backlog%rowtype;
  canonical_backlog_id uuid;
  conversation_record public.conversations%rowtype;
  batch_record private.pedro_response_batches%rowtype;
  active_count integer;
  admission_kind_value text;
  delay_seconds_value integer;
  slot_last_activity_at timestamptz;
  next_run_at timestamptz;
  result_value jsonb;
begin
  -- Read only the routing key, then preserve the domain lock order. The
  -- consumer claims the OperationCapacity row with SKIP LOCKED before entry.
  select command.*
  into snapshot_record
  from private.operation_capacity_commands as command
  where command.id = target_command_id;

  if snapshot_record.id is null then
    return jsonb_build_object('status', 'missing');
  end if;

  select state.*
  into strict state_record
  from private.operation_capacity_state as state
  where state.operation_id = snapshot_record.operation_id
  for update;

  select command.*
  into strict command_record
  from private.operation_capacity_commands as command
  where command.id = target_command_id
  for update;

  if command_record.status <> 'pending'
    or command_record.run_at > now()
  then
    return jsonb_build_object(
      'status', command_record.status,
      'run_at', command_record.run_at
    );
  end if;

  if command_record.request_hash <> private.sha256_json(
    jsonb_build_object(
      'organization_id', command_record.organization_id,
      'operation_id', command_record.operation_id,
      'scheduled_job_id', command_record.scheduled_job_id,
      'conversation_id', command_record.conversation_id,
      'backlog_id', command_record.backlog_id,
      'command_type', command_record.command_type,
      'payload', command_record.payload
    )
  ) then
    raise exception 'capacity command payload hash mismatch'
      using errcode = '23514';
  end if;

  update private.operation_capacity_commands
  set
    status = 'processing',
    attempts = attempts + 1,
    updated_at = now()
  where id = command_record.id;

  if command_record.command_type = 'maintenance' then
    state_record := private.capacity_refresh_operation_state(
      command_record.operation_id,
      now(),
      command_record.trace_id,
      command_record.correlation_id
    );

    select backlog.id
    into canonical_backlog_id
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = command_record.operation_id
      and backlog.status = 'waiting'
      and backlog.eligible_at <= now()
    order by backlog.priority_class, backlog.fifo_sequence, backlog.id
    limit 1;

    if canonical_backlog_id is not null then
      select backlog.*
      into strict backlog_record
      from private.operation_capacity_backlog as backlog
      where backlog.id = canonical_backlog_id;

      perform private.enqueue_capacity_command(
        backlog_record.organization_id,
        backlog_record.operation_id,
        null,
        backlog_record.conversation_id,
        backlog_record.id,
        'drain_backlog',
        jsonb_build_object(
          'backlog_id', backlog_record.id,
          'conversation_id', backlog_record.conversation_id,
          'backlog_kind', backlog_record.backlog_kind,
          'source_message_id', backlog_record.source_message_id,
          'observed_at', backlog_record.arrived_at
        ),
        't07:drain-backlog:' || backlog_record.id::text,
        now(),
        command_record.trace_id,
        command_record.correlation_id
      );
    end if;

    for conversation_record in
      select conversation.*
      from public.conversations as conversation
      where conversation.operation_id = command_record.operation_id
        and conversation.pending_return
      order by
        conversation.pending_return_requested_at,
        conversation.id
      limit 25
    loop
      perform private.enqueue_capacity_command(
        conversation_record.organization_id,
        conversation_record.operation_id,
        null,
        conversation_record.id,
        null,
        'resume_pending_return',
        jsonb_build_object(
          'conversation_id', conversation_record.id,
          'requested_version',
            conversation_record.pending_return_requested_version,
          'target_mode', conversation_record.pending_return_target_mode,
          'observed_at',
            conversation_record.pending_return_requested_at
        ),
        't07:resume-pending-return:'
          || conversation_record.id::text
          || ':v'
          || conversation_record.pending_return_requested_version::text,
        now(),
        command_record.trace_id,
        command_record.correlation_id
      );
    end loop;

    for conversation_record in
      select conversation.*
      from public.conversations as conversation
      join private.conversation_capacity_slots as slot
        on slot.conversation_id = conversation.id
      where conversation.operation_id = command_record.operation_id
        and conversation.status = 'active'
        and conversation.ownership_type = 'pedro'
        and not conversation.is_paused
        and conversation.last_pedro_outbound_at is not null
        and conversation.last_inbound_at
          <= conversation.last_pedro_outbound_at
        and (
          (
            private.is_operation_inbound_open(
              conversation.operation_id,
              now()
            )
            and conversation.last_pedro_outbound_at
              <= now() - interval '5 minutes'
          )
          or (
            not private.is_operation_inbound_open(
              conversation.operation_id,
              now()
            )
            and slot.last_activity_at
              <= now() - interval '30 minutes'
          )
        )
      order by conversation.last_pedro_outbound_at, conversation.id
      limit 25
    loop
      perform private.enqueue_capacity_command(
        conversation_record.organization_id,
        conversation_record.operation_id,
        null,
        conversation_record.id,
        null,
        'sleep',
        jsonb_build_object(
          'conversation_id', conversation_record.id,
          'last_pedro_outbound_at',
            conversation_record.last_pedro_outbound_at,
          'observed_at', conversation_record.last_pedro_outbound_at
        ),
        't07:sleep:' || conversation_record.id::text
          || ':'
          || extract(
            epoch from conversation_record.last_pedro_outbound_at
          )::bigint::text,
        now(),
        command_record.trace_id,
        command_record.correlation_id
      );
    end loop;

    for batch_record in
      select batch.*
      from private.pedro_response_batches as batch
      where batch.operation_id = command_record.operation_id
        and (
          (
            batch.status = 'collecting'
            and batch.grouping_due_at <= now()
          )
          or (
            batch.status = 'delaying'
            and batch.delay_due_at <= now()
          )
        )
      order by
        coalesce(batch.delay_due_at, batch.grouping_due_at),
        batch.id
      limit 25
    loop
      perform private.enqueue_capacity_command(
        batch_record.organization_id,
        batch_record.operation_id,
        null,
        batch_record.conversation_id,
        null,
        case
          when batch_record.status = 'collecting'
            then 'close_response_batch'
          else 'ready_response_batch'
        end,
        jsonb_build_object(
          'batch_id', batch_record.id,
          'batch_version', batch_record.version,
          'observed_at', coalesce(
            batch_record.delay_due_at,
            batch_record.grouping_due_at
          )
        ),
        't07:batch:' || batch_record.status || ':'
          || batch_record.id::text
          || ':v' || batch_record.version::text,
        now(),
        command_record.trace_id,
        command_record.correlation_id
      );
    end loop;

    result_value := jsonb_build_object('status', 'maintained');

  elsif command_record.command_type = 'drain_backlog' then
    select backlog.*
    into backlog_record
    from private.operation_capacity_backlog as backlog
    where backlog.id = command_record.backlog_id
      and backlog.operation_id = command_record.operation_id
    for update;

    select backlog.id
    into canonical_backlog_id
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = command_record.operation_id
      and backlog.status = 'waiting'
      and backlog.eligible_at <= now()
    order by backlog.priority_class, backlog.fifo_sequence, backlog.id
    limit 1;

    if backlog_record.id is null
      or backlog_record.status <> 'waiting'
    then
      update private.operation_capacity_commands
      set status = 'cancelled', updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'cancelled');
    end if;

    if canonical_backlog_id is distinct from backlog_record.id then
      update private.operation_capacity_commands
      set
        status = 'pending',
        run_at = now() + interval '5 seconds',
        updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'deferred', 'reason', 'not_head');
    end if;

    select count(*)::integer
    into active_count
    from private.conversation_capacity_slots as slot
    where slot.operation_id = command_record.operation_id;

    state_record := private.capacity_refresh_operation_state(
      command_record.operation_id,
      now(),
      command_record.trace_id,
      command_record.correlation_id
    );

    if backlog_record.backlog_kind in ('followup', 'campaign') then
      if active_count >= 10
        or state_record.automatic_proactive_paused
        or state_record.manual_proactive_paused
        or not private.is_operation_proactive_open(
          command_record.operation_id,
          now()
        )
        or (
          state_record.last_proactive_admitted_at is not null
          and state_record.last_proactive_admitted_at
            > now() - interval '1 minute'
        )
      then
        next_run_at := greatest(
          private.next_operation_window_open(
            command_record.operation_id,
            now(),
            'proactive'
          ),
          coalesce(
            state_record.last_proactive_admitted_at + interval '1 minute',
            now() + interval '5 seconds'
          ),
          now() + interval '5 seconds'
        );
      end if;
    elsif active_count >= 30
      or not private.is_operation_inbound_open(
        command_record.operation_id,
        now()
      )
    then
      next_run_at := greatest(
        private.next_operation_window_open(
          command_record.operation_id,
          now(),
          'inbound'
        ),
        now() + interval '5 seconds'
      );
    end if;

    if next_run_at is not null then
      update private.operation_capacity_backlog
      set
        eligible_at = greatest(eligible_at, next_run_at),
        updated_at = now()
      where id = backlog_record.id;
      update private.operation_capacity_commands
      set
        status = 'pending',
        run_at = next_run_at,
        updated_at = now()
      where id = command_record.id;
      return jsonb_build_object(
        'status', 'deferred',
        'run_at', next_run_at
      );
    end if;

    admission_kind_value := case backlog_record.backlog_kind
      when 'followup' then 'followup'
      when 'campaign' then 'campaign'
      when 'sleeping_return' then 'sleeping_return'
      else 'inbound'
    end;

    result_value := private.apply_operation_capacity_command(
      command_record.operation_id,
      backlog_record.conversation_id,
      'admit_backlog',
      admission_kind_value,
      backlog_record.backlog_kind,
      backlog_record.source_message_id,
      now(),
      't07:admit-backlog:' || backlog_record.id::text,
      null,
      'durable backlog drain',
      command_record.trace_id,
      command_record.correlation_id
    );

  elsif command_record.command_type = 'resume_pending_return' then
    perform slot.conversation_id
    from private.conversation_capacity_slots as slot
    where slot.operation_id = command_record.operation_id
      and slot.conversation_id = command_record.conversation_id
    for update;

    perform backlog.id
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = command_record.operation_id
      and backlog.conversation_id = command_record.conversation_id
      and backlog.status = 'waiting'
    for update;

    select conversation.*
    into conversation_record
    from public.conversations as conversation
    where conversation.operation_id = command_record.operation_id
      and conversation.id = command_record.conversation_id
    for update;

    if conversation_record.id is null
      or not conversation_record.pending_return
      or conversation_record.pending_return_requested_version::text
        is distinct from command_record.payload ->> 'requested_version'
    then
      update private.operation_capacity_commands
      set status = 'cancelled', updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'cancelled');
    end if;

    select count(*)::integer
    into active_count
    from private.conversation_capacity_slots as slot
    where slot.operation_id = command_record.operation_id;

    if active_count >= 30
      or (
        conversation_record.pending_return_target_mode = 'production'
        and (
          not exists (
            select 1
            from public.operation_settings as settings
            where settings.operation_id = command_record.operation_id
              and settings.production_enabled
          )
          or exists (
            select 1
            from public.system_pauses as pause
            where pause.operation_id = command_record.operation_id
              and pause.status = 'active'
          )
        )
      )
    then
      update private.operation_capacity_commands
      set
        status = 'pending',
        run_at = now() + interval '30 seconds',
        updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'deferred');
    end if;

    update public.conversations
    set
      ownership_type = 'pedro',
      assigned_membership_id = null,
      automation_mode = pending_return_target_mode,
      pending_return = false,
      pending_return_target_mode = null,
      pending_return_action = null,
      pending_return_requested_at = null,
      pending_return_requested_by_membership_id = null,
      pending_return_requested_version = null,
      status = 'active',
      sleeping_since = null,
      capacity_state = 'active',
      capacity_state_changed_at = now(),
      updated_at = now(),
      version = version + 1
    where id = conversation_record.id;

    insert into private.conversation_capacity_slots (
      conversation_id,
      organization_id,
      operation_id,
      admission_kind,
      admitted_at,
      last_activity_at,
      last_pedro_outbound_at,
      trace_id,
      correlation_id
    )
    values (
      conversation_record.id,
      conversation_record.organization_id,
      conversation_record.operation_id,
      'pending_return',
      now(),
      now(),
      conversation_record.last_pedro_outbound_at,
      command_record.trace_id,
      command_record.correlation_id
    );

    insert into audit.audit_events (
      organization_id, operation_id, actor_user_id, action,
      target_type, target_id, before_state, after_state,
      trace_id, correlation_id
    )
    values (
      conversation_record.organization_id,
      conversation_record.operation_id,
      null,
      'conversation.pending_return_resumed_automatically',
      'conversation',
      conversation_record.id,
      jsonb_build_object(
        'pending_return', true,
        'owner_membership_id',
          conversation_record.assigned_membership_id
      ),
      jsonb_build_object(
        'pending_return', false,
        'ownership_type', 'pedro'
      ),
      command_record.trace_id,
      command_record.correlation_id
    );

    perform private.capacity_refresh_operation_state(
      command_record.operation_id,
      now(),
      command_record.trace_id,
      command_record.correlation_id
    );
    result_value := jsonb_build_object(
      'status', 'resumed',
      'conversation_id', conversation_record.id
    );

  elsif command_record.command_type = 'sleep' then
    select conversation.*
    into conversation_record
    from public.conversations as conversation
    where conversation.operation_id = command_record.operation_id
      and conversation.id = command_record.conversation_id;

    select slot.last_activity_at
    into slot_last_activity_at
    from private.conversation_capacity_slots as slot
    where slot.operation_id = command_record.operation_id
      and slot.conversation_id = command_record.conversation_id;

    if conversation_record.id is null
      or conversation_record.last_pedro_outbound_at is distinct from
        (command_record.payload ->> 'last_pedro_outbound_at')::timestamptz
    then
      update private.operation_capacity_commands
      set status = 'cancelled', updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'cancelled');
    end if;

    if (
      private.is_operation_inbound_open(
        command_record.operation_id,
        now()
      )
      and conversation_record.last_pedro_outbound_at
        > now() - interval '5 minutes'
    )
      or (
        not private.is_operation_inbound_open(
          command_record.operation_id,
          now()
        )
        and slot_last_activity_at > now() - interval '30 minutes'
      )
    then
      update private.operation_capacity_commands
      set
        status = 'pending',
        run_at = case
          when private.is_operation_inbound_open(
            command_record.operation_id,
            now()
          )
            then conversation_record.last_pedro_outbound_at
              + interval '5 minutes'
          else slot_last_activity_at + interval '30 minutes'
        end,
        updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'deferred');
    end if;

    result_value := private.apply_operation_capacity_command(
      command_record.operation_id,
      command_record.conversation_id,
      'sleep',
      null,
      null,
      null,
      now(),
      command_record.effect_key || ':effect',
      null,
      'five minutes without lead response',
      command_record.trace_id,
      command_record.correlation_id
    );

  elsif command_record.command_type = 'close_response_batch' then
    select batch.*
    into batch_record
    from private.pedro_response_batches as batch
    where batch.id =
      (command_record.payload ->> 'batch_id')::uuid
      and batch.operation_id = command_record.operation_id;

    if batch_record.id is null or batch_record.status <> 'collecting' then
      update private.operation_capacity_commands
      set status = 'cancelled', updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'cancelled');
    end if;

    perform slot.conversation_id
    from private.conversation_capacity_slots as slot
    where slot.operation_id = command_record.operation_id
      and slot.conversation_id = batch_record.conversation_id
    for update;

    perform backlog.id
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = command_record.operation_id
      and backlog.conversation_id = batch_record.conversation_id
      and backlog.status = 'waiting'
    for update;

    select conversation.*
    into strict conversation_record
    from public.conversations as conversation
    where conversation.operation_id = command_record.operation_id
      and conversation.id = batch_record.conversation_id
    for update;

    select batch.*
    into strict batch_record
    from private.pedro_response_batches as batch
    where batch.id = batch_record.id
    for update;

    if conversation_record.ownership_type <> 'pedro'
      and not conversation_record.pending_return
    then
      update private.pedro_response_batches
      set
        status = 'cancelled',
        cancelled_at = now(),
        updated_at = now(),
        version = version + 1
      where id = batch_record.id;
      result_value := jsonb_build_object(
        'status', 'cancelled',
        'reason', 'human_owned'
      );
    elsif not exists (
      select 1
      from private.conversation_capacity_slots as slot
      where slot.conversation_id = batch_record.conversation_id
    ) then
      update private.operation_capacity_commands
      set
        status = 'pending',
        run_at = now() + interval '5 seconds',
        updated_at = now()
      where id = command_record.id;
      return jsonb_build_object(
        'status', 'deferred',
        'reason', 'capacity_not_admitted'
      );
    end if;

    if result_value ->> 'status' = 'cancelled' then
      null;
    else
    if batch_record.grouping_due_at > now() then
      update private.operation_capacity_commands
      set
        status = 'pending',
        run_at = batch_record.grouping_due_at,
        updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'deferred');
    end if;

    delay_seconds_value := private.capacity_delay_seconds(
      't07:batch-delay:' || batch_record.id::text
        || ':v' || batch_record.version::text,
      batch_record.delay_class,
      state_record.high_demand
    );
    next_run_at := now() + make_interval(secs => delay_seconds_value);

    update private.pedro_response_batches
    set
      status = 'delaying',
      delay_seconds = delay_seconds_value,
      delay_due_at = next_run_at,
      response_effect_key = 't07:batch-delay:' || batch_record.id::text
        || ':v' || batch_record.version::text,
      updated_at = now(),
      version = version + 1
    where id = batch_record.id
    returning * into strict batch_record;

    perform private.schedule_t07_job(
      batch_record.organization_id,
      batch_record.operation_id,
      't07.ready_response_batch',
      'pedro_response_batch',
      batch_record.id,
      next_run_at,
      't07:batch:ready:' || batch_record.id::text
        || ':v' || batch_record.version::text,
      jsonb_build_object(
        'batch_id', batch_record.id,
        'batch_version', batch_record.version
      ),
      command_record.trace_id,
      command_record.correlation_id
    );

    result_value := jsonb_build_object(
      'status', 'delaying',
      'delay_seconds', delay_seconds_value,
      'delay_due_at', next_run_at
    );
    end if;

  elsif command_record.command_type = 'ready_response_batch' then
    select batch.*
    into batch_record
    from private.pedro_response_batches as batch
    where batch.id =
      (command_record.payload ->> 'batch_id')::uuid
      and batch.operation_id = command_record.operation_id
    for update;

    if batch_record.id is null or batch_record.status <> 'delaying' then
      update private.operation_capacity_commands
      set status = 'cancelled', updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'cancelled');
    end if;

    if batch_record.delay_due_at > now() then
      update private.operation_capacity_commands
      set
        status = 'pending',
        run_at = batch_record.delay_due_at,
        updated_at = now()
      where id = command_record.id;
      return jsonb_build_object('status', 'deferred');
    end if;

    update private.pedro_response_batches
    set
      status = 'ready',
      ready_at = now(),
      updated_at = now(),
      version = version + 1
    where id = batch_record.id;
    result_value := jsonb_build_object(
      'status', 'ready',
      'batch_id', batch_record.id
    );
  else
    raise exception 'unsupported capacity command'
      using errcode = '22023';
  end if;

  update private.operation_capacity_commands
  set
    status = 'applied',
    applied_at = now(),
    last_error_code = null,
    updated_at = now()
  where id = command_record.id
    and status = 'processing';

  return coalesce(result_value, jsonb_build_object('status', 'applied'));
end;
$$;

revoke all on function private.process_capacity_command(uuid)
  from public, anon, authenticated, service_role;

create or replace function private.consume_capacity_commands(
  maximum_commands integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_id uuid;
  candidate_operation_id uuid;
  claimed_operation_ids uuid[] := '{}'::uuid[];
  result_value jsonb;
  processed_count integer := 0;
  deferred_count integer := 0;
  failed_count integer := 0;
  error_state text;
begin
  if maximum_commands not between 1 and 100 then
    raise exception 'invalid capacity worker bound'
      using errcode = '22023';
  end if;

  for command_index in 1..maximum_commands loop
    select command.id, command.operation_id
    into candidate_id, candidate_operation_id
    from private.operation_capacity_commands as command
    join private.operation_capacity_state as state
      on state.operation_id = command.operation_id
    where command.status = 'pending'
      and command.run_at <= now()
      and not command.operation_id = any(claimed_operation_ids)
    order by command.run_at, command.created_at, command.id
    limit 1
    for update of state skip locked;

    exit when candidate_id is null;
    claimed_operation_ids := array_append(
      claimed_operation_ids,
      candidate_operation_id
    );

    begin
      result_value := private.process_capacity_command(candidate_id);
      if result_value ->> 'status' = 'deferred' then
        deferred_count := deferred_count + 1;
      else
        processed_count := processed_count + 1;
      end if;
    exception when others then
      get stacked diagnostics error_state = returned_sqlstate;
      update private.operation_capacity_commands
      set
        status = case
          when attempts + 1 >= 8 then 'failed'
          else 'pending'
        end,
        attempts = attempts + 1,
        run_at = now() + make_interval(
          secs => least(
            300,
            greatest(5, (attempts + 1) * (attempts + 1) * 5)
          )
        ),
        last_error_code = left(error_state, 120),
        updated_at = now()
      where id = candidate_id;
      failed_count := failed_count + 1;
    end;
  end loop;

  return jsonb_build_object(
    'processed', processed_count,
    'deferred', deferred_count,
    'failed', failed_count
  );
end;
$$;

revoke all on function private.consume_capacity_commands(integer)
  from public, anon, authenticated, service_role;

-- This is intentionally not called by private.run_durable_workers().
-- pg_cron starts a fresh transaction after the T06 job transaction committed.
select cron.schedule(
  't07-capacity-command-consumer-1s',
  '1 second',
  'select private.consume_capacity_commands(25);'
);

create or replace function private.claim_ready_response_batch(
  target_operation_id uuid,
  target_batch_id uuid,
  target_effect_key text,
  target_worker_id uuid,
  lease_seconds integer,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  batch_record private.pedro_response_batches%rowtype;
  message_payload jsonb;
  input_hash_value text;
  lease_token_value uuid;
  claim_status text;
begin
  if target_worker_id is null
    or nullif(target_effect_key, '') is null
    or lease_seconds not between 15 and 300
  then
    raise exception 'invalid response batch claim'
      using errcode = '22023';
  end if;

  select batch.*
  into strict batch_record
  from private.pedro_response_batches as batch
  where batch.operation_id = target_operation_id
    and batch.id = target_batch_id
  for update;

  if batch_record.status = 'completed' then
    if batch_record.processing_lease_until > now()
      and batch_record.processing_worker_id <> target_worker_id
    then
      return jsonb_build_object(
        'status', 'busy',
        'batch_id', batch_record.id,
        'lease_until', batch_record.processing_lease_until
      );
    end if;
    lease_token_value := gen_random_uuid();
    update private.pedro_response_batches
    set
      processing_worker_id = target_worker_id,
      processing_lease_token = lease_token_value,
      processing_lease_until = now()
        + make_interval(secs => lease_seconds),
      processing_claim_count = processing_claim_count + 1,
      trace_id = request_trace_id,
      correlation_id = request_correlation_id,
      updated_at = now(),
      version = version + 1
    where id = batch_record.id
    returning * into strict batch_record;
    return jsonb_build_object(
      'status', 'completed',
      'recovered', true,
      'batch_id', batch_record.id,
      'conversation_id', batch_record.conversation_id,
      'effect_key', batch_record.response_effect_key,
      'lease_token', batch_record.processing_lease_token,
      'lease_until', batch_record.processing_lease_until
    );
  end if;

  if batch_record.status = 'processing'
    and batch_record.processing_lease_until > now()
  then
    if batch_record.response_effect_key = target_effect_key
      and batch_record.processing_worker_id = target_worker_id
    then
      claim_status := 'resumed';
      lease_token_value := batch_record.processing_lease_token;
      update private.pedro_response_batches
      set
        processing_lease_until = now()
          + make_interval(secs => lease_seconds),
        trace_id = request_trace_id,
        correlation_id = request_correlation_id,
        updated_at = now()
      where id = batch_record.id
      returning * into strict batch_record;
    else
      return jsonb_build_object(
        'status', 'busy',
        'batch_id', batch_record.id,
        'lease_until', batch_record.processing_lease_until
      );
    end if;
  elsif batch_record.status in ('ready', 'processing') then
    claim_status := case
      when batch_record.status = 'processing' then 'reclaimed'
      else 'processing'
    end;
    lease_token_value := gen_random_uuid();
  else
    raise exception 'response batch is not ready' using errcode = '55000';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'message_id', message.id,
        'revision', message.revision,
        'body', private.message_active_body(message.id)
      )
      order by batch_message.observed_at, message.id
    ) filter (where batch_message.included and message.deleted_at is null),
    '[]'::jsonb
  )
  into message_payload
  from private.pedro_response_batch_messages as batch_message
  join public.messages as message
    on message.id = batch_message.message_id
  where batch_message.batch_id = batch_record.id;

  input_hash_value := encode(
    sha256(
      convert_to(
        jsonb_build_object(
          'batch_id', batch_record.id,
          'messages', message_payload
        )::text,
        'UTF8'
      )
    ),
    'hex'
  );

  if claim_status in ('processing', 'reclaimed') then
    update private.pedro_response_batches
    set
      status = 'processing',
      processing_at = coalesce(processing_at, now()),
      processing_worker_id = target_worker_id,
      processing_lease_token = lease_token_value,
      processing_lease_until = now()
        + make_interval(secs => lease_seconds),
      processing_input_version = version,
      processing_input_hash = input_hash_value,
      processing_claim_count = processing_claim_count + 1,
      response_effect_key = target_effect_key,
      trace_id = request_trace_id,
      correlation_id = request_correlation_id,
      updated_at = now(),
      version = version + 1
    where id = batch_record.id
    returning * into strict batch_record;
  elsif batch_record.processing_input_hash <> input_hash_value then
    raise exception 'response batch input changed under active lease'
      using errcode = '40001';
  end if;

  return jsonb_build_object(
    'status', claim_status,
    'batch_id', batch_record.id,
    'conversation_id', batch_record.conversation_id,
    'effect_key', batch_record.response_effect_key,
    'lease_token', batch_record.processing_lease_token,
    'lease_until', batch_record.processing_lease_until,
    'input_version', batch_record.processing_input_version,
    'input_hash', batch_record.processing_input_hash,
    'messages', message_payload
  );
end;
$$;

create or replace function private.complete_response_batch(
  target_operation_id uuid,
  target_batch_id uuid,
  target_effect_key text,
  target_worker_id uuid,
  target_lease_token uuid,
  target_input_hash text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  batch_record private.pedro_response_batches%rowtype;
begin
  select batch.*
  into strict batch_record
  from private.pedro_response_batches as batch
  where batch.operation_id = target_operation_id
    and batch.id = target_batch_id
  for update;

  if batch_record.response_effect_key is distinct from target_effect_key then
    raise exception 'response batch effect conflict'
      using errcode = '23505';
  end if;
  if batch_record.status = 'completed' then
    if batch_record.processing_worker_id is not distinct from target_worker_id
      and batch_record.processing_lease_token
        is not distinct from target_lease_token
    then
      return jsonb_build_object(
        'status', 'duplicate',
        'lease_token', batch_record.processing_lease_token
      );
    end if;
    raise exception 'response batch completion lease conflict'
      using errcode = '40001';
  end if;
  if batch_record.status <> 'processing' then
    raise exception 'response batch is not processing'
      using errcode = '55000';
  end if;
  if batch_record.processing_worker_id is distinct from target_worker_id
    or batch_record.processing_lease_token is distinct from target_lease_token
    or batch_record.processing_lease_until <= now()
    or batch_record.processing_input_hash is distinct from target_input_hash
  then
    raise exception 'response batch processing lease is stale'
      using errcode = '40001';
  end if;

  update private.pedro_response_batches
  set
    status = 'completed',
    completed_at = now(),
    processing_lease_until = now() + interval '2 minutes',
    trace_id = request_trace_id,
    correlation_id = request_correlation_id,
    updated_at = now(),
    version = version + 1
  where id = batch_record.id;

  return jsonb_build_object(
    'status', 'completed',
    'lease_token', target_lease_token,
    'lease_until', now() + interval '2 minutes'
  );
end;
$$;

create or replace function private.consume_response_batch(
  target_operation_id uuid,
  target_batch_id uuid,
  target_effect_key text,
  target_worker_id uuid,
  target_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  batch_record private.pedro_response_batches%rowtype;
begin
  select batch.*
  into strict batch_record
  from private.pedro_response_batches as batch
  where batch.operation_id = target_operation_id
    and batch.id = target_batch_id
  for update;

  if batch_record.response_effect_key is distinct from target_effect_key then
    raise exception 'response batch effect conflict'
      using errcode = '23505';
  end if;
  if batch_record.status = 'consumed' then
    return jsonb_build_object('status', 'duplicate');
  end if;
  if batch_record.processing_worker_id is distinct from target_worker_id
    or batch_record.processing_lease_token is distinct from target_lease_token
    or batch_record.processing_lease_until <= now()
  then
    raise exception 'response batch completion lease is stale'
      using errcode = '40001';
  end if;
  if batch_record.status <> 'completed' then
    raise exception 'response batch is not completed'
      using errcode = '55000';
  end if;

  update private.pedro_response_batches
  set
    status = 'consumed',
    consumed_at = now(),
    updated_at = now(),
    version = version + 1
  where id = batch_record.id;

  return jsonb_build_object('status', 'consumed');
end;
$$;

create or replace function private.cancel_response_batch(
  target_operation_id uuid,
  target_batch_id uuid,
  target_reason text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  batch_record private.pedro_response_batches%rowtype;
begin
  if nullif(btrim(coalesce(target_reason, '')), '') is null then
    raise exception 'batch cancellation reason is required'
      using errcode = '22023';
  end if;

  select batch.*
  into strict batch_record
  from private.pedro_response_batches as batch
  where batch.operation_id = target_operation_id
    and batch.id = target_batch_id
  for update;

  if batch_record.status = 'cancelled' then
    return jsonb_build_object('status', 'duplicate');
  end if;
  if batch_record.status = 'consumed' then
    raise exception 'consumed response batch cannot be cancelled'
      using errcode = '55000';
  end if;

  update private.pedro_response_batches
  set
    status = 'cancelled',
    cancelled_at = now(),
    trace_id = request_trace_id,
    correlation_id = request_correlation_id,
    updated_at = now(),
    version = version + 1
  where id = batch_record.id;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    batch_record.organization_id,
    batch_record.operation_id,
    null,
    'pedro_response_batch.cancelled',
    'pedro_response_batch',
    batch_record.id,
    jsonb_build_object('status', batch_record.status),
    jsonb_build_object(
      'status', 'cancelled',
      'reason', left(btrim(target_reason), 500)
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object('status', 'cancelled');
end;
$$;

revoke all on function private.claim_ready_response_batch(
  uuid, uuid, text, uuid, integer, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function private.complete_response_batch(
  uuid, uuid, text, uuid, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function private.consume_response_batch(
  uuid, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function private.cancel_response_batch(
  uuid, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.assert_t07_service_role()
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if current_setting('request.jwt.claim.role', true)
      is distinct from 'service_role'
    and session_user not in ('postgres', 'supabase_admin')
  then
    raise exception 'T07 worker service role required'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function private.assert_t07_service_role()
  from public, anon, authenticated, service_role;

create or replace function public.service_claim_next_response_batch(
  target_operation_id uuid,
  target_worker_id uuid,
  lease_seconds integer,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_record private.pedro_response_batches%rowtype;
  effect_key_value text;
begin
  perform private.assert_t07_service_role();
  if target_worker_id is null
    or lease_seconds not between 15 and 300
  then
    raise exception 'invalid response batch worker claim'
      using errcode = '22023';
  end if;

  select batch.*
  into candidate_record
  from private.pedro_response_batches as batch
  where batch.operation_id = target_operation_id
    and (
      batch.status = 'ready'
      or (
        batch.status in ('processing', 'completed')
        and batch.processing_lease_until <= now()
      )
    )
  order by
    case batch.status
      when 'completed' then 1
      when 'processing' then 2
      else 3
    end,
    coalesce(
      batch.completed_at,
      batch.processing_lease_until,
      batch.ready_at
    ),
    batch.id
  limit 1
  for update skip locked;

  if candidate_record.id is null then
    return jsonb_build_object('status', 'idle');
  end if;

  effect_key_value := case
    when candidate_record.status = 'ready'
      then 't07:ai-turn:' || candidate_record.id::text
        || ':v' || candidate_record.version::text
    else candidate_record.response_effect_key
  end;

  return private.claim_ready_response_batch(
    candidate_record.operation_id,
    candidate_record.id,
    effect_key_value,
    target_worker_id,
    lease_seconds,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

create or replace function public.service_complete_response_batch(
  target_operation_id uuid,
  target_batch_id uuid,
  target_effect_key text,
  target_worker_id uuid,
  target_lease_token uuid,
  target_input_hash text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_t07_service_role();
  return private.complete_response_batch(
    target_operation_id,
    target_batch_id,
    target_effect_key,
    target_worker_id,
    target_lease_token,
    target_input_hash,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

create or replace function public.service_consume_response_batch(
  target_operation_id uuid,
  target_batch_id uuid,
  target_effect_key text,
  target_worker_id uuid,
  target_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_t07_service_role();
  return private.consume_response_batch(
    target_operation_id,
    target_batch_id,
    target_effect_key,
    target_worker_id,
    target_lease_token
  );
end;
$$;

create or replace function public.service_cancel_response_batch(
  target_operation_id uuid,
  target_batch_id uuid,
  target_reason text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_t07_service_role();
  return private.cancel_response_batch(
    target_operation_id,
    target_batch_id,
    target_reason,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

create or replace function public.service_apply_provider_message_revision(
  target_organization_id uuid,
  target_operation_id uuid,
  target_connection_id uuid,
  target_provider_event_id text,
  target_provider_message_id text,
  target_revision_kind text,
  target_revised_body text,
  target_provider_occurred_at timestamptz,
  target_payload_hash text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_t07_service_role();
  return private.apply_provider_message_revision(
    target_organization_id,
    target_operation_id,
    target_connection_id,
    target_provider_event_id,
    target_provider_message_id,
    target_revision_kind,
    target_revised_body,
    target_provider_occurred_at,
    target_payload_hash,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

revoke all on function public.service_claim_next_response_batch(
  uuid, uuid, integer, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.service_claim_next_response_batch(
  uuid, uuid, integer, uuid, uuid
) to service_role;
revoke all on function public.service_complete_response_batch(
  uuid, uuid, text, uuid, uuid, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.service_complete_response_batch(
  uuid, uuid, text, uuid, uuid, text, uuid, uuid
) to service_role;
revoke all on function public.service_consume_response_batch(
  uuid, uuid, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.service_consume_response_batch(
  uuid, uuid, text, uuid, uuid
) to service_role;
revoke all on function public.service_cancel_response_batch(
  uuid, uuid, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.service_cancel_response_batch(
  uuid, uuid, text, uuid, uuid
) to service_role;
revoke all on function public.service_apply_provider_message_revision(
  uuid, uuid, uuid, text, text, text, text, timestamptz,
  text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.service_apply_provider_message_revision(
  uuid, uuid, uuid, text, text, text, text, timestamptz,
  text, uuid, uuid
) to service_role;

create table private.pedro_outbound_effects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  conversation_id uuid not null,
  effect_key text not null check (char_length(effect_key) between 1 and 500),
  sent_at timestamptz not null,
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  unique (organization_id, operation_id, effect_key),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade
);

revoke all on table private.pedro_outbound_effects
  from public, anon, authenticated, service_role;

create or replace function private.record_pedro_outbound_sent(
  target_operation_id uuid,
  target_conversation_id uuid,
  target_effect_key text,
  sent_at timestamptz,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  state_record private.operation_capacity_state%rowtype;
  conversation_record public.conversations%rowtype;
  existing_record private.pedro_outbound_effects%rowtype;
begin
  select state.*
  into strict state_record
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id
  for update;

  perform slot.conversation_id
  from private.conversation_capacity_slots as slot
  where slot.operation_id = target_operation_id
    and slot.conversation_id = target_conversation_id
  for update;

  select conversation.*
  into strict conversation_record
  from public.conversations as conversation
  where conversation.operation_id = target_operation_id
    and conversation.id = target_conversation_id
  for update;

  select effect.*
  into existing_record
  from private.pedro_outbound_effects as effect
  where effect.organization_id = state_record.organization_id
    and effect.operation_id = target_operation_id
    and effect.effect_key = target_effect_key;

  if existing_record.id is not null then
    if existing_record.conversation_id <> target_conversation_id
      or existing_record.sent_at <> sent_at
    then
      raise exception 'Pedro outbound replay conflict'
        using errcode = '23505';
    end if;
    return jsonb_build_object('status', 'duplicate');
  end if;

  if conversation_record.ownership_type <> 'pedro'
    or conversation_record.capacity_state <> 'active'
  then
    raise exception 'Pedro outbound requires active Pedro ownership'
      using errcode = '55000';
  end if;

  insert into private.pedro_outbound_effects (
    organization_id,
    operation_id,
    conversation_id,
    effect_key,
    sent_at,
    trace_id,
    correlation_id
  )
  values (
    conversation_record.organization_id,
    conversation_record.operation_id,
    conversation_record.id,
    target_effect_key,
    sent_at,
    request_trace_id,
    request_correlation_id
  );

  update public.conversations
  set
    last_pedro_outbound_at = greatest(
      coalesce(last_pedro_outbound_at, sent_at),
      sent_at
    ),
    updated_at = greatest(updated_at, sent_at)
  where id = conversation_record.id;

  update private.conversation_capacity_slots
  set
    last_activity_at = greatest(last_activity_at, sent_at),
    last_pedro_outbound_at = greatest(
      coalesce(last_pedro_outbound_at, sent_at),
      sent_at
    ),
    trace_id = request_trace_id,
    correlation_id = request_correlation_id
  where conversation_id = conversation_record.id;

  perform private.schedule_t07_job(
    conversation_record.organization_id,
    conversation_record.operation_id,
    't07.sleep_conversation',
    'conversation_capacity',
    conversation_record.id,
    sent_at + interval '5 minutes',
    't07:sleep:' || conversation_record.id::text
      || ':' || extract(epoch from sent_at)::bigint::text,
    jsonb_build_object(
      'conversation_id', conversation_record.id,
      'last_pedro_outbound_at', sent_at,
      'observed_at', sent_at + interval '5 minutes'
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object('status', 'recorded');
end;
$$;

revoke all on function private.record_pedro_outbound_sent(
  uuid, uuid, text, timestamptz, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function public.service_record_pedro_outbound_sent(
  target_operation_id uuid,
  target_conversation_id uuid,
  target_effect_key text,
  sent_at timestamptz,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_t07_service_role();
  return private.record_pedro_outbound_sent(
    target_operation_id,
    target_conversation_id,
    target_effect_key,
    sent_at,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

revoke all on function public.service_record_pedro_outbound_sent(
  uuid, uuid, text, timestamptz, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.service_record_pedro_outbound_sent(
  uuid, uuid, text, timestamptz, uuid, uuid
) to service_role;

create or replace function public.set_operation_proactive_pause(
  target_operation_id uuid,
  paused boolean,
  target_reason text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_membership_id uuid;
begin
  -- The lock precedes permission/membership and every state mutation.
  perform private.apply_operation_capacity_command(
    target_operation_id,
    null,
    'lock_operation',
    null,
    null,
    null,
    now(),
    null,
    null,
    null,
    request_trace_id,
    request_correlation_id
  );

  if not private.can_manage_conversation_operation(target_operation_id) then
    raise exception 'Operation capacity permission denied'
      using errcode = '42501';
  end if;

  actor_membership_id :=
    private.actor_membership_id(target_operation_id);
  if actor_membership_id is null then
    raise exception 'active Operation membership required'
      using errcode = '42501';
  end if;

  return private.apply_operation_capacity_command(
    target_operation_id,
    null,
    case when paused then 'set_manual_pause' else 'clear_manual_pause' end,
    null,
    null,
    null,
    now(),
    null,
    actor_membership_id,
    case
      when paused then target_reason
      else null
    end,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

revoke all on function public.set_operation_proactive_pause(
  uuid, boolean, text, uuid, uuid
) from public, anon, service_role;
grant execute on function public.set_operation_proactive_pause(
  uuid, boolean, text, uuid, uuid
) to authenticated;

create or replace function public.get_operation_capacity_status(
  target_operation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result_value jsonb;
begin
  if not private.can_manage_conversation_operation(target_operation_id) then
    raise exception 'Operation capacity permission denied'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'operation_id', state.operation_id,
    'active_slots', (
      select count(*)::integer
      from private.conversation_capacity_slots as slot
      where slot.operation_id = state.operation_id
    ),
    'automatic_proactive_paused',
      state.automatic_proactive_paused,
    'manual_proactive_paused',
      state.manual_proactive_paused,
    'high_demand', state.high_demand,
    'below_ten_since', state.below_ten_since,
    'waiting_total', (
      select count(*)::integer
      from private.operation_capacity_backlog as backlog
      where backlog.operation_id = state.operation_id
        and backlog.status = 'waiting'
    ),
    'oldest_waiting_at', (
      select min(backlog.arrived_at)
      from private.operation_capacity_backlog as backlog
      where backlog.operation_id = state.operation_id
        and backlog.status = 'waiting'
    ),
    'backlog_by_kind', coalesce(
      (
        select jsonb_object_agg(summary.backlog_kind, summary.total)
        from (
          select backlog.backlog_kind, count(*)::integer as total
          from private.operation_capacity_backlog as backlog
          where backlog.operation_id = state.operation_id
            and backlog.status = 'waiting'
          group by backlog.backlog_kind
        ) as summary
      ),
      '{}'::jsonb
    ),
    'pending_returns', (
      select count(*)::integer
      from public.conversations as conversation
      where conversation.operation_id = state.operation_id
        and conversation.pending_return
    ),
    'version', state.version,
    'updated_at', state.updated_at
  )
  into strict result_value
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id;

  return result_value;
end;
$$;

revoke all on function public.get_operation_capacity_status(uuid)
  from public, anon, service_role;
grant execute on function public.get_operation_capacity_status(uuid)
  to authenticated;
