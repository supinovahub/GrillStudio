-- T07 slice (b): one internal OperationCapacity mutation boundary and T05
-- writer integration. This migration is forward-only.

do $$
begin
  if exists (
    select 1
    from public.operations as operation
    where operation.timezone is null
      or not exists (
        select 1
        from pg_catalog.pg_timezone_names as zone
        where zone.name = operation.timezone
      )
  ) then
    raise exception 'existing Operation has invalid IANA timezone'
      using errcode = '23514';
  end if;
end;
$$;

create or replace function private.prevent_capacity_identity_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id
    or new.operation_id is distinct from old.operation_id
    or new.conversation_id is distinct from old.conversation_id
  then
    raise exception 'capacity aggregate identity is immutable'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.prevent_capacity_identity_change()
  from public, anon, authenticated, service_role;

create trigger conversation_capacity_slots_identity_immutable
before update of organization_id, operation_id, conversation_id
on private.conversation_capacity_slots
for each row execute function private.prevent_capacity_identity_change();

create trigger operation_capacity_backlog_identity_immutable
before update of organization_id, operation_id, conversation_id
on private.operation_capacity_backlog
for each row execute function private.prevent_capacity_identity_change();

create or replace function private.assert_conversation_capacity_coherence(
  target_conversation_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  conversation_record public.conversations%rowtype;
  slot_count integer;
  waiting_count integer;
begin
  select conversation.*
  into conversation_record
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  if conversation_record.id is null then
    return;
  end if;

  select count(*)::integer
  into slot_count
  from private.conversation_capacity_slots as slot
  where slot.conversation_id = target_conversation_id;

  select count(*)::integer
  into waiting_count
  from private.operation_capacity_backlog as backlog
  where backlog.conversation_id = target_conversation_id
    and backlog.status = 'waiting';

  if conversation_record.capacity_state = 'excluded' then
    if slot_count <> 0 or waiting_count <> 0 then
      raise exception
        'excluded Conversation cannot hold capacity state'
        using errcode = '23514';
    end if;
  elsif conversation_record.capacity_state = 'active' then
    if conversation_record.status <> 'active'
      or conversation_record.ownership_type <> 'pedro'
      or conversation_record.assigned_membership_id is not null
      or conversation_record.is_paused
      or slot_count <> 1
      or waiting_count <> 0
    then
      raise exception 'active capacity aggregate is incoherent'
        using errcode = '23514';
    end if;
  elsif conversation_record.capacity_state = 'waiting' then
    if conversation_record.status <> 'active'
      or conversation_record.ownership_type <> 'pedro'
      or conversation_record.assigned_membership_id is not null
      or conversation_record.is_paused
      or slot_count <> 0
      or waiting_count <> 1
    then
      raise exception 'waiting capacity aggregate is incoherent'
        using errcode = '23514';
    end if;
  elsif conversation_record.capacity_state = 'sleeping' then
    if conversation_record.status <> 'sleeping'
      or conversation_record.ownership_type <> 'pedro'
      or conversation_record.assigned_membership_id is not null
      or conversation_record.is_paused
      or slot_count <> 0
      or waiting_count <> 0
    then
      raise exception 'sleeping capacity aggregate is incoherent'
        using errcode = '23514';
    end if;
  else
    raise exception 'unknown Conversation capacity state'
      using errcode = '23514';
  end if;
end;
$$;

create or replace function
  private.enforce_conversation_capacity_coherence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform private.assert_conversation_capacity_coherence(
      old.conversation_id
    );
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform private.assert_conversation_capacity_coherence(
      new.conversation_id
    );
  end if;
  return null;
end;
$$;

alter table private.operation_capacity_state
  add column automatic_pause_reason text
    check (
      automatic_pause_reason is null
      or automatic_pause_reason in ('high_demand')
    ),
  add column automatic_paused_at timestamptz,
  add column manual_pause_reason text
    check (
      manual_pause_reason is null
      or char_length(manual_pause_reason) between 1 and 500
    ),
  add column manual_paused_at timestamptz,
  add column manual_paused_by_membership_id uuid,
  add column last_proactive_effect_key text
    check (
      last_proactive_effect_key is null
      or char_length(last_proactive_effect_key) between 1 and 500
    ),
  add constraint operation_capacity_automatic_pause_metadata_check
    check (
      (
        automatic_proactive_paused
        and automatic_pause_reason = 'high_demand'
        and automatic_paused_at is not null
      )
      or (
        not automatic_proactive_paused
        and automatic_pause_reason is null
        and automatic_paused_at is null
      )
    ),
  add constraint operation_capacity_manual_pause_metadata_check
    check (
      (
        manual_proactive_paused
        and manual_pause_reason is not null
        and manual_paused_at is not null
        and manual_paused_by_membership_id is not null
      )
      or (
        not manual_proactive_paused
        and manual_pause_reason is null
        and manual_paused_at is null
        and manual_paused_by_membership_id is null
      )
    ),
  add constraint operation_capacity_manual_pause_membership_fkey
    foreign key (organization_id, manual_paused_by_membership_id)
    references public.memberships(organization_id, id);

create index operation_capacity_manual_pause_membership_idx
  on private.operation_capacity_state (
    organization_id,
    manual_paused_by_membership_id
  )
  where manual_paused_by_membership_id is not null;

create table private.operation_capacity_effects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  effect_key text not null
    check (char_length(effect_key) between 1 and 500),
  conversation_id uuid,
  command_type text not null
    check (
      command_type in (
        'admit_inbound',
        'admit_proactive',
        'admit_backlog',
        'finalize_return',
        'opt_out',
        'sleep'
      )
    ),
  outcome text not null
    check (
      outcome in (
        'admitted',
        'already_active',
        'waiting',
        'excluded',
        'sleeping',
        'blocked',
        'pending'
      )
    ),
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

create index operation_capacity_effects_conversation_idx
  on private.operation_capacity_effects (
    organization_id,
    operation_id,
    conversation_id,
    created_at
  )
  where conversation_id is not null;

revoke all on table private.operation_capacity_effects
  from public, anon, authenticated, service_role;

create or replace function private.capacity_enqueue_waiting(
  target_organization_id uuid,
  target_operation_id uuid,
  target_conversation_id uuid,
  target_source_message_id uuid,
  target_backlog_kind text,
  target_arrived_at timestamptz,
  target_eligible_at timestamptz,
  target_trace_id uuid,
  target_correlation_id uuid
)
returns private.operation_capacity_backlog
language plpgsql
security definer
set search_path = ''
as $$
declare
  state_record private.operation_capacity_state%rowtype;
  backlog_record private.operation_capacity_backlog%rowtype;
  priority_value smallint;
begin
  priority_value := private.capacity_priority_for_kind(target_backlog_kind);
  if priority_value is null then
    raise exception 'backlog kind cannot wait for capacity'
      using errcode = '22023';
  end if;

  select state.*
  into strict state_record
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id
  for update;

  if state_record.organization_id <> target_organization_id then
    raise exception 'OperationCapacity tenant mismatch'
      using errcode = '23503';
  end if;

  select backlog.*
  into backlog_record
  from private.operation_capacity_backlog as backlog
  where backlog.operation_id = target_operation_id
    and backlog.conversation_id = target_conversation_id
    and backlog.status = 'waiting'
  for update;

  if backlog_record.id is not null then
    if backlog_record.priority_class > priority_value then
      update private.operation_capacity_backlog
      set
        backlog_kind = target_backlog_kind,
        priority_class = priority_value,
        source_message_id = coalesce(
          target_source_message_id,
          source_message_id
        ),
        eligible_at = least(eligible_at, target_eligible_at),
        updated_at = now()
      where id = backlog_record.id
      returning * into strict backlog_record;
    end if;
    return backlog_record;
  end if;

  update private.operation_capacity_state
  set
    last_backlog_sequence = last_backlog_sequence + 1,
    updated_at = now(),
    version = version + 1
  where operation_id = target_operation_id
  returning * into strict state_record;

  insert into private.operation_capacity_backlog (
    organization_id,
    operation_id,
    conversation_id,
    source_message_id,
    backlog_kind,
    priority_class,
    status,
    arrived_at,
    eligible_at,
    trace_id,
    correlation_id,
    fifo_sequence
  )
  values (
    target_organization_id,
    target_operation_id,
    target_conversation_id,
    target_source_message_id,
    target_backlog_kind,
    priority_value,
    'waiting',
    target_arrived_at,
    target_eligible_at,
    target_trace_id,
    target_correlation_id,
    state_record.last_backlog_sequence
  )
  returning * into strict backlog_record;

  return backlog_record;
end;
$$;

revoke all on function private.capacity_enqueue_waiting(
  uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, uuid, uuid
) from public, anon, authenticated, service_role;

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
  previous_automatic_paused boolean;
begin
  select state.*
  into strict state_record
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id
  for update;
  previous_automatic_paused :=
    state_record.automatic_proactive_paused;

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

  update private.operation_capacity_state
  set
    automatic_proactive_paused = case
      when active_count >= 25 then true
      when automatic_proactive_paused
        and active_count < 10
        and below_ten_since is not null
        and below_ten_since <= observed_at - interval '5 minutes'
        and not delayed_inbound_exists
        then false
      else automatic_proactive_paused
    end,
    automatic_pause_reason = case
      when active_count >= 25 then 'high_demand'
      when automatic_proactive_paused
        and active_count < 10
        and below_ten_since is not null
        and below_ten_since <= observed_at - interval '5 minutes'
        and not delayed_inbound_exists
        then null
      else automatic_pause_reason
    end,
    automatic_paused_at = case
      when active_count >= 25
        then coalesce(automatic_paused_at, observed_at)
      when automatic_proactive_paused
        and active_count < 10
        and below_ten_since is not null
        and below_ten_since <= observed_at - interval '5 minutes'
        and not delayed_inbound_exists
        then null
      else automatic_paused_at
    end,
    high_demand = active_count >= 25,
    high_demand_since = case
      when active_count >= 25
        then coalesce(high_demand_since, observed_at)
      else null
    end,
    below_ten_since = case
      when active_count < 10 then coalesce(below_ten_since, observed_at)
      else null
    end,
    inbound_backlog_clear_since = case
      when delayed_inbound_exists then null
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

create or replace function private.apply_operation_capacity_command(
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
  conversation_record public.conversations%rowtype;
  existing_effect private.operation_capacity_effects%rowtype;
  active_count integer;
  outcome_value text := 'excluded';
  eligibility_time timestamptz;
  effect_is_new boolean := false;
begin
  if target_operation_id is null
    or command_type is null
    or observed_at is null
    or request_trace_id is null
    or request_correlation_id is null
  then
    raise exception 'capacity command fields are required'
      using errcode = '22023';
  end if;
  if command_type not in (
    'lock_operation',
    'lock_conversation',
    'prepare_human',
    'cancel_pending',
    'admit_inbound',
    'admit_proactive',
    'admit_backlog',
    'finalize_return',
    'opt_out',
    'sleep',
    'evaluate_resume',
    'set_manual_pause',
    'clear_manual_pause'
  ) then
    raise exception 'unknown capacity command' using errcode = '22023';
  end if;

  -- Global lock order starts here and nowhere else:
  -- OperationCapacity -> existing Backlog/Slot -> Conversation.
  select state.*
  into strict state_record
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id
  for update;

  if target_conversation_id is not null then
    perform slot.conversation_id
    from private.conversation_capacity_slots as slot
    where slot.operation_id = target_operation_id
      and slot.conversation_id = target_conversation_id
    for update;

    perform backlog.id
    from private.operation_capacity_backlog as backlog
    where backlog.operation_id = target_operation_id
      and backlog.conversation_id = target_conversation_id
      and backlog.status = 'waiting'
    order by backlog.fifo_sequence
    for update;

    select conversation.*
    into strict conversation_record
    from public.conversations as conversation
    where conversation.operation_id = target_operation_id
      and conversation.id = target_conversation_id
    for update;

    if conversation_record.organization_id <> state_record.organization_id
    then
      raise exception 'capacity Conversation tenant mismatch'
        using errcode = '23503';
    end if;
  elsif command_type not in (
    'lock_operation',
    'evaluate_resume',
    'set_manual_pause',
    'clear_manual_pause'
  ) then
    raise exception 'capacity command requires Conversation'
      using errcode = '22023';
  end if;

  if command_type in (
    'admit_inbound',
    'admit_proactive',
    'admit_backlog',
    'finalize_return',
    'opt_out',
    'sleep'
  ) then
    if target_effect_key is null
      or char_length(target_effect_key) not between 1 and 500
    then
      raise exception 'capacity effect key is required'
        using errcode = '22023';
    end if;

    select effect.*
    into existing_effect
    from private.operation_capacity_effects as effect
    where effect.organization_id = state_record.organization_id
      and effect.operation_id = target_operation_id
      and effect.effect_key = target_effect_key
    for update;

    if existing_effect.id is not null then
      if existing_effect.command_type <> command_type
        or existing_effect.conversation_id
          is distinct from target_conversation_id
      then
        raise exception 'capacity effect replay conflict'
          using errcode = '23505';
      end if;
      return jsonb_build_object(
        'status', 'duplicate',
        'outcome', existing_effect.outcome,
        'conversation_id', existing_effect.conversation_id
      );
    end if;
    effect_is_new := true;
  end if;

  if command_type = 'lock_operation' then
    return jsonb_build_object(
      'status', 'locked',
      'operation_id', target_operation_id
    );
  elsif command_type = 'lock_conversation' then
    return jsonb_build_object(
      'status', 'locked',
      'conversation_id', target_conversation_id
    );
  elsif command_type = 'set_manual_pause' then
    if target_actor_membership_id is null
      or nullif(btrim(coalesce(target_reason, '')), '') is null
    then
      raise exception 'manual pause actor and reason are required'
        using errcode = '22023';
    end if;
    update private.operation_capacity_state
    set
      manual_proactive_paused = true,
      manual_pause_reason = left(btrim(target_reason), 500),
      manual_paused_at = observed_at,
      manual_paused_by_membership_id = target_actor_membership_id,
      updated_at = observed_at,
      version = version + 1
    where operation_id = target_operation_id;
    insert into audit.audit_events (
      organization_id, operation_id, actor_user_id, action,
      target_type, target_id, before_state, after_state,
      trace_id, correlation_id
    )
    values (
      state_record.organization_id, target_operation_id, auth.uid(),
      'operation.proactive_capacity_paused_manually',
      'operation', target_operation_id,
      jsonb_build_object(
        'manual_proactive_paused',
        state_record.manual_proactive_paused
      ),
      jsonb_build_object(
        'manual_proactive_paused', true,
        'reason_recorded', true,
        'actor_membership_id', target_actor_membership_id
      ),
      request_trace_id, request_correlation_id
    );
    return jsonb_build_object('status', 'manual_pause_enabled');
  elsif command_type = 'clear_manual_pause' then
    update private.operation_capacity_state
    set
      manual_proactive_paused = false,
      manual_pause_reason = null,
      manual_paused_at = null,
      manual_paused_by_membership_id = null,
      updated_at = observed_at,
      version = version + 1
    where operation_id = target_operation_id;
    insert into audit.audit_events (
      organization_id, operation_id, actor_user_id, action,
      target_type, target_id, before_state, after_state,
      trace_id, correlation_id
    )
    values (
      state_record.organization_id, target_operation_id, auth.uid(),
      'operation.proactive_capacity_resumed_manually',
      'operation', target_operation_id,
      jsonb_build_object(
        'manual_proactive_paused',
        state_record.manual_proactive_paused
      ),
      jsonb_build_object('manual_proactive_paused', false),
      request_trace_id, request_correlation_id
    );
    return jsonb_build_object('status', 'manual_pause_cleared');
  elsif command_type = 'evaluate_resume' then
    state_record := private.capacity_refresh_operation_state(
      target_operation_id,
      observed_at,
      request_trace_id,
      request_correlation_id
    );
    return jsonb_build_object(
      'status', 'evaluated',
      'automatic_proactive_paused',
        state_record.automatic_proactive_paused,
      'manual_proactive_paused', state_record.manual_proactive_paused
    );
  elsif command_type in ('prepare_human', 'cancel_pending', 'opt_out') then
    delete from private.conversation_capacity_slots
    where operation_id = target_operation_id
      and conversation_id = target_conversation_id;
    update private.operation_capacity_backlog
    set
      status = 'cancelled',
      cancelled_at = observed_at,
      updated_at = observed_at
    where operation_id = target_operation_id
      and conversation_id = target_conversation_id
      and status = 'waiting';
    update public.conversations
    set
      capacity_state = 'excluded',
      capacity_state_changed_at = observed_at
    where id = target_conversation_id;
    outcome_value := case
      when command_type = 'opt_out' then 'blocked'
      else 'excluded'
    end;
  elsif command_type = 'sleep' then
    if conversation_record.last_pedro_outbound_at is null
      or conversation_record.last_inbound_at
        > conversation_record.last_pedro_outbound_at
      or conversation_record.last_pedro_outbound_at
        > observed_at - interval '5 minutes'
    then
      outcome_value := 'already_active';
    else
      delete from private.conversation_capacity_slots
      where operation_id = target_operation_id
        and conversation_id = target_conversation_id;
      update private.operation_capacity_backlog
      set
        status = 'cancelled',
        cancelled_at = observed_at,
        updated_at = observed_at
      where operation_id = target_operation_id
        and conversation_id = target_conversation_id
        and status = 'waiting';
      update public.conversations
      set
        status = 'sleeping',
        sleeping_since = observed_at,
        capacity_state = 'sleeping',
        capacity_state_changed_at = observed_at,
        updated_at = observed_at,
        version = version + 1
      where id = target_conversation_id
        and ownership_type = 'pedro'
        and not is_paused;
      outcome_value := case when found then 'sleeping' else 'excluded' end;
    end if;
  elsif command_type in (
    'admit_inbound',
    'admit_proactive',
    'admit_backlog',
    'finalize_return'
  ) then
    if conversation_record.ownership_type <> 'pedro'
      or conversation_record.assigned_membership_id is not null
      or conversation_record.is_paused
      or conversation_record.status = 'closed'
    then
      delete from private.conversation_capacity_slots
      where operation_id = target_operation_id
        and conversation_id = target_conversation_id;
      update private.operation_capacity_backlog
      set
        status = 'cancelled',
        cancelled_at = observed_at,
        updated_at = observed_at
      where operation_id = target_operation_id
        and conversation_id = target_conversation_id
        and status = 'waiting';
      update public.conversations
      set
        capacity_state = 'excluded',
        capacity_state_changed_at = observed_at
      where id = target_conversation_id;
      outcome_value := case
        when conversation_record.pending_return then 'pending'
        else 'excluded'
      end;
    elsif exists (
      select 1
      from private.conversation_capacity_slots as slot
      where slot.conversation_id = target_conversation_id
    ) then
      update private.conversation_capacity_slots
      set
        last_activity_at = greatest(last_activity_at, observed_at),
        trace_id = request_trace_id,
        correlation_id = request_correlation_id
      where conversation_id = target_conversation_id;
      update public.conversations
      set
        status = 'active',
        sleeping_since = null,
        capacity_state = 'active',
        capacity_state_changed_at = observed_at
      where id = target_conversation_id;
      outcome_value := 'already_active';
    else
      select count(*)::integer
      into active_count
      from private.conversation_capacity_slots as slot
      where slot.operation_id = target_operation_id;

      if command_type = 'admit_proactive'
        or (
          command_type = 'admit_backlog'
          and target_admission_kind in ('followup', 'campaign')
        )
      then
        if target_admission_kind not in ('followup', 'campaign')
          or target_backlog_kind not in ('followup', 'campaign')
        then
          raise exception 'invalid proactive admission kind'
            using errcode = '22023';
        end if;
        if state_record.manual_proactive_paused
          or state_record.automatic_proactive_paused
          or active_count >= 10
          or not private.is_operation_proactive_open(
            target_operation_id,
            observed_at
          )
          or (
            state_record.last_proactive_admitted_at is not null
            and state_record.last_proactive_admitted_at
              > observed_at - interval '1 minute'
          )
        then
          eligibility_time := greatest(
            private.next_operation_window_open(
              target_operation_id,
              observed_at,
              'proactive'
            ),
            coalesce(
              state_record.last_proactive_admitted_at
                + interval '1 minute',
              observed_at
            )
          );
          perform private.capacity_enqueue_waiting(
            state_record.organization_id,
            target_operation_id,
            target_conversation_id,
            target_source_message_id,
            target_backlog_kind,
            observed_at,
            eligibility_time,
            request_trace_id,
            request_correlation_id
          );
          update public.conversations
          set
            status = 'active',
            sleeping_since = null,
            capacity_state = 'waiting',
            capacity_state_changed_at = observed_at
          where id = target_conversation_id;
          outcome_value := 'waiting';
        else
          update private.operation_capacity_backlog
          set
            status = 'cancelled',
            cancelled_at = observed_at,
            updated_at = observed_at
          where operation_id = target_operation_id
            and conversation_id = target_conversation_id
            and status = 'waiting';
          insert into private.conversation_capacity_slots (
            conversation_id, organization_id, operation_id,
            admission_kind, admitted_at, last_activity_at,
            last_pedro_outbound_at, trace_id, correlation_id
          )
          values (
            target_conversation_id, state_record.organization_id,
            target_operation_id, target_admission_kind,
            observed_at, observed_at,
            conversation_record.last_pedro_outbound_at,
            request_trace_id, request_correlation_id
          );
          update public.conversations
          set
            status = 'active',
            sleeping_since = null,
            capacity_state = 'active',
            capacity_state_changed_at = observed_at
          where id = target_conversation_id;
          update private.operation_capacity_state
          set
            last_proactive_admitted_at = observed_at,
            last_proactive_effect_key = target_effect_key,
            updated_at = observed_at,
            version = version + 1
          where operation_id = target_operation_id;
          outcome_value := 'admitted';
        end if;
      elsif command_type in ('admit_inbound', 'admit_backlog')
        and (
          active_count >= 30
          or not private.is_operation_inbound_open(
            target_operation_id,
            observed_at
          )
        )
      then
        eligibility_time := private.next_operation_window_open(
          target_operation_id,
          observed_at,
          'inbound'
        );
        perform private.capacity_enqueue_waiting(
          state_record.organization_id,
          target_operation_id,
          target_conversation_id,
          target_source_message_id,
          case
            when conversation_record.status = 'sleeping'
              then 'sleeping_return'
            when target_backlog_kind in (
              'urgent_call',
              'active_reply',
              'new_inbound'
            )
              then target_backlog_kind
            else 'new_inbound'
          end,
          observed_at,
          eligibility_time,
          request_trace_id,
          request_correlation_id
        );
        update public.conversations
        set
          status = 'active',
          sleeping_since = null,
          capacity_state = 'waiting',
          capacity_state_changed_at = observed_at
        where id = target_conversation_id;
        outcome_value := 'waiting';
      elsif active_count < 30 then
        insert into private.conversation_capacity_slots (
          conversation_id, organization_id, operation_id,
          admission_kind, admitted_at, last_activity_at,
          last_pedro_outbound_at, trace_id, correlation_id
        )
        values (
          target_conversation_id, state_record.organization_id,
          target_operation_id,
          case
            when command_type = 'finalize_return'
              then 'pending_return'
            when conversation_record.status = 'sleeping'
              then 'sleeping_return'
            else coalesce(target_admission_kind, 'inbound')
          end,
          observed_at, observed_at,
          conversation_record.last_pedro_outbound_at,
          request_trace_id, request_correlation_id
        );
        update private.operation_capacity_backlog
        set
          status = 'cancelled',
          cancelled_at = observed_at,
          updated_at = observed_at
        where operation_id = target_operation_id
          and conversation_id = target_conversation_id
          and status = 'waiting';
        update public.conversations
        set
          status = 'active',
          sleeping_since = null,
          capacity_state = 'active',
          capacity_state_changed_at = observed_at
        where id = target_conversation_id;
        outcome_value := 'admitted';
      else
        -- finalize_return intentionally keeps the existing T05 pending flag.
        -- It has no T07 queue rank and is retried only by an explicit command.
        update public.conversations
        set
          capacity_state = 'excluded',
          capacity_state_changed_at = observed_at
        where id = target_conversation_id;
        outcome_value := 'pending';
      end if;
    end if;
  end if;

  state_record := private.capacity_refresh_operation_state(
    target_operation_id,
    observed_at,
    request_trace_id,
    request_correlation_id
  );

  if effect_is_new then
    insert into private.operation_capacity_effects (
      organization_id, operation_id, effect_key, conversation_id,
      command_type, outcome, trace_id, correlation_id
    )
    values (
      state_record.organization_id, target_operation_id, target_effect_key,
      target_conversation_id, command_type, outcome_value,
      request_trace_id, request_correlation_id
    );
  end if;

  return jsonb_build_object(
    'status', 'applied',
    'outcome', outcome_value,
    'conversation_id', target_conversation_id,
    'automatic_proactive_paused',
      state_record.automatic_proactive_paused,
    'manual_proactive_paused', state_record.manual_proactive_paused
  );
end;
$$;

revoke all on function private.apply_operation_capacity_command(
  uuid, uuid, text, text, text, uuid, timestamptz, text,
  uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.can_accept_ai_ownership(
  target_operation_id uuid,
  excluded_conversation_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (
    select count(*)
    from private.conversation_capacity_slots as slot
    where slot.operation_id = target_operation_id
      and slot.conversation_id <> excluded_conversation_id
  ) < 30;
$$;

revoke all on function private.can_accept_ai_ownership(uuid, uuid)
  from public, anon, authenticated, service_role;

-- T05 human commands first lock OperationCapacity, then Membership, then use
-- the capacity API to lock Slot/Backlog and Conversation before invoking the
-- preserved command body. Intermediate Conversation state is checked only by
-- the deferred aggregate constraint from slice (a).
alter function private.assume_conversation(
  uuid, bigint, uuid, uuid
) rename to assume_conversation_t07_capacity_base;

revoke all on function private.assume_conversation_t07_capacity_base(
  uuid, bigint, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.assume_conversation(
  target_conversation_id uuid,
  expected_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_operation_id uuid;
  access_record record;
  base_result jsonb;
begin
  select conversation.operation_id
  into strict target_operation_id
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  perform private.apply_operation_capacity_command(
    target_operation_id, null, 'lock_operation',
    null, null, null, now(), null, null, null,
    request_trace_id, request_correlation_id
  );
  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);
  perform private.apply_operation_capacity_command(
    target_operation_id, target_conversation_id, 'prepare_human',
    null, null, null, now(), null,
    access_record.actor_membership_id, null,
    request_trace_id, request_correlation_id
  );

  base_result := private.assume_conversation_t07_capacity_base(
    target_conversation_id,
    expected_version,
    request_trace_id,
    request_correlation_id
  );
  return base_result || jsonb_build_object(
    'capacity_state', 'excluded'
  );
end;
$$;

revoke all on function private.assume_conversation(
  uuid, bigint, uuid, uuid
) from public, anon, authenticated, service_role;

alter function private.pause_conversation(
  uuid, bigint, text, uuid, uuid
) rename to pause_conversation_t07_capacity_base;

revoke all on function private.pause_conversation_t07_capacity_base(
  uuid, bigint, text, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.pause_conversation(
  target_conversation_id uuid,
  expected_version bigint,
  pause_reason_value text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_operation_id uuid;
  access_record record;
  base_result jsonb;
begin
  select conversation.operation_id
  into strict target_operation_id
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  perform private.apply_operation_capacity_command(
    target_operation_id, null, 'lock_operation',
    null, null, null, now(), null, null, null,
    request_trace_id, request_correlation_id
  );
  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);
  perform private.apply_operation_capacity_command(
    target_operation_id, target_conversation_id, 'prepare_human',
    null, null, null, now(), null,
    access_record.actor_membership_id, pause_reason_value,
    request_trace_id, request_correlation_id
  );

  base_result := private.pause_conversation_t07_capacity_base(
    target_conversation_id,
    expected_version,
    pause_reason_value,
    request_trace_id,
    request_correlation_id
  );
  return base_result || jsonb_build_object(
    'capacity_state', 'excluded'
  );
end;
$$;

revoke all on function private.pause_conversation(
  uuid, bigint, text, uuid, uuid
) from public, anon, authenticated, service_role;

alter function private.return_conversation_to_pedro(
  uuid, bigint, text, text, uuid, uuid
) rename to return_conversation_to_pedro_t07_capacity_base;

revoke all on function
  private.return_conversation_to_pedro_t07_capacity_base(
    uuid, bigint, text, text, uuid, uuid
  )
  from public, anon, authenticated, service_role;

create function private.return_conversation_to_pedro(
  target_conversation_id uuid,
  expected_version bigint,
  target_automation_mode text,
  return_action text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_operation_id uuid;
  access_record record;
  base_result jsonb;
  capacity_result jsonb;
begin
  select conversation.operation_id
  into strict target_operation_id
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  perform private.apply_operation_capacity_command(
    target_operation_id, null, 'lock_operation',
    null, null, null, now(), null, null, null,
    request_trace_id, request_correlation_id
  );
  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);
  perform private.apply_operation_capacity_command(
    target_operation_id, target_conversation_id, 'lock_conversation',
    null, null, null, now(), null,
    access_record.actor_membership_id, null,
    request_trace_id, request_correlation_id
  );

  base_result := private.return_conversation_to_pedro_t07_capacity_base(
    target_conversation_id,
    expected_version,
    target_automation_mode,
    return_action,
    request_trace_id,
    request_correlation_id
  );
  capacity_result := private.apply_operation_capacity_command(
    target_operation_id,
    target_conversation_id,
    'finalize_return',
    'pending_return',
    null,
    null,
    now(),
    'return:' || request_correlation_id::text,
    access_record.actor_membership_id,
    null,
    request_trace_id,
    request_correlation_id
  );
  return base_result || jsonb_build_object(
    'capacity', capacity_result
  );
end;
$$;

revoke all on function private.return_conversation_to_pedro(
  uuid, bigint, text, text, uuid, uuid
) from public, anon, authenticated, service_role;

alter function private.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) rename to send_human_message_t07_capacity_base;

revoke all on function private.send_human_message_t07_capacity_base(
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
  target_operation_id uuid;
  access_record record;
  base_result jsonb;
begin
  select conversation.operation_id
  into strict target_operation_id
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  perform private.apply_operation_capacity_command(
    target_operation_id, null, 'lock_operation',
    null, null, null, now(), null, null, null,
    request_trace_id, request_correlation_id
  );
  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);
  perform private.apply_operation_capacity_command(
    target_operation_id, target_conversation_id, 'lock_conversation',
    null, null, null, now(), null,
    access_record.actor_membership_id, null,
    request_trace_id, request_correlation_id
  );

  base_result := private.send_human_message_t07_capacity_base(
    target_conversation_id,
    expected_version,
    command_id,
    message_text,
    request_trace_id,
    request_correlation_id
  );

  if base_result ->> 'status' <> 'duplicate' then
    perform private.apply_operation_capacity_command(
      target_operation_id, target_conversation_id, 'cancel_pending',
      null, null, null, now(), null,
      access_record.actor_membership_id, null,
      request_trace_id, request_correlation_id
    );
  end if;
  return base_result || jsonb_build_object(
    'capacity_state', 'excluded'
  );
end;
$$;

revoke all on function private.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

alter function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) rename to deactivate_membership_t07_capacity_base;

revoke all on function private.deactivate_membership_t07_capacity_base(
  uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.deactivate_membership_after_reauthentication(
  actor_user_id uuid,
  target_membership_id uuid,
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  future_calls bigint,
  calls_within_one_hour bigint,
  post_call_opportunities bigint,
  revoked_sessions bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  perform private.apply_operation_capacity_command(
    target_operation_id, null, 'lock_operation',
    null, null, null, now(), null, null, null,
    request_trace_id, request_correlation_id
  );

  return query
  select *
  from private.deactivate_membership_t07_capacity_base(
    actor_user_id,
    target_membership_id,
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

revoke all on function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function
  private.deactivate_membership_after_reauthentication(
    uuid, uuid, uuid, uuid, uuid
  )
  to service_role;

-- SQL functions retain dependencies by OID across ALTER ... RENAME. Rebuild
-- every public RPC explicitly so no caller can remain bound to a preserved
-- pre-capacity implementation.
create or replace function public.assume_conversation(
  target_conversation_id uuid,
  expected_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.assume_conversation(
    target_conversation_id,
    expected_version,
    request_trace_id,
    request_correlation_id
  );
$$;

create or replace function public.pause_conversation(
  target_conversation_id uuid,
  expected_version bigint,
  pause_reason text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.pause_conversation(
    target_conversation_id,
    expected_version,
    pause_reason,
    request_trace_id,
    request_correlation_id
  );
$$;

create or replace function public.return_conversation_to_pedro(
  target_conversation_id uuid,
  expected_version bigint,
  target_automation_mode text,
  return_action text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.return_conversation_to_pedro(
    target_conversation_id,
    expected_version,
    target_automation_mode,
    return_action,
    request_trace_id,
    request_correlation_id
  );
$$;

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

create or replace function
  public.deactivate_membership_after_reauthentication(
    actor_user_id uuid,
    target_membership_id uuid,
    target_operation_id uuid,
    request_trace_id uuid,
    request_correlation_id uuid
  )
returns table (
  future_calls bigint,
  calls_within_one_hour bigint,
  post_call_opportunities bigint,
  revoked_sessions bigint
)
language sql
volatile
security invoker
set search_path = ''
as $$
  select *
  from private.deactivate_membership_after_reauthentication(
    actor_user_id,
    target_membership_id,
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.assume_conversation(
  uuid, bigint, uuid, uuid
) from public, anon;
grant execute on function public.assume_conversation(
  uuid, bigint, uuid, uuid
) to authenticated;
revoke all on function public.pause_conversation(
  uuid, bigint, text, uuid, uuid
) from public, anon;
grant execute on function public.pause_conversation(
  uuid, bigint, text, uuid, uuid
) to authenticated;
revoke all on function public.return_conversation_to_pedro(
  uuid, bigint, text, text, uuid, uuid
) from public, anon;
grant execute on function public.return_conversation_to_pedro(
  uuid, bigint, text, text, uuid, uuid
) to authenticated;
revoke all on function public.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) from public, anon;
grant execute on function public.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) to authenticated;
revoke all on function
  public.deactivate_membership_after_reauthentication(
    uuid, uuid, uuid, uuid, uuid
  )
  from public, anon, authenticated, service_role;
grant execute on function
  public.deactivate_membership_after_reauthentication(
    uuid, uuid, uuid, uuid, uuid
  )
  to service_role;

-- The T06 reservation wrapper calls this preserved base. Replacing the base
-- keeps queue fencing/retry semantics while moving the capacity lock ahead of
-- every Conversation/lease lock.
create or replace function
  private.consume_inbound_whatsapp_t06_fenced_base(
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
  conversation_preexisted boolean;
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
    conversation_preexisted := false;
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
      -- Inbox/stream fencing is already held by the outer T06 reservation.
      -- Capacity must precede any Conversation lock from this point forward.
      perform private.apply_operation_capacity_command(
        inbox_record.operation_id, null, 'lock_operation',
        null, null, null, now(), null, null, null,
        inbox_record.trace_id, inbox_record.correlation_id
      );

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
        and conversation.status in ('active', 'sleeping');
      conversation_preexisted := conversation_id_value is not null;

      if conversation_id_value is not null then
        perform private.apply_operation_capacity_command(
          inbox_record.operation_id,
          conversation_id_value,
          'lock_conversation',
          null, null, null, now(), null, null, null,
          inbox_record.trace_id, inbox_record.correlation_id
        );
        select conversation.version
        into strict conversation_version
        from public.conversations as conversation
        where conversation.id = conversation_id_value;

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
        perform private.apply_operation_capacity_command(
          inbox_record.operation_id,
          conversation_id_value,
          'admit_inbound',
          'inbound',
          case
            when conversation_preexisted then 'active_reply'
            else 'new_inbound'
          end,
          (result_value ->> 'message_id')::uuid,
          now(),
          'inbound:' || (result_value ->> 'message_id'),
          null,
          null,
          inbox_record.trace_id,
          inbox_record.correlation_id
        );

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

revoke all on function
  private.consume_inbound_whatsapp_t06_fenced_base(
    integer, uuid, integer
  )
  from public, anon, authenticated, service_role;
