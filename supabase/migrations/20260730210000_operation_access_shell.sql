create schema if not exists private;
create schema if not exists audit;

revoke all on schema private from public;
revoke all on schema audit from public;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 160),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  timezone text not null default 'America/Sao_Paulo',
  status text not null default 'active'
    check (status in ('active', 'suspended', 'closed')),
  created_at timestamptz not null default now()
);

create table public.operations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null check (char_length(name) between 1 and 160),
  timezone text not null default 'America/Sao_Paulo',
  status text not null default 'active'
    check (status in ('active', 'suspended', 'closed')),
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, id)
);

create unique index operations_one_default_per_organization
  on public.operations (organization_id)
  where is_default;

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'manager', 'broker')),
  status text not null default 'pending'
    check (status in ('pending', 'active', 'suspended', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, user_id),
  unique (organization_id, id)
);

create unique index memberships_one_owner_per_organization
  on public.memberships (organization_id)
  where role = 'owner' and status = 'active';

create table public.membership_operations (
  membership_id uuid not null,
  organization_id uuid not null,
  operation_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (membership_id, operation_id),
  foreign key (organization_id, membership_id)
    references public.memberships(organization_id, id) on delete cascade,
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

create table public.operation_settings (
  operation_id uuid primary key references public.operations(id) on delete cascade,
  organization_id uuid not null,
  production_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

create table public.system_pauses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  scope text not null default 'operation'
    check (scope = 'operation'),
  status text not null default 'active'
    check (status in ('active', 'resolved')),
  reason text not null check (char_length(reason) between 1 and 500),
  origin text not null default 'manual'
    check (origin in ('manual', 'automatic')),
  activated_by uuid not null references auth.users(id),
  activated_at timestamptz not null default now(),
  resolved_at timestamptz,
  trace_id uuid not null,
  correlation_id uuid not null,
  version bigint not null default 1 check (version > 0),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    (status = 'active' and resolved_at is null)
    or (status = 'resolved' and resolved_at is not null)
  )
);

create unique index system_pauses_one_active_per_operation
  on public.system_pauses (operation_id)
  where status = 'active';

create table audit.audit_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid,
  actor_user_id uuid,
  action text not null,
  target_type text not null,
  target_id uuid,
  before_state jsonb,
  after_state jsonb,
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now()
);

create index memberships_user_id_idx
  on public.memberships (user_id);
create index membership_operations_operation_id_idx
  on public.membership_operations (operation_id);
create index audit_events_operation_created_at_idx
  on audit.audit_events (operation_id, created_at desc);

alter table public.organizations enable row level security;
alter table public.operations enable row level security;
alter table public.memberships enable row level security;
alter table public.membership_operations enable row level security;
alter table public.operation_settings enable row level security;
alter table public.system_pauses enable row level security;

revoke all on table public.organizations from anon, authenticated;
revoke all on table public.operations from anon, authenticated;
revoke all on table public.memberships from anon, authenticated;
revoke all on table public.membership_operations from anon, authenticated;
revoke all on table public.operation_settings from anon, authenticated;
revoke all on table public.system_pauses from anon, authenticated;
grant select on table public.organizations to authenticated;
grant select on table public.operations to authenticated;
grant select on table public.memberships to authenticated;
grant select on table public.membership_operations to authenticated;
grant select on table public.operation_settings to authenticated;
grant select on table public.system_pauses to authenticated;

create or replace function private.has_active_membership(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships
    where organization_id = target_organization_id
      and user_id = auth.uid()
      and status = 'active'
  );
$$;

create or replace function private.has_operation_access(target_operation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships as membership
    join public.membership_operations as membership_operation
      on membership_operation.membership_id = membership.id
      and membership_operation.organization_id = membership.organization_id
    where membership.user_id = auth.uid()
      and membership.status = 'active'
      and membership_operation.operation_id = target_operation_id
  );
$$;

