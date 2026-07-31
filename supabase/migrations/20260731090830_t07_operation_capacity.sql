-- T07: canonical operation capacity, backlog and Pedro response timing state.
--
-- This migration only establishes state and clock-injected policy helpers.
-- Later forward-only T07 migrations integrate the T05 ownership commands and
-- T06 durable workers after their global lock order is normalized.

alter table public.operation_settings
  add column timezone_name text not null default 'America/Sao_Paulo'
    check (char_length(timezone_name) between 1 and 100),
  add column inbound_open_minute integer not null default 300
    check (inbound_open_minute between 0 and 1439),
  add column inbound_close_minute integer not null default 1440
    check (inbound_close_minute between 1 and 1440),
  add column proactive_open_minute integer not null default 510
    check (proactive_open_minute between 0 and 1439),
  add column proactive_close_minute integer not null default 1230
    check (proactive_close_minute between 1 and 1440),
  add constraint operation_settings_inbound_window_check
    check (inbound_open_minute <= inbound_close_minute),
  add constraint operation_settings_proactive_window_check
    check (proactive_open_minute <= proactive_close_minute);

create or replace function private.validate_operation_timezone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_timezone_names as zone
    where zone.name = new.timezone_name
  ) then
    raise exception 'invalid Operation timezone'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

revoke all on function private.validate_operation_timezone()
  from public, anon, authenticated, service_role;

create trigger operation_settings_validate_timezone
before insert or update of timezone_name on public.operation_settings
for each row execute function private.validate_operation_timezone();

alter table public.conversations
  add column capacity_state text not null default 'excluded'
    check (
      capacity_state in ('active', 'waiting', 'sleeping', 'excluded')
    ),
  add column capacity_state_changed_at timestamptz not null default now(),
  add column last_pedro_outbound_at timestamptz,
  add constraint conversations_capacity_coherence_check
    check (
      capacity_state = 'excluded'
      or (
        ownership_type = 'pedro'
        and assigned_membership_id is null
        and not is_paused
        and (
          (
            capacity_state in ('active', 'waiting')
            and status = 'active'
          )
          or (
            capacity_state = 'sleeping'
            and status = 'sleeping'
          )
        )
      )
    );

create table private.operation_capacity_state (
  operation_id uuid primary key,
  organization_id uuid not null,
  automatic_proactive_paused boolean not null default false,
  manual_proactive_paused boolean not null default false,
  high_demand boolean not null default false,
  high_demand_since timestamptz,
  below_ten_since timestamptz,
  inbound_backlog_clear_since timestamptz,
  last_proactive_admitted_at timestamptz,
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, operation_id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    (high_demand and high_demand_since is not null)
    or (not high_demand and high_demand_since is null)
  )
);

create or replace function private.initialize_operation_capacity_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.operation_capacity_state (
    organization_id,
    operation_id,
    below_ten_since,
    inbound_backlog_clear_since
  )
  values (
    new.organization_id,
    new.id,
    now(),
    now()
  )
  on conflict (operation_id) do nothing;
  return new;
end;
$$;

revoke all on function private.initialize_operation_capacity_state()
  from public, anon, authenticated, service_role;

create trigger operations_initialize_capacity_state
after insert on public.operations
for each row execute function private.initialize_operation_capacity_state();

create table private.conversation_capacity_slots (
  conversation_id uuid primary key,
  organization_id uuid not null,
  operation_id uuid not null,
  admission_kind text not null
    check (
      admission_kind in (
        'inbound',
        'sleeping_return',
        'pending_return',
        'followup',
        'campaign'
      )
    ),
  admitted_at timestamptz not null,
  last_activity_at timestamptz not null,
  last_pedro_outbound_at timestamptz,
  trace_id uuid not null,
  correlation_id uuid not null,
  unique (organization_id, operation_id, conversation_id),
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade,
  check (last_activity_at >= admitted_at),
  check (
    last_pedro_outbound_at is null
    or last_pedro_outbound_at >= admitted_at
  )
);

create table private.operation_capacity_backlog (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  conversation_id uuid not null,
  source_message_id uuid references public.messages(id) on delete set null,
  backlog_kind text not null
    check (
      backlog_kind in (
        'urgent_call',
        'opt_out',
        'sleeping_return',
        'pending_return',
        'active_reply',
        'new_inbound',
        'followup',
        'campaign'
      )
    ),
  priority_class smallint not null check (priority_class between 1 and 7),
  status text not null default 'waiting'
    check (status in ('waiting', 'admitted', 'cancelled')),
  arrived_at timestamptz not null,
  eligible_at timestamptz not null,
  admitted_at timestamptz,
  cancelled_at timestamptz,
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, operation_id, id),
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade,
  check (
    (backlog_kind = 'urgent_call' and priority_class = 1)
    or (backlog_kind = 'opt_out' and priority_class = 2)
    or (
      backlog_kind in ('sleeping_return', 'pending_return')
      and priority_class = 3
    )
    or (backlog_kind = 'active_reply' and priority_class = 4)
    or (backlog_kind = 'new_inbound' and priority_class = 5)
    or (backlog_kind = 'followup' and priority_class = 6)
    or (backlog_kind = 'campaign' and priority_class = 7)
  ),
  check (
    (status = 'waiting' and admitted_at is null and cancelled_at is null)
    or (status = 'admitted' and admitted_at is not null and cancelled_at is null)
    or (status = 'cancelled' and cancelled_at is not null and admitted_at is null)
  )
);

