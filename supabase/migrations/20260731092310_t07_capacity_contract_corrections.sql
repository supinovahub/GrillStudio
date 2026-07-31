-- T07 repair slice (a): forward-only corrections for the state established
-- by 20260731090830_t07_operation_capacity.sql.
--
-- This slice deliberately does not connect T05/T06 writers yet. It makes the
-- canonical timezone, tenant bindings, FIFO identity and deferred aggregate
-- coherence precise so the next slice can expose one mutation API.

-- public.operations.timezone predates T07 and remains the only canonical
-- Operation timezone. The duplicate settings column contained only a copy.
drop trigger operation_settings_validate_timezone
  on public.operation_settings;

create or replace function private.validate_operation_timezone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.timezone is null
    or not exists (
      select 1
      from pg_catalog.pg_timezone_names as zone
      where zone.name = new.timezone
    )
  then
    raise exception 'invalid Operation timezone'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger operations_validate_timezone
before insert or update of timezone on public.operations
for each row execute function private.validate_operation_timezone();

alter table public.operation_settings
  drop constraint operation_settings_inbound_window_check,
  drop constraint operation_settings_proactive_window_check,
  add constraint operation_settings_inbound_window_check
    check (inbound_open_minute < inbound_close_minute),
  add constraint operation_settings_proactive_window_check
    check (proactive_open_minute < proactive_close_minute);

create or replace function private.operation_local_minute(
  target_operation_id uuid,
  observed_at timestamptz
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when target_operation_id is null or observed_at is null then null
    else (
      extract(
        hour
        from observed_at at time zone operation.timezone
      )::integer * 60
      + extract(
        minute
        from observed_at at time zone operation.timezone
      )::integer
    )
  end
  from public.operations as operation
  where operation.id = target_operation_id;
$$;

create or replace function private.is_operation_inbound_open(
  target_operation_id uuid,
  observed_at timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select
        private.operation_local_minute(
          target_operation_id,
          observed_at
        ) >= settings.inbound_open_minute
        and private.operation_local_minute(
          target_operation_id,
          observed_at
        ) < settings.inbound_close_minute
      from public.operation_settings as settings
      where settings.operation_id = target_operation_id
    ),
    false
  );
$$;

create or replace function private.is_operation_proactive_open(
  target_operation_id uuid,
  observed_at timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select
        private.operation_local_minute(
          target_operation_id,
          observed_at
        ) >= settings.proactive_open_minute
        and private.operation_local_minute(
          target_operation_id,
          observed_at
        ) < settings.proactive_close_minute
      from public.operation_settings as settings
      where settings.operation_id = target_operation_id
    ),
    false
  );
$$;