create or replace function private.has_operation_role(
  target_operation_id uuid,
  allowed_roles text[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships as membership
    join public.membership_operations as membership_operation
      on membership_operation.membership_id = membership.id
      and membership_operation.organization_id = membership.organization_id
    where membership.user_id = auth.uid()
      and membership.status = 'active'
      and membership.role = any (allowed_roles)
      and membership_operation.operation_id = target_operation_id
  );
$$;

create or replace function private.get_member_workspace()
returns table (
  organization_id uuid,
  organization_name text,
  operation_id uuid,
  operation_name text,
  member_role text,
  production_enabled boolean,
  global_pause boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    organization.id,
    organization.name,
    operation.id,
    operation.name,
    membership.role,
    settings.production_enabled,
    exists (
      select 1
      from public.system_pauses as pause
      where pause.operation_id = operation.id
        and pause.status = 'active'
    )
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  join public.organizations as organization
    on organization.id = membership.organization_id
  join public.operations as operation
    on operation.id = membership_operation.operation_id
    and operation.organization_id = membership.organization_id
  join public.operation_settings as settings
    on settings.operation_id = operation.id
    and settings.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and organization.status = 'active'
    and operation.status = 'active'
  order by operation.is_default desc, operation.created_at asc
  limit 1;
$$;

revoke all on function private.has_active_membership(uuid) from public;
revoke all on function private.has_operation_access(uuid) from public;
revoke all on function private.has_operation_role(uuid, text[]) from public;
revoke all on function private.get_member_workspace() from public;
grant usage on schema private to authenticated;
grant execute on function private.has_active_membership(uuid) to authenticated;
grant execute on function private.has_operation_access(uuid) to authenticated;
grant execute on function private.has_operation_role(uuid, text[]) to authenticated;
grant execute on function private.get_member_workspace() to authenticated;

create policy organizations_select_active_members
  on public.organizations
  for select
  to authenticated
  using (private.has_active_membership(id));

create policy operations_select_operation_members
  on public.operations
  for select
  to authenticated
  using (private.has_operation_access(id));

create policy memberships_select_self
  on public.memberships
  for select
  to authenticated
  using (user_id = auth.uid() and status = 'active');

create policy membership_operations_select_self
  on public.membership_operations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.memberships
      where memberships.id = membership_operations.membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
    )
  );

create policy operation_settings_select_operation_managers
  on public.operation_settings
  for select
  to authenticated
  using (
    private.has_operation_role(
      operation_id,
      array['owner', 'manager']
    )
  );

create policy system_pauses_select_operation_managers
  on public.system_pauses
  for select
  to authenticated
  using (
    private.has_operation_role(
      operation_id,
      array['owner', 'manager']
    )
  );

create or replace function public.get_operation_shell()
returns table (
  organization_id uuid,
  organization_name text,
  operation_id uuid,
  operation_name text,
  member_role text,
  production_enabled boolean,
  global_pause boolean,
  can_use_kill_switch boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    workspace.organization_id,
    workspace.organization_name,
    workspace.operation_id,
    workspace.operation_name,
    workspace.member_role,
    workspace.production_enabled,
    workspace.global_pause,
    true
  from private.get_member_workspace() as workspace
  where workspace.member_role in ('owner', 'manager');
$$;

revoke all on function public.get_operation_shell() from public;
grant execute on function public.get_operation_shell() to authenticated;

create or replace function public.get_member_workspace()
returns table (
  organization_id uuid,
  organization_name text,
  operation_id uuid,
  operation_name text,
  member_role text,
  production_enabled boolean,
  global_pause boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.get_member_workspace();
$$;

revoke all on function public.get_member_workspace() from public;
grant execute on function public.get_member_workspace() to authenticated;

create or replace function private.activate_global_pause(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  production_enabled boolean,
  global_pause boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_settings public.operation_settings%rowtype;
  active_pause_id uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not private.has_operation_role(
    target_operation_id,
    array['owner', 'manager']
  ) then
    raise exception 'operation permission denied' using errcode = '42501';
  end if;

  select *
  into current_settings
  from public.operation_settings
  where operation_id = target_operation_id
  for update;

  if not found then
    raise exception 'operation settings not found' using errcode = 'P0002';
  end if;

  select pause.id
  into active_pause_id
  from public.system_pauses as pause
  where pause.operation_id = target_operation_id
    and pause.status = 'active'
  for update;

  if active_pause_id is null then
    update public.operation_settings
    set
      production_enabled = false,
      updated_at = now(),
      version = version + 1
    where operation_id = target_operation_id;

    insert into public.system_pauses (
      organization_id,
      operation_id,
      reason,
      origin,
      activated_by,
      trace_id,
      correlation_id
    )
    values (
      current_settings.organization_id,
      current_settings.operation_id,
      'Kill switch acionado pela interface',
      'manual',
      auth.uid(),
      request_trace_id,
      request_correlation_id
    )
    returning id into active_pause_id;

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
      current_settings.organization_id,
      current_settings.operation_id,
      auth.uid(),
      'pedro.global_pause.activated',
      'system_pause',
      active_pause_id,
      jsonb_build_object(
        'production_enabled', current_settings.production_enabled,
        'global_pause', false
      ),
      jsonb_build_object(
        'production_enabled', false,
        'global_pause', true
      ),
      request_trace_id,
      request_correlation_id
    );
  end if;

  return query
  select
    settings.production_enabled,
    exists (
      select 1
      from public.system_pauses as pause
      where pause.operation_id = settings.operation_id
        and pause.status = 'active'
    )
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id;
end;
$$;

revoke all on function private.activate_global_pause(uuid, uuid, uuid)
  from public;
grant execute on function private.activate_global_pause(uuid, uuid, uuid)
  to authenticated;

create or replace function public.activate_global_pause(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  production_enabled boolean,
  global_pause boolean
)
language sql
volatile
security invoker
set search_path = ''
as $$
  select *
  from private.activate_global_pause(
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.activate_global_pause(uuid, uuid, uuid) from public;
grant execute on function public.activate_global_pause(uuid, uuid, uuid)
  to authenticated;