create unique index operation_capacity_backlog_one_waiting_conversation
  on private.operation_capacity_backlog (operation_id, conversation_id)
  where status = 'waiting';

create index operation_capacity_backlog_priority_idx
  on private.operation_capacity_backlog (
    operation_id,
    priority_class,
    arrived_at,
    id
  )
  where status = 'waiting';

create index operation_capacity_backlog_eligible_idx
  on private.operation_capacity_backlog (
    operation_id,
    eligible_at,
    priority_class,
    arrived_at,
    id
  )
  where status = 'waiting';

create table private.pedro_response_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  conversation_id uuid not null,
  status text not null default 'collecting'
    check (status in ('collecting', 'delaying', 'ready', 'cancelled')),
  opened_at timestamptz not null,
  last_inbound_at timestamptz not null,
  grouping_due_at timestamptz not null,
  grouping_deadline_at timestamptz not null,
  delay_class text not null default 'normal'
    check (delay_class in ('short', 'normal', 'long')),
  delay_seconds integer
    check (delay_seconds is null or delay_seconds between 0 and 60),
  ready_at timestamptz,
  cancelled_at timestamptz,
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, operation_id, id),
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade,
  check (last_inbound_at >= opened_at),
  check (grouping_deadline_at = opened_at + interval '30 seconds'),
  check (grouping_due_at <= grouping_deadline_at),
  check (
    (status = 'collecting' and ready_at is null and cancelled_at is null)
    or (
      status = 'delaying'
      and delay_seconds is not null
      and ready_at is null
      and cancelled_at is null
    )
    or (
      status = 'ready'
      and delay_seconds is not null
      and ready_at is not null
      and cancelled_at is null
    )
    or (
      status = 'cancelled'
      and ready_at is null
      and cancelled_at is not null
    )
  )
);

create unique index pedro_response_batches_one_open_conversation
  on private.pedro_response_batches (conversation_id)
  where status in ('collecting', 'delaying');

create index pedro_response_batches_operation_status_idx
  on private.pedro_response_batches (
    operation_id,
    status,
    grouping_due_at,
    id
  );

create table private.pedro_response_batch_messages (
  batch_id uuid not null,
  message_id uuid not null,
  organization_id uuid not null,
  operation_id uuid not null,
  conversation_id uuid not null,
  observed_at timestamptz not null,
  revision integer not null default 1 check (revision > 0),
  included boolean not null default true,
  primary key (batch_id, message_id),
  foreign key (organization_id, operation_id, batch_id)
    references private.pedro_response_batches(
      organization_id,
      operation_id,
      id
    ) on delete cascade,
  foreign key (message_id)
    references public.messages(id) on delete cascade,
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade
);

alter table public.messages
  add column revision integer not null default 1 check (revision > 0),
  add column edited_at timestamptz,
  add column deleted_at timestamptz,
  add constraint messages_provider_revision_state_check
    check (
      (deleted_at is null)
      or (
        direction = 'inbound'
        and created_by_type = 'provider'
      )
    ),
  add constraint messages_provider_edited_state_check
    check (
      (edited_at is null)
      or (
        direction = 'inbound'
        and created_by_type = 'provider'
      )
    );

create table private.provider_message_revisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  connection_id uuid not null,
  provider_event_id text not null
    check (char_length(provider_event_id) between 1 and 500),
  target_message_id uuid not null,
  target_provider_message_id text not null
    check (char_length(target_provider_message_id) between 1 and 500),
  revision_kind text not null check (revision_kind in ('edit', 'delete')),
  revision_number integer not null check (revision_number > 1),
  revised_body text
    check (revised_body is null or char_length(revised_body) <= 12000),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  provider_occurred_at timestamptz not null,
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  unique (connection_id, provider_event_id),
  unique (target_message_id, revision_number),
  foreign key (organization_id, operation_id, connection_id)
    references public.whatsapp_connections(organization_id, operation_id, id)
    on delete cascade,
  foreign key (target_message_id)
    references public.messages(id) on delete cascade,
  check (provider_event_id <> target_provider_message_id),
  check (
    (revision_kind = 'edit' and revised_body is not null)
    or (revision_kind = 'delete' and revised_body is null)
  )
);

create index provider_message_revisions_target_idx
  on private.provider_message_revisions (
    target_message_id,
    revision_number,
    id
  );

create index conversation_capacity_slots_operation_idx
  on private.conversation_capacity_slots (
    operation_id,
    admitted_at,
    conversation_id
  );

create index conversations_capacity_state_idx
  on public.conversations (
    operation_id,
    capacity_state,
    capacity_state_changed_at,
    id
  )
  where status in ('active', 'sleeping');

revoke all on table private.operation_capacity_state
  from public, anon, authenticated, service_role;