create or replace function private.next_operation_window_open(
  target_operation_id uuid,
  observed_at timestamptz,
  target_window text
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  settings_record public.operation_settings%rowtype;
  operation_timezone text;
  local_observed timestamp;
  local_minute integer;
  open_minute integer;
  close_minute integer;
  local_open timestamp;
begin
  if target_operation_id is null
    or observed_at is null
    or target_window is null
  then
    return null;
  end if;
  if target_window not in ('inbound', 'proactive') then
    raise exception 'invalid Operation window' using errcode = '22023';
  end if;

  select settings.*
  into strict settings_record
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id;

  select operation.timezone
  into strict operation_timezone
  from public.operations as operation
  where operation.id = target_operation_id;

  local_observed := observed_at at time zone operation_timezone;
  local_minute :=
    extract(hour from local_observed)::integer * 60
    + extract(minute from local_observed)::integer;
  open_minute := case
    when target_window = 'inbound'
      then settings_record.inbound_open_minute
    else settings_record.proactive_open_minute
  end;
  close_minute := case
    when target_window = 'inbound'
      then settings_record.inbound_close_minute
    else settings_record.proactive_close_minute
  end;

  if local_minute >= open_minute and local_minute < close_minute then
    return observed_at;
  end if;

  local_open := date_trunc('day', local_observed)
    + case
      when local_minute < open_minute then interval '0 days'
      else interval '1 day'
    end
    + make_interval(mins => open_minute);

  return local_open at time zone operation_timezone;
end;
$$;

alter table public.operation_settings
  drop column timezone_name;

comment on column public.operations.timezone is
  'Canonical IANA timezone for the Operation and all T07 window decisions.';

-- Every cross-aggregate reference carries the tenant and parent identity.
alter table public.messages
  add constraint messages_organization_operation_conversation_id_key
    unique (organization_id, operation_id, conversation_id, id),
  add constraint messages_provider_target_identity_key
    unique (
      organization_id,
      operation_id,
      connection_id,
      id,
      provider_message_id
    );

alter table private.pedro_response_batches
  add constraint pedro_response_batches_tenant_conversation_id_key
    unique (organization_id, operation_id, conversation_id, id);

alter table private.operation_capacity_backlog
  drop constraint operation_capacity_backlog_source_message_id_fkey,
  add constraint operation_capacity_backlog_source_message_tenant_fkey
    foreign key (
      organization_id,
      operation_id,
      conversation_id,
      source_message_id
    )
    references public.messages(
      organization_id,
      operation_id,
      conversation_id,
      id
    )
    on delete set null (source_message_id);

alter table private.pedro_response_batch_messages
  drop constraint pedro_response_batch_messages_message_id_fkey,
  drop constraint
    pedro_response_batch_messages_organization_id_operation_id_fkey,
  add constraint pedro_response_batch_messages_batch_tenant_fkey
    foreign key (
      organization_id,
      operation_id,
      conversation_id,
      batch_id
    )
    references private.pedro_response_batches(
      organization_id,
      operation_id,
      conversation_id,
      id
    )
    on delete cascade,
  add constraint pedro_response_batch_messages_message_tenant_fkey
    foreign key (
      organization_id,
      operation_id,
      conversation_id,
      message_id
    )
    references public.messages(
      organization_id,
      operation_id,
      conversation_id,
      id
    )
    on delete cascade;

alter table private.provider_message_revisions
  drop constraint provider_message_revisions_target_message_id_fkey,
  drop constraint provider_message_revisions_check,
  add constraint provider_message_revisions_target_message_tenant_fkey
    foreign key (
      organization_id,
      operation_id,
      connection_id,
      target_message_id,
      target_provider_message_id
    )
    references public.messages(
      organization_id,
      operation_id,
      connection_id,
      id,
      provider_message_id
    )
    on delete cascade;

create index operation_capacity_backlog_source_message_tenant_idx
  on private.operation_capacity_backlog (
    organization_id,
    operation_id,
    conversation_id,
    source_message_id
  )
  where source_message_id is not null;

create index pedro_response_batch_messages_message_tenant_idx
  on private.pedro_response_batch_messages (
    organization_id,
    operation_id,
    conversation_id,
    message_id
  );

create index provider_message_revisions_target_message_tenant_idx
  on private.provider_message_revisions (
    organization_id,
    operation_id,
    connection_id,
    target_message_id,
    target_provider_message_id
  );

-- FIFO is an Operation-local sequence allocated while OperationCapacity is
-- locked. Wall-clock ties and UUID ordering never decide queue order.
alter table private.operation_capacity_state
  add column last_backlog_sequence bigint not null default 0
    check (last_backlog_sequence >= 0);

alter table private.operation_capacity_backlog
  add column fifo_sequence bigint;

with sequenced as (
  select
    backlog.id,
    row_number() over (
      partition by backlog.operation_id
      order by backlog.arrived_at, backlog.created_at, backlog.id
    )::bigint as fifo_sequence
  from private.operation_capacity_backlog as backlog
)
update private.operation_capacity_backlog as backlog
set fifo_sequence = sequenced.fifo_sequence
from sequenced
where sequenced.id = backlog.id;

update private.operation_capacity_state as state
set last_backlog_sequence = sequence.maximum_sequence
from (
  select
    backlog.operation_id,
    max(backlog.fifo_sequence) as maximum_sequence
  from private.operation_capacity_backlog as backlog
  group by backlog.operation_id
) as sequence
where sequence.operation_id = state.operation_id;

alter table private.operation_capacity_backlog
  alter column fifo_sequence set not null,
  add constraint operation_capacity_backlog_operation_fifo_key
    unique (operation_id, fifo_sequence);

drop index private.operation_capacity_backlog_priority_idx;
drop index private.operation_capacity_backlog_eligible_idx;

create index operation_capacity_backlog_priority_idx
  on private.operation_capacity_backlog (
    operation_id,
    priority_class,
    fifo_sequence
  )
  where status = 'waiting';

create index operation_capacity_backlog_eligible_idx
  on private.operation_capacity_backlog (
    operation_id,
    eligible_at,
    priority_class,
    fifo_sequence
  )
  where status = 'waiting';

create index operation_capacity_backlog_oldest_delayed_inbound_idx
  on private.operation_capacity_backlog (
    operation_id,
    eligible_at,
    fifo_sequence
  )
  where status = 'waiting'
    and backlog_kind in (
      'urgent_call',
      'sleeping_return',
      'active_reply',
      'new_inbound'
    );

-- opt_out is an immediate safety command and can never wait for capacity.
-- pending_return retains the T05 owner-held pending state but is not assigned
-- an unapproved T07 queue rank.
do $$
begin
  if exists (
    select 1
    from private.operation_capacity_backlog
    where backlog_kind in ('opt_out', 'pending_return')
  ) then
    raise exception
      'cannot remove unapproved backlog kinds while rows still exist'
      using errcode = '23514';
  end if;
end;
$$;

alter table private.operation_capacity_backlog
  drop constraint operation_capacity_backlog_backlog_kind_check,
  drop constraint operation_capacity_backlog_check,
  add constraint operation_capacity_backlog_backlog_kind_check
    check (
      backlog_kind in (
        'urgent_call',
        'sleeping_return',
        'active_reply',
        'new_inbound',
        'followup',
        'campaign'
      )
    ),
  add constraint operation_capacity_backlog_priority_policy_check
    check (
      (backlog_kind = 'urgent_call' and priority_class = 1)
      or (backlog_kind = 'sleeping_return' and priority_class = 3)
      or (backlog_kind = 'active_reply' and priority_class = 4)
      or (backlog_kind = 'new_inbound' and priority_class = 5)
      or (backlog_kind = 'followup' and priority_class = 6)
      or (backlog_kind = 'campaign' and priority_class = 7)
    );

create or replace function private.capacity_priority_for_kind(
  target_kind text
)
returns smallint
language sql
immutable
security invoker
set search_path = ''
as $$
  select case target_kind
    when 'urgent_call' then 1
    when 'sleeping_return' then 3
    when 'active_reply' then 4
    when 'new_inbound' then 5
    when 'followup' then 6
    when 'campaign' then 7
    else null
  end::smallint;
$$;

-- CHECK constraints are immediate in Postgres. T05 commands legitimately
-- change Conversation ownership before their T07 slot/backlog cleanup in the
-- same transaction, so validate the aggregate only at transaction end.
alter table public.conversations
  drop constraint conversations_capacity_coherence_check;

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
    if slot_count <> 0 then
      raise exception 'excluded Conversation cannot hold capacity slot'
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

revoke all on function private.assert_conversation_capacity_coherence(uuid)
  from public, anon, authenticated, service_role;

create or replace function
  private.enforce_conversation_capacity_coherence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_conversation_capacity_coherence(
    case
      when tg_op = 'DELETE' then old.conversation_id
      else new.conversation_id
    end
  );
  return null;
end;
$$;

revoke all on function
  private.enforce_conversation_capacity_coherence()
  from public, anon, authenticated, service_role;

create or replace function
  private.enforce_conversation_row_capacity_coherence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_conversation_capacity_coherence(
    case when tg_op = 'DELETE' then old.id else new.id end
  );
  return null;
end;
$$;

revoke all on function
  private.enforce_conversation_row_capacity_coherence()
  from public, anon, authenticated, service_role;

create constraint trigger conversations_capacity_coherence
after insert or update
on public.conversations
deferrable initially deferred
for each row execute function
  private.enforce_conversation_row_capacity_coherence();

create constraint trigger conversation_capacity_slots_coherence
after insert or update or delete
on private.conversation_capacity_slots
deferrable initially deferred
for each row execute function
  private.enforce_conversation_capacity_coherence();

create constraint trigger operation_capacity_backlog_coherence
after insert or update or delete
on private.operation_capacity_backlog
deferrable initially deferred
for each row execute function
  private.enforce_conversation_capacity_coherence();