revoke all on table private.conversation_capacity_slots
  from public, anon, authenticated, service_role;
revoke all on table private.operation_capacity_backlog
  from public, anon, authenticated, service_role;
revoke all on table private.pedro_response_batches
  from public, anon, authenticated, service_role;
revoke all on table private.pedro_response_batch_messages
  from public, anon, authenticated, service_role;
revoke all on table private.provider_message_revisions
  from public, anon, authenticated, service_role;

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
  select (
    extract(
      hour
      from observed_at at time zone settings.timezone_name
    )::integer * 60
    + extract(
      minute
      from observed_at at time zone settings.timezone_name
    )::integer
  )
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id;
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
  select private.operation_local_minute(
    target_operation_id,
    observed_at
  ) >= settings.inbound_open_minute
  and private.operation_local_minute(
    target_operation_id,
    observed_at
  ) < settings.inbound_close_minute
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id;
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
  select private.operation_local_minute(
    target_operation_id,
    observed_at
  ) >= settings.proactive_open_minute
  and private.operation_local_minute(
    target_operation_id,
    observed_at
  ) < settings.proactive_close_minute
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id;
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
  local_observed timestamp;
  local_minute integer;
  open_minute integer;
  close_minute integer;
  local_open timestamp;
begin
  if target_window not in ('inbound', 'proactive') then
    raise exception 'invalid Operation window' using errcode = '22023';
  end if;

  select settings.*
  into strict settings_record
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id;

  local_observed := observed_at at time zone settings_record.timezone_name;
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

  return local_open at time zone settings_record.timezone_name;
end;
$$;

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
    when 'opt_out' then 2
    when 'sleeping_return' then 3
    when 'pending_return' then 3
    when 'active_reply' then 4
    when 'new_inbound' then 5
    when 'followup' then 6
    when 'campaign' then 7
    else null
  end::smallint;
$$;

create or replace function private.capacity_delay_seconds(
  target_delay_class text,
  high_demand boolean
)
returns integer
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  if target_delay_class not in ('short', 'normal', 'long') then
    raise exception 'invalid artificial delay class'
      using errcode = '22023';
  end if;
  if high_demand then
    return 3;
  end if;
  return case target_delay_class
    when 'short' then 8
    when 'normal' then 24
    else 42
  end;
end;
$$;

revoke all on function private.operation_local_minute(uuid, timestamptz)
  from public, anon, authenticated, service_role;
revoke all on function private.is_operation_inbound_open(uuid, timestamptz)
  from public, anon, authenticated, service_role;
revoke all on function private.is_operation_proactive_open(uuid, timestamptz)
  from public, anon, authenticated, service_role;
revoke all on function private.next_operation_window_open(
  uuid, timestamptz, text
) from public, anon, authenticated, service_role;
revoke all on function private.capacity_priority_for_kind(text)
  from public, anon, authenticated, service_role;
revoke all on function private.capacity_delay_seconds(text, boolean)
  from public, anon, authenticated, service_role;

insert into private.operation_capacity_state (
  organization_id,
  operation_id,
  below_ten_since,
  inbound_backlog_clear_since
)
select
  operation.organization_id,
  operation.id,
  now(),
  now()
from public.operations as operation
on conflict (operation_id) do nothing;

with ranked_active as (
  select
    conversation.id,
    conversation.organization_id,
    conversation.operation_id,
    conversation.updated_at,
    row_number() over (
      partition by conversation.operation_id
      order by conversation.updated_at, conversation.id
    ) as capacity_rank
  from public.conversations as conversation
  where conversation.status = 'active'
    and conversation.ownership_type = 'pedro'
    and not conversation.is_paused
)
update public.conversations as conversation
set
  capacity_state = case
    when ranked.capacity_rank <= 30 then 'active'
    else 'waiting'
  end,
  capacity_state_changed_at = now()
from ranked_active as ranked
where conversation.id = ranked.id;

update public.conversations
set
  capacity_state = 'sleeping',
  capacity_state_changed_at = now()
where status = 'sleeping'
  and ownership_type = 'pedro'
  and not is_paused;

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
select
  conversation.id,
  conversation.organization_id,
  conversation.operation_id,
  'inbound',
  least(conversation.opened_at, conversation.updated_at),
  conversation.updated_at,
  conversation.last_pedro_outbound_at,
  gen_random_uuid(),
  gen_random_uuid()
from public.conversations as conversation
where conversation.capacity_state = 'active'
on conflict (conversation_id) do nothing;

insert into private.operation_capacity_backlog (
  organization_id,
  operation_id,
  conversation_id,
  backlog_kind,
  priority_class,
  arrived_at,
  eligible_at,
  trace_id,
  correlation_id
)
select
  conversation.organization_id,
  conversation.operation_id,
  conversation.id,
  'active_reply',
  4,
  conversation.updated_at,
  conversation.updated_at,
  gen_random_uuid(),
  gen_random_uuid()
from public.conversations as conversation
where conversation.capacity_state = 'waiting'
on conflict (operation_id, conversation_id)
  where status = 'waiting'
do nothing;
