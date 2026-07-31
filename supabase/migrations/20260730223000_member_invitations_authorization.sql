alter table public.memberships
  alter column role drop not null,
  add column can_receive_calls boolean not null default false,
  add column is_preferred_receiver boolean not null default false,
  add constraint memberships_active_requires_role
    check (status <> 'active' or role is not null);

update public.memberships
set can_receive_calls = true
where status = 'active'
  and role = 'broker';

create table public.membership_roles (
  membership_id uuid not null,
  organization_id uuid not null,
  role text not null check (role in ('owner', 'manager', 'broker')),
  created_at timestamptz not null default now(),
  primary key (membership_id, role),
  foreign key (organization_id, membership_id)
    references public.memberships(organization_id, id) on delete cascade
);

insert into public.membership_roles (membership_id, organization_id, role)
select id, organization_id, role
from public.memberships
where role is not null;

create or replace function private.sync_primary_membership_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.role is not null then
    insert into public.membership_roles (
      membership_id,
      organization_id,
      role
    )
    values (
      new.id,
      new.organization_id,
      new.role
    )
    on conflict (membership_id, role) do nothing;
  end if;

  return new;
end;
$$;

create trigger memberships_sync_primary_role
after insert or update of role on public.memberships
for each row execute function private.sync_primary_membership_role();

create table public.membership_permissions (
  membership_id uuid not null,
  organization_id uuid not null,
  permission text not null check (
    permission in (
      'manage_members',
      'publish_knowledge',
      'train_pedro',
      'publish_learning',
      'manage_campaigns',
      'view_financial_data',
      'export_data',
      'manage_privacy',
      'receive_urgent_call_alerts',
      'configure_operation',
      'manage_conversations'
    )
  ),
  granted_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (membership_id, permission),
  foreign key (organization_id, membership_id)
    references public.memberships(organization_id, id) on delete cascade
);

create table public.staff_profiles (
  membership_id uuid primary key,
  organization_id uuid not null,
  full_name text not null check (char_length(full_name) between 1 and 160),
  whatsapp text not null check (whatsapp ~ '^\+[1-9][0-9]{7,14}$'),
  creci text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, membership_id)
    references public.memberships(organization_id, id) on delete cascade
);

create table public.invitation_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  token uuid not null unique default gen_random_uuid(),
  status text not null default 'active'
    check (status in ('active', 'paused', 'replaced')),
  replaced_by_id uuid references public.invitation_links(id),
  created_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

create unique index invitation_links_one_active_per_organization
  on public.invitation_links (organization_id)
  where status in ('active', 'paused');

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  token uuid not null unique default gen_random_uuid(),
  email text not null check (position('@' in email) > 1),
  predefined_roles text[] not null,
  status text not null default 'active'
    check (status in ('active', 'claimed', 'revoked')),
  claimed_by_membership_id uuid,
  created_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  revoked_at timestamptz,
  version bigint not null default 1 check (version > 0),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, claimed_by_membership_id)
    references public.memberships(organization_id, id),
  check (
    cardinality(predefined_roles) > 0
    and predefined_roles <@ array['manager', 'broker']::text[]
  ),
  check (
    (status = 'active' and claimed_at is null and revoked_at is null)
    or (status = 'claimed' and claimed_at is not null and claimed_by_membership_id is not null)
    or (status = 'revoked' and revoked_at is not null)
  )
);

create unique index invitations_one_active_email_per_organization
  on public.invitations (organization_id, lower(email))
  where status = 'active';

create table private.invitation_registration_attempts (
  id bigint generated always as identity primary key,
  invitation_token uuid not null,
  request_fingerprint text not null
    check (char_length(request_fingerprint) between 32 and 128),
  attempted_at timestamptz not null default now()
);

create index invitation_registration_attempts_rate_limit_idx
  on private.invitation_registration_attempts (
    invitation_token,
    request_fingerprint,
    attempted_at desc
  );

-- These narrow foundations let member deactivation enforce its current ticket
-- contract. Later opportunity and call slices extend them without weakening
-- the eligibility and reassignment invariants established here.
create table public.opportunities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  stage text not null default 'new'
    check (
      stage in (
        'new',
        'in_service',
        'call_scheduled',
        'negotiation',
        'proposal_reservation',
        'documentation',
        'payment',
        'purchased',
        'lost'
      )
    ),
  assigned_membership_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, assigned_membership_id)
    references public.memberships(organization_id, id)
);

create table public.calls (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  opportunity_id uuid not null,
  scheduled_for timestamptz not null,
  status text not null default 'distributing'
    check (
      status in (
        'held',
        'distributing',
        'assigned',
        'scheduled',
        'completed',
        'no_show',
        'cancelled',
        'unassigned_alerted'
      )
    ),
  assigned_membership_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, opportunity_id)
    references public.opportunities(organization_id, id) on delete cascade,
  foreign key (organization_id, assigned_membership_id)
    references public.memberships(organization_id, id)
);

create table public.call_offers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  call_id uuid not null,
  recipient_membership_id uuid not null,
  status text not null default 'pending'
    check (
      status in (
        'pending',
        'accepted',
        'declined',
        'expired',
        'lost_race',
        'recipient_revoked'
      )
    ),
  sent_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (call_id, recipient_membership_id, status),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, call_id)
    references public.calls(organization_id, id) on delete cascade,
  foreign key (organization_id, recipient_membership_id)
    references public.memberships(organization_id, id)
);

create table public.call_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  call_id uuid not null,
  membership_id uuid not null,
  assigned_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoke_reason text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, call_id)
    references public.calls(organization_id, id) on delete cascade,
  foreign key (organization_id, membership_id)
    references public.memberships(organization_id, id)
);

create unique index call_assignments_one_active_per_call
  on public.call_assignments (call_id)
  where revoked_at is null;

create index membership_roles_role_idx
  on public.membership_roles (organization_id, role);
create index membership_permissions_permission_idx
  on public.membership_permissions (organization_id, permission);
create index invitations_operation_status_idx
  on public.invitations (operation_id, status, created_at desc);
create index opportunities_assigned_stage_idx
  on public.opportunities (assigned_membership_id, stage);
create index calls_assigned_scheduled_idx
  on public.calls (assigned_membership_id, scheduled_for)
  where status in ('assigned', 'scheduled');
create index call_offers_recipient_status_idx
  on public.call_offers (recipient_membership_id, status);

alter table public.membership_roles enable row level security;
alter table public.membership_permissions enable row level security;
alter table public.staff_profiles enable row level security;
alter table public.invitation_links enable row level security;
alter table public.invitations enable row level security;
alter table public.opportunities enable row level security;
alter table public.calls enable row level security;
alter table public.call_offers enable row level security;
alter table public.call_assignments enable row level security;

revoke all on table public.membership_roles from anon, authenticated;
revoke all on table public.membership_permissions from anon, authenticated;
revoke all on table public.staff_profiles from anon, authenticated;
revoke all on table public.invitation_links from anon, authenticated;
revoke all on table public.invitations from anon, authenticated;
revoke all on table public.opportunities from anon, authenticated;
revoke all on table public.calls from anon, authenticated;
revoke all on table public.call_offers from anon, authenticated;
revoke all on table public.call_assignments from anon, authenticated;
grant select on table public.membership_roles to authenticated;
grant select on table public.membership_permissions to authenticated;
grant select on table public.staff_profiles to authenticated;
grant select on table public.opportunities to authenticated;
grant select on table public.calls to authenticated;
grant select on table public.call_offers to authenticated;
grant select on table public.call_assignments to authenticated;

create or replace function private.has_membership_permission(
  target_operation_id uuid,
  target_permission text
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
      and membership_operation.operation_id = target_operation_id
      and (
        membership.role = 'owner'
        or (
          membership.role = 'manager'
          and exists (
            select 1
            from public.membership_permissions as permission
            where permission.membership_id = membership.id
              and permission.permission = target_permission
          )
        )
      )
  );
$$;

create or replace function private.actor_membership_id(
  target_operation_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select membership.id
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id
  limit 1;
$$;

create or replace function private.is_service_role()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(auth.jwt() ->> 'role' = 'service_role', false);
$$;

revoke all on function private.has_membership_permission(uuid, text) from public;
revoke all on function private.actor_membership_id(uuid) from public;
revoke all on function private.is_service_role() from public;
grant execute on function private.has_membership_permission(uuid, text)
  to authenticated;
grant execute on function private.actor_membership_id(uuid)
  to authenticated;

create policy membership_roles_select_self
  on public.membership_roles
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.memberships
      where memberships.id = membership_roles.membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
    )
  );

create policy membership_permissions_select_self
  on public.membership_permissions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.memberships
      where memberships.id = membership_permissions.membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
    )
  );

create policy staff_profiles_select_self
  on public.staff_profiles
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.memberships
      where memberships.id = staff_profiles.membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
    )
  );

create policy opportunities_select_operation_managers_or_assignee
  on public.opportunities
  for select
  to authenticated
  using (
    private.has_operation_role(operation_id, array['owner', 'manager'])
    or exists (
      select 1
      from public.memberships
      where memberships.id = opportunities.assigned_membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
        and memberships.role = 'broker'
    )
  );

create policy calls_select_operation_managers_or_assignee
  on public.calls
  for select
  to authenticated
  using (
    private.has_operation_role(operation_id, array['owner', 'manager'])
    or exists (
      select 1
      from public.memberships
      where memberships.id = calls.assigned_membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
        and memberships.role = 'broker'
    )
  );

create policy call_offers_select_operation_managers_or_recipient
  on public.call_offers
  for select
  to authenticated
  using (
    private.has_operation_role(operation_id, array['owner', 'manager'])
    or exists (
      select 1
      from public.memberships
      where memberships.id = call_offers.recipient_membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
        and memberships.role = 'broker'
    )
  );

create policy call_assignments_select_operation_managers_or_assignee
  on public.call_assignments
  for select
  to authenticated
  using (
    private.has_operation_role(operation_id, array['owner', 'manager'])
    or exists (
      select 1
      from public.memberships
      where memberships.id = call_assignments.membership_id
        and memberships.user_id = auth.uid()
        and memberships.status = 'active'
        and memberships.role = 'broker'
    )
  );

create or replace function public.create_individual_invitation(
  invite_email text,
  invite_operation_id uuid,
  invite_roles text[],
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  email text,
  predefined_roles text[],
  token uuid,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_membership public.memberships%rowtype;
  normalized_email text;
  normalized_roles text[];
  created_invitation public.invitations%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  normalized_email := lower(trim(invite_email));
  normalized_roles := array(
    select distinct role_name
    from unnest(invite_roles) as role_name
    order by role_name
  );

  if normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'invalid invitation email' using errcode = '22023';
  end if;

  if cardinality(normalized_roles) = 0
    or not normalized_roles <@ array['manager', 'broker']::text[] then
    raise exception 'invalid invitation roles' using errcode = '22023';
  end if;

  select membership.*
  into actor_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = invite_operation_id;

  if not found or not private.has_membership_permission(
    invite_operation_id,
    'manage_members'
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  if actor_membership.role = 'manager'
    and normalized_roles <> array['broker']::text[] then
    raise exception 'manager can only invite brokers' using errcode = '42501';
  end if;

  update public.invitations as invitation
  set
    status = 'revoked',
    revoked_at = now(),
    version = version + 1
  where invitation.organization_id = actor_membership.organization_id
    and lower(invitation.email) = normalized_email
    and invitation.status = 'active';

  insert into public.invitations (
    organization_id,
    operation_id,
    email,
    predefined_roles,
    created_by_user_id
  )
  values (
    actor_membership.organization_id,
    invite_operation_id,
    normalized_email,
    normalized_roles,
    auth.uid()
  )
  returning * into created_invitation;

  insert into audit.audit_events (
    organization_id,
    operation_id,
    actor_user_id,
    action,
    target_type,
    target_id,
    after_state,
    trace_id,
    correlation_id
  )
  values (
    actor_membership.organization_id,
    invite_operation_id,
    auth.uid(),
    'member.invitation.created',
    'invitation',
    created_invitation.id,
    jsonb_build_object(
      'email', normalized_email,
      'predefined_roles', normalized_roles,
      'status', 'active'
    ),
    request_trace_id,
    request_correlation_id
  );

  return query
  select
    created_invitation.id,
    created_invitation.email,
    created_invitation.predefined_roles,
    created_invitation.token,
    created_invitation.status;
end;
$$;

revoke all on function public.create_individual_invitation(
  text,
  uuid,
  text[],
  uuid,
  uuid
) from public;
grant execute on function public.create_individual_invitation(
  text,
  uuid,
  text[],
  uuid,
  uuid
) to authenticated;

create or replace function public.create_general_invitation_link(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  token uuid,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_membership public.memberships%rowtype;
  created_link public.invitation_links%rowtype;
begin
  if auth.uid() is null or not private.has_membership_permission(
    target_operation_id,
    'manage_members'
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  select membership.*
  into strict actor_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  if exists (
    select 1
    from public.invitation_links as invitation_link
    where invitation_link.organization_id = actor_membership.organization_id
      and invitation_link.status in ('active', 'paused')
  ) then
    raise exception 'active general invitation link already exists'
      using errcode = '23505';
  end if;

  insert into public.invitation_links (
    organization_id,
    operation_id,
    created_by_user_id
  )
  values (
    actor_membership.organization_id,
    target_operation_id,
    auth.uid()
  )
  returning * into created_link;

  insert into audit.audit_events (
    organization_id,
    operation_id,
    actor_user_id,
    action,
    target_type,
    target_id,
    after_state,
    trace_id,
    correlation_id
  )
  values (
    actor_membership.organization_id,
    target_operation_id,
    auth.uid(),
    'member.general_link.created',
    'invitation_link',
    created_link.id,
    jsonb_build_object('status', 'active'),
    request_trace_id,
    request_correlation_id
  );

  return query
  select created_link.id, created_link.token, created_link.status;
end;
$$;

revoke all on function public.create_general_invitation_link(uuid, uuid, uuid)
  from public;
grant execute on function public.create_general_invitation_link(uuid, uuid, uuid)
  to authenticated;

create or replace function public.set_general_invitation_link_status(
  target_link_id uuid,
  target_status text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  token uuid,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_link public.invitation_links%rowtype;
begin
  if target_status not in ('active', 'paused') then
    raise exception 'invalid general invitation link status'
      using errcode = '22023';
  end if;

  select *
  into current_link
  from public.invitation_links
  where invitation_links.id = target_link_id
  for update;

  if not found or not private.has_membership_permission(
    current_link.operation_id,
    'manage_members'
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  if current_link.status = 'replaced' then
    raise exception 'replaced link cannot be resumed' using errcode = '22023';
  end if;

  update public.invitation_links
  set
    status = target_status,
    updated_at = now(),
    version = version + 1
  where invitation_links.id = target_link_id
  returning * into current_link;

  insert into audit.audit_events (
    organization_id,
    operation_id,
    actor_user_id,
    action,
    target_type,
    target_id,
    after_state,
    trace_id,
    correlation_id
  )
  values (
    current_link.organization_id,
    current_link.operation_id,
    auth.uid(),
    'member.general_link.' || target_status,
    'invitation_link',
    current_link.id,
    jsonb_build_object('status', target_status),
    request_trace_id,
    request_correlation_id
  );

  return query
  select current_link.id, current_link.token, current_link.status;
end;
$$;

revoke all on function public.set_general_invitation_link_status(
  uuid,
  text,
  uuid,
  uuid
) from public;
grant execute on function public.set_general_invitation_link_status(
  uuid,
  text,
  uuid,
  uuid
) to authenticated;

create or replace function public.regenerate_general_invitation_link(
  target_link_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  token uuid,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_link public.invitation_links%rowtype;
  replacement_link public.invitation_links%rowtype;
begin
  select *
  into current_link
  from public.invitation_links
  where invitation_links.id = target_link_id
  for update;

  if not found or not private.has_membership_permission(
    current_link.operation_id,
    'manage_members'
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  if current_link.status = 'replaced' then
    raise exception 'link already replaced' using errcode = '22023';
  end if;

  update public.invitation_links
  set
    status = 'replaced',
    updated_at = now(),
    version = version + 1
  where invitation_links.id = target_link_id;

  insert into public.invitation_links (
    organization_id,
    operation_id,
    created_by_user_id
  )
  values (
    current_link.organization_id,
    current_link.operation_id,
    auth.uid()
  )
  returning * into replacement_link;

  update public.invitation_links
  set replaced_by_id = replacement_link.id
  where invitation_links.id = target_link_id;

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
    current_link.organization_id,
    current_link.operation_id,
    auth.uid(),
    'member.general_link.regenerated',
    'invitation_link',
    current_link.id,
    jsonb_build_object('status', current_link.status),
    jsonb_build_object(
      'status', 'replaced',
      'replacement_id', replacement_link.id
    ),
    request_trace_id,
    request_correlation_id
  );

  return query
  select replacement_link.id, replacement_link.token, replacement_link.status;
end;
$$;

revoke all on function public.regenerate_general_invitation_link(
  uuid,
  uuid,
  uuid
) from public;
grant execute on function public.regenerate_general_invitation_link(
  uuid,
  uuid,
  uuid
) to authenticated;

create or replace function public.get_invitation_entry(
  invitation_token uuid
)
returns table (
  invitation_kind text,
  organization_name text,
  link_status text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select
    'individual'::text,
    organization.name,
    invitation.status
  from public.invitations as invitation
  join public.organizations as organization
    on organization.id = invitation.organization_id
  where invitation.token = invitation_token
    and organization.status = 'active';

  if found then
    return;
  end if;

  return query
  select
    'general'::text,
    organization.name,
    invitation_link.status
  from public.invitation_links as invitation_link
  join public.organizations as organization
    on organization.id = invitation_link.organization_id
  where invitation_link.token = invitation_token
    and organization.status = 'active';
end;
$$;

revoke all on function public.get_invitation_entry(uuid) from public;
grant execute on function public.get_invitation_entry(uuid)
  to anon, authenticated;

create or replace function public.reserve_invitation_registration(
  registration_token uuid,
  registration_email text,
  registration_fingerprint text
)
returns table (
  invitation_kind text,
  organization_id uuid,
  operation_id uuid,
  predefined_roles text[]
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := lower(trim(registration_email));
  recent_attempt_count integer;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  delete from private.invitation_registration_attempts
  where attempted_at < now() - interval '24 hours';

  select count(*)::integer
  into recent_attempt_count
  from private.invitation_registration_attempts
  where invitation_token = registration_token
    and invitation_registration_attempts.request_fingerprint = registration_fingerprint
    and attempted_at >= now() - interval '15 minutes';

  if recent_attempt_count >= 5 then
    raise exception 'invitation registration rate limited'
      using errcode = 'P0001';
  end if;

  insert into private.invitation_registration_attempts (
    invitation_token,
    request_fingerprint
  )
  values (
    registration_token,
    registration_fingerprint
  );

  return query
  select
    'individual'::text,
    invitation.organization_id,
    invitation.operation_id,
    invitation.predefined_roles
  from public.invitations as invitation
  where invitation.token = registration_token
    and invitation.status = 'active'
    and lower(invitation.email) = normalized_email;

  if found then
    return;
  end if;

  return query
  select
    'general'::text,
    invitation_link.organization_id,
    invitation_link.operation_id,
    array[]::text[]
  from public.invitation_links as invitation_link
  where invitation_link.token = registration_token
    and invitation_link.status = 'active';
end;
$$;

revoke all on function public.reserve_invitation_registration(
  uuid,
  text,
  text
) from public;
grant execute on function public.reserve_invitation_registration(
  uuid,
  text,
  text
) to service_role;

create or replace function public.complete_invitation_registration(
  registration_token uuid,
  registration_user_id uuid,
  registration_email text,
  registration_full_name text,
  registration_whatsapp text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_organization_id uuid;
  target_operation_id uuid;
  target_invitation_id uuid;
  target_kind text;
  new_membership_id uuid := gen_random_uuid();
  auth_email text;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  if trim(registration_full_name) = ''
    or char_length(trim(registration_full_name)) > 160 then
    raise exception 'invalid member name' using errcode = '22023';
  end if;

  if registration_whatsapp !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'invalid member WhatsApp' using errcode = '22023';
  end if;

  select lower(email)
  into auth_email
  from auth.users
  where id = registration_user_id;

  if not found or auth_email <> lower(trim(registration_email)) then
    raise exception 'Auth identity does not match invitation registration'
      using errcode = '42501';
  end if;

  select
    invitation.id,
    invitation.organization_id,
    invitation.operation_id,
    'individual'
  into
    target_invitation_id,
    target_organization_id,
    target_operation_id,
    target_kind
  from public.invitations as invitation
  where invitation.token = registration_token
    and invitation.status = 'active'
    and lower(invitation.email) = auth_email
  for update;

  if not found then
    select
      null::uuid,
      invitation_link.organization_id,
      invitation_link.operation_id,
      'general'
    into
      target_invitation_id,
      target_organization_id,
      target_operation_id,
      target_kind
    from public.invitation_links as invitation_link
    where invitation_link.token = registration_token
      and invitation_link.status = 'active'
    for update;
  end if;

  if target_organization_id is null then
    raise exception 'invitation is not active' using errcode = 'P0002';
  end if;

  insert into public.memberships (
    id,
    organization_id,
    user_id,
    role,
    status,
    can_receive_calls
  )
  values (
    new_membership_id,
    target_organization_id,
    registration_user_id,
    null,
    'pending',
    false
  );

  insert into public.membership_operations (
    membership_id,
    organization_id,
    operation_id
  )
  values (
    new_membership_id,
    target_organization_id,
    target_operation_id
  );

  insert into public.staff_profiles (
    membership_id,
    organization_id,
    full_name,
    whatsapp
  )
  values (
    new_membership_id,
    target_organization_id,
    trim(registration_full_name),
    registration_whatsapp
  );

  if target_kind = 'individual' then
    update public.invitations
    set
      status = 'claimed',
      claimed_by_membership_id = new_membership_id,
      claimed_at = now(),
      version = version + 1
    where invitations.id = target_invitation_id;
  end if;

  insert into audit.audit_events (
    organization_id,
    operation_id,
    actor_user_id,
    action,
    target_type,
    target_id,
    after_state,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    registration_user_id,
    'member.registration.pending',
    'membership',
    new_membership_id,
    jsonb_build_object(
      'invitation_kind', target_kind,
      'status', 'pending',
      'email_confirmed', false
    ),
    request_trace_id,
    request_correlation_id
  );

  return new_membership_id;
end;
$$;

revoke all on function public.complete_invitation_registration(
  uuid,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
) from public;
grant execute on function public.complete_invitation_registration(
  uuid,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
) to service_role;

create or replace function public.approve_membership(
  target_membership_id uuid,
  target_operation_id uuid,
  approved_roles text[],
  approved_permissions text[],
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_membership public.memberships%rowtype;
  target_membership public.memberships%rowtype;
  normalized_roles text[];
  normalized_permissions text[];
  primary_role text;
  confirmed_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  normalized_roles := array(
    select distinct role_name
    from unnest(coalesce(approved_roles, array[]::text[])) as role_name
    order by role_name
  );
  normalized_permissions := array(
    select distinct permission_name
    from unnest(coalesce(approved_permissions, array[]::text[])) as permission_name
    order by permission_name
  );

  if cardinality(normalized_roles) = 0
    or not normalized_roles <@ array['manager', 'broker']::text[] then
    raise exception 'invalid approved roles' using errcode = '22023';
  end if;

  if not normalized_permissions <@ array[
    'manage_members',
    'publish_knowledge',
    'train_pedro',
    'publish_learning',
    'manage_campaigns',
    'view_financial_data',
    'export_data',
    'manage_privacy',
    'receive_urgent_call_alerts',
    'configure_operation',
    'manage_conversations'
  ]::text[] then
    raise exception 'invalid approved permissions' using errcode = '22023';
  end if;

  if cardinality(normalized_permissions) > 0
    and not ('manager' = any(normalized_roles)) then
    raise exception 'only managers receive administrative permissions'
      using errcode = '22023';
  end if;

  select membership.*
  into strict actor_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  if not private.has_membership_permission(
    target_operation_id,
    'manage_members'
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  select membership.*
  into target_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.id = target_membership_id
    and membership.organization_id = actor_membership.organization_id
    and membership.status = 'pending'
    and membership_operation.operation_id = target_operation_id
  for update;

  if not found then
    raise exception 'pending membership not found' using errcode = 'P0002';
  end if;

  if actor_membership.role = 'manager'
    and (
      normalized_roles <> array['broker']::text[]
      or cardinality(normalized_permissions) > 0
    ) then
    raise exception 'manager can only approve brokers'
      using errcode = '42501';
  end if;

  select email_confirmed_at
  into confirmed_at
  from auth.users
  where id = target_membership.user_id;

  if confirmed_at is null then
    raise exception 'member email is not confirmed' using errcode = '22023';
  end if;

  primary_role := case
    when 'manager' = any(normalized_roles) then 'manager'
    else 'broker'
  end;

  delete from public.membership_roles
  where membership_id = target_membership.id;
  delete from public.membership_permissions
  where membership_id = target_membership.id;

  update public.memberships
  set
    role = primary_role,
    status = 'active',
    can_receive_calls = 'broker' = any(normalized_roles),
    updated_at = now(),
    version = version + 1
  where id = target_membership.id;

  insert into public.membership_roles (
    membership_id,
    organization_id,
    role
  )
  select
    target_membership.id,
    target_membership.organization_id,
    role_name
  from unnest(normalized_roles) as role_name
  on conflict (membership_id, role) do nothing;

  insert into public.membership_permissions (
    membership_id,
    organization_id,
    permission,
    granted_by_user_id
  )
  select
    target_membership.id,
    target_membership.organization_id,
    permission_name,
    auth.uid()
  from unnest(normalized_permissions) as permission_name;

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
    target_membership.organization_id,
    target_operation_id,
    auth.uid(),
    'member.approved',
    'membership',
    target_membership.id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object(
      'status', 'active',
      'roles', normalized_roles,
      'permissions', normalized_permissions
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'membership_id', target_membership.id,
    'status', 'active',
    'roles', normalized_roles,
    'permissions', normalized_permissions
  );
end;
$$;

revoke all on function public.approve_membership(
  uuid,
  uuid,
  text[],
  text[],
  uuid,
  uuid
) from public;
grant execute on function public.approve_membership(
  uuid,
  uuid,
  text[],
  text[],
  uuid,
  uuid
) to authenticated;

create or replace function public.get_member_deactivation_impact(
  target_membership_id uuid,
  target_operation_id uuid
)
returns table (
  future_calls bigint,
  calls_within_one_hour bigint,
  post_call_opportunities bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_membership public.memberships%rowtype;
  target_roles text[];
begin
  if auth.uid() is null or not private.has_membership_permission(
    target_operation_id,
    'manage_members'
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  select membership.*
  into strict actor_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  select coalesce(array_agg(role order by role), array[]::text[])
  into target_roles
  from public.membership_roles
  where membership_id = target_membership_id
    and organization_id = actor_membership.organization_id;

  if 'owner' = any(target_roles)
    or (
      actor_membership.role = 'manager'
      and target_roles <> array['broker']::text[]
    ) then
    raise exception 'target member cannot be deactivated by actor'
      using errcode = '42501';
  end if;

  return query
  select
    (
      select count(*)
      from public.calls
      where calls.operation_id = target_operation_id
        and calls.assigned_membership_id = target_membership_id
        and calls.scheduled_for > now()
        and calls.status in ('assigned', 'scheduled')
    ),
    (
      select count(*)
      from public.calls
      where calls.operation_id = target_operation_id
        and calls.assigned_membership_id = target_membership_id
        and calls.scheduled_for > now()
        and calls.scheduled_for < now() + interval '1 hour'
        and calls.status in ('assigned', 'scheduled')
    ),
    (
      select count(*)
      from public.opportunities
      where opportunities.operation_id = target_operation_id
        and opportunities.assigned_membership_id = target_membership_id
        and opportunities.stage in (
          'negotiation',
          'proposal_reservation',
          'documentation',
          'payment'
        )
    );
end;
$$;

revoke all on function public.get_member_deactivation_impact(uuid, uuid)
  from public;
grant execute on function public.get_member_deactivation_impact(uuid, uuid)
  to authenticated;

create or replace function private.enforce_eligible_call_offer_recipient()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.memberships as membership
    join public.membership_roles as membership_role
      on membership_role.membership_id = membership.id
      and membership_role.role = 'broker'
    join public.membership_operations as membership_operation
      on membership_operation.membership_id = membership.id
      and membership_operation.operation_id = new.operation_id
    where membership.id = new.recipient_membership_id
      and membership.organization_id = new.organization_id
      and membership.status = 'active'
      and membership.can_receive_calls
  ) then
    raise exception 'call offer recipient is not eligible'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger call_offers_require_eligible_recipient
before insert on public.call_offers
for each row execute function private.enforce_eligible_call_offer_recipient();

create or replace function public.deactivate_membership_after_reauthentication(
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
declare
  actor_membership public.memberships%rowtype;
  target_membership public.memberships%rowtype;
  target_roles text[];
  impact_future_calls bigint;
  impact_calls_within_one_hour bigint;
  impact_post_call_opportunities bigint;
  revoked_session_count bigint;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select membership.*
  into strict actor_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = actor_user_id
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  if not (
    actor_membership.role = 'owner'
    or (
      actor_membership.role = 'manager'
      and exists (
        select 1
        from public.membership_permissions
        where membership_permissions.membership_id = actor_membership.id
          and membership_permissions.permission = 'manage_members'
      )
    )
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  select membership.*
  into target_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.id = target_membership_id
    and membership.organization_id = actor_membership.organization_id
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id
  for update;

  if not found then
    raise exception 'active membership not found' using errcode = 'P0002';
  end if;

  select coalesce(array_agg(role order by role), array[]::text[])
  into target_roles
  from public.membership_roles
  where membership_id = target_membership.id;

  if 'owner' = any(target_roles)
    or actor_membership.id = target_membership.id
    or (
      actor_membership.role = 'manager'
      and target_roles <> array['broker']::text[]
    ) then
    raise exception 'target member cannot be deactivated by actor'
      using errcode = '42501';
  end if;

  select
    count(*) filter (
      where scheduled_for > now()
        and status in ('assigned', 'scheduled')
    ),
    count(*) filter (
      where scheduled_for > now()
        and scheduled_for < now() + interval '1 hour'
        and status in ('assigned', 'scheduled')
    )
  into impact_future_calls, impact_calls_within_one_hour
  from public.calls
  where operation_id = target_operation_id
    and assigned_membership_id = target_membership.id;

  select count(*)
  into impact_post_call_opportunities
  from public.opportunities
  where operation_id = target_operation_id
    and assigned_membership_id = target_membership.id
    and stage in (
      'negotiation',
      'proposal_reservation',
      'documentation',
      'payment'
    );

  update public.memberships
  set
    status = 'revoked',
    can_receive_calls = false,
    is_preferred_receiver = false,
    updated_at = now(),
    version = version + 1
  where id = target_membership.id;

  delete from public.membership_permissions
  where membership_id = target_membership.id;

  update public.call_offers
  set
    status = 'recipient_revoked',
    updated_at = now()
  where recipient_membership_id = target_membership.id
    and status = 'pending';

  update public.call_assignments
  set
    revoked_at = now(),
    revoke_reason = 'member_deactivated'
  where membership_id = target_membership.id
    and revoked_at is null;

  update public.calls
  set
    assigned_membership_id = null,
    status = 'distributing',
    updated_at = now(),
    version = version + 1
  where operation_id = target_operation_id
    and assigned_membership_id = target_membership.id
    and scheduled_for > now()
    and status in ('assigned', 'scheduled');

  update public.opportunities
  set
    assigned_membership_id = null,
    updated_at = now(),
    version = version + 1
  where operation_id = target_operation_id
    and assigned_membership_id = target_membership.id
    and stage in (
      'negotiation',
      'proposal_reservation',
      'documentation',
      'payment'
    );

  delete from auth.sessions
  where sessions.user_id = target_membership.user_id;
  get diagnostics revoked_session_count = row_count;

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
    target_membership.organization_id,
    target_operation_id,
    actor_user_id,
    'member.deactivated',
    'membership',
    target_membership.id,
    jsonb_build_object(
      'status', target_membership.status,
      'roles', target_roles,
      'can_receive_calls', target_membership.can_receive_calls
    ),
    jsonb_build_object(
      'status', 'revoked',
      'reauthenticated', true,
      'future_calls_redistributed', impact_future_calls,
      'calls_within_one_hour', impact_calls_within_one_hour,
      'post_call_opportunities_unassigned', impact_post_call_opportunities,
      'revoked_sessions', revoked_session_count
    ),
    request_trace_id,
    request_correlation_id
  );

  return query
  select
    impact_future_calls,
    impact_calls_within_one_hour,
    impact_post_call_opportunities,
    revoked_session_count;
end;
$$;

revoke all on function public.deactivate_membership_after_reauthentication(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid
) from public;
grant execute on function public.deactivate_membership_after_reauthentication(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid
) to service_role;

create or replace function public.get_member_workspace_v2()
returns table (
  organization_id uuid,
  organization_name text,
  operation_id uuid,
  operation_name text,
  member_role text,
  member_roles text[],
  member_permissions text[],
  production_enabled boolean,
  global_pause boolean,
  can_manage_members boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    workspace.organization_id,
    workspace.organization_name,
    workspace.operation_id,
    workspace.operation_name,
    workspace.member_role,
    coalesce(
      (
        select array_agg(membership_role.role order by membership_role.role)
        from public.memberships as membership
        join public.membership_roles as membership_role
          on membership_role.membership_id = membership.id
        where membership.user_id = auth.uid()
          and membership.organization_id = workspace.organization_id
          and membership.status = 'active'
      ),
      array[]::text[]
    ),
    coalesce(
      (
        select array_agg(permission.permission order by permission.permission)
        from public.memberships as membership
        join public.membership_permissions as permission
          on permission.membership_id = membership.id
        where membership.user_id = auth.uid()
          and membership.organization_id = workspace.organization_id
          and membership.status = 'active'
      ),
      array[]::text[]
    ),
    workspace.production_enabled,
    workspace.global_pause,
    private.has_membership_permission(
      workspace.operation_id,
      'manage_members'
    )
  from private.get_member_workspace() as workspace;
$$;

revoke all on function public.get_member_workspace_v2() from public;
grant execute on function public.get_member_workspace_v2() to authenticated;

create or replace function public.get_team_management(
  target_operation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_membership public.memberships%rowtype;
  result jsonb;
begin
  if auth.uid() is null or not private.has_membership_permission(
    target_operation_id,
    'manage_members'
  ) then
    raise exception 'member management permission denied' using errcode = '42501';
  end if;

  select membership.*
  into strict actor_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  select jsonb_build_object(
    'actor', jsonb_build_object(
      'membership_id', actor_membership.id,
      'is_owner', actor_membership.role = 'owner'
    ),
    'general_link', (
      select jsonb_build_object(
        'id', invitation_link.id,
        'token', invitation_link.token,
        'status', invitation_link.status
      )
      from public.invitation_links as invitation_link
      where invitation_link.organization_id = actor_membership.organization_id
        and invitation_link.status in ('active', 'paused')
      order by invitation_link.created_at desc
      limit 1
    ),
    'invitations', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', invitation.id,
            'email', invitation.email,
            'predefined_roles', invitation.predefined_roles,
            'status', invitation.status,
            'token', invitation.token,
            'created_at', invitation.created_at
          )
          order by invitation.created_at desc
        )
        from public.invitations as invitation
        where invitation.organization_id = actor_membership.organization_id
          and invitation.operation_id = target_operation_id
          and invitation.status = 'active'
      ),
      '[]'::jsonb
    ),
    'members', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', membership.id,
            'user_id', membership.user_id,
            'email', auth_user.email,
            'email_confirmed', auth_user.email_confirmed_at is not null,
            'full_name', staff_profile.full_name,
            'whatsapp', staff_profile.whatsapp,
            'status', membership.status,
            'roles', coalesce(
              (
                select array_agg(membership_role.role order by membership_role.role)
                from public.membership_roles as membership_role
                where membership_role.membership_id = membership.id
              ),
              array[]::text[]
            ),
            'permissions', coalesce(
              (
                select array_agg(permission.permission order by permission.permission)
                from public.membership_permissions as permission
                where permission.membership_id = membership.id
              ),
              array[]::text[]
            ),
            'predefined_roles', coalesce(
              (
                select invitation.predefined_roles
                from public.invitations as invitation
                where invitation.claimed_by_membership_id = membership.id
                order by invitation.claimed_at desc
                limit 1
              ),
              array[]::text[]
            ),
            'can_receive_calls', membership.can_receive_calls,
            'is_preferred_receiver', membership.is_preferred_receiver,
            'impact', jsonb_build_object(
              'future_calls', (
                select count(*)
                from public.calls
                where calls.operation_id = target_operation_id
                  and calls.assigned_membership_id = membership.id
                  and calls.scheduled_for > now()
                  and calls.status in ('assigned', 'scheduled')
              ),
              'calls_within_one_hour', (
                select count(*)
                from public.calls
                where calls.operation_id = target_operation_id
                  and calls.assigned_membership_id = membership.id
                  and calls.scheduled_for > now()
                  and calls.scheduled_for < now() + interval '1 hour'
                  and calls.status in ('assigned', 'scheduled')
              ),
              'post_call_opportunities', (
                select count(*)
                from public.opportunities
                where opportunities.operation_id = target_operation_id
                  and opportunities.assigned_membership_id = membership.id
                  and opportunities.stage in (
                    'negotiation',
                    'proposal_reservation',
                    'documentation',
                    'payment'
                  )
              )
            )
          )
          order by
            case membership.status
              when 'pending' then 0
              when 'active' then 1
              else 2
            end,
            coalesce(staff_profile.full_name, auth_user.email)
        )
        from public.memberships as membership
        join public.membership_operations as membership_operation
          on membership_operation.membership_id = membership.id
          and membership_operation.organization_id = membership.organization_id
          and membership_operation.operation_id = target_operation_id
        join auth.users as auth_user
          on auth_user.id = membership.user_id
        left join public.staff_profiles as staff_profile
          on staff_profile.membership_id = membership.id
        where membership.organization_id = actor_membership.organization_id
      ),
      '[]'::jsonb
    )
  )
  into result;

  return result;
end;
$$;

revoke all on function public.get_team_management(uuid) from public;
grant execute on function public.get_team_management(uuid) to authenticated;

-- Keep privileged implementations in `private`; public RPCs are narrow,
-- security-invoker adapters so the exposed schema never owns elevated logic.
alter function public.create_individual_invitation(
  text,
  uuid,
  text[],
  uuid,
  uuid
) set schema private;
alter function public.create_general_invitation_link(uuid, uuid, uuid)
  set schema private;
alter function public.set_general_invitation_link_status(
  uuid,
  text,
  uuid,
  uuid
) set schema private;
alter function public.regenerate_general_invitation_link(uuid, uuid, uuid)
  set schema private;
alter function public.get_invitation_entry(uuid) set schema private;
alter function public.reserve_invitation_registration(uuid, text, text)
  set schema private;
alter function public.complete_invitation_registration(
  uuid,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
) set schema private;
alter function public.approve_membership(
  uuid,
  uuid,
  text[],
  text[],
  uuid,
  uuid
) set schema private;
alter function public.get_member_deactivation_impact(uuid, uuid)
  set schema private;
alter function public.deactivate_membership_after_reauthentication(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid
) set schema private;
alter function public.get_member_workspace_v2() set schema private;
alter function public.get_team_management(uuid) set schema private;

grant usage on schema private to anon, authenticated, service_role;

create function public.create_individual_invitation(
  invite_email text,
  invite_operation_id uuid,
  invite_roles text[],
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  email text,
  predefined_roles text[],
  token uuid,
  status text
)
language sql
volatile
security invoker
set search_path = ''
as $$
  select *
  from private.create_individual_invitation(
    invite_email,
    invite_operation_id,
    invite_roles,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.create_individual_invitation(
  text,
  uuid,
  text[],
  uuid,
  uuid
) from public;
revoke all on function private.create_individual_invitation(
  text,
  uuid,
  text[],
  uuid,
  uuid
) from public;
grant execute on function public.create_individual_invitation(
  text,
  uuid,
  text[],
  uuid,
  uuid
) to authenticated;
grant execute on function private.create_individual_invitation(
  text,
  uuid,
  text[],
  uuid,
  uuid
) to authenticated;

create function public.create_general_invitation_link(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  token uuid,
  status text
)
language sql
volatile
security invoker
set search_path = ''
as $$
  select *
  from private.create_general_invitation_link(
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.create_general_invitation_link(uuid, uuid, uuid)
  from public;
revoke all on function private.create_general_invitation_link(uuid, uuid, uuid)
  from public;
grant execute on function public.create_general_invitation_link(uuid, uuid, uuid)
  to authenticated;
grant execute on function private.create_general_invitation_link(uuid, uuid, uuid)
  to authenticated;

create function public.set_general_invitation_link_status(
  target_link_id uuid,
  target_status text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  token uuid,
  status text
)
language sql
volatile
security invoker
set search_path = ''
as $$
  select *
  from private.set_general_invitation_link_status(
    target_link_id,
    target_status,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.set_general_invitation_link_status(
  uuid,
  text,
  uuid,
  uuid
) from public;
revoke all on function private.set_general_invitation_link_status(
  uuid,
  text,
  uuid,
  uuid
) from public;
grant execute on function public.set_general_invitation_link_status(
  uuid,
  text,
  uuid,
  uuid
) to authenticated;
grant execute on function private.set_general_invitation_link_status(
  uuid,
  text,
  uuid,
  uuid
) to authenticated;

create function public.regenerate_general_invitation_link(
  target_link_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns table (
  id uuid,
  token uuid,
  status text
)
language sql
volatile
security invoker
set search_path = ''
as $$
  select *
  from private.regenerate_general_invitation_link(
    target_link_id,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.regenerate_general_invitation_link(
  uuid,
  uuid,
  uuid
) from public;
revoke all on function private.regenerate_general_invitation_link(
  uuid,
  uuid,
  uuid
) from public;
grant execute on function public.regenerate_general_invitation_link(
  uuid,
  uuid,
  uuid
) to authenticated;
grant execute on function private.regenerate_general_invitation_link(
  uuid,
  uuid,
  uuid
) to authenticated;

create function public.get_invitation_entry(
  invitation_token uuid
)
returns table (
  invitation_kind text,
  organization_name text,
  link_status text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.get_invitation_entry(invitation_token);
$$;

revoke all on function public.get_invitation_entry(uuid) from public;
revoke all on function private.get_invitation_entry(uuid) from public;
grant execute on function public.get_invitation_entry(uuid)
  to anon, authenticated;
grant execute on function private.get_invitation_entry(uuid)
  to anon, authenticated;

create function public.reserve_invitation_registration(
  registration_token uuid,
  registration_email text,
  request_fingerprint text
)
returns table (
  invitation_kind text,
  organization_id uuid,
  operation_id uuid,
  predefined_roles text[]
)
language sql
volatile
security invoker
set search_path = ''
as $$
  select *
  from private.reserve_invitation_registration(
    registration_token,
    registration_email,
    request_fingerprint
  );
$$;

revoke all on function public.reserve_invitation_registration(
  uuid,
  text,
  text
) from public;
revoke all on function private.reserve_invitation_registration(
  uuid,
  text,
  text
) from public;
grant execute on function public.reserve_invitation_registration(
  uuid,
  text,
  text
) to service_role;
grant execute on function private.reserve_invitation_registration(
  uuid,
  text,
  text
) to service_role;

create function public.complete_invitation_registration(
  registration_token uuid,
  registration_user_id uuid,
  registration_email text,
  registration_full_name text,
  registration_whatsapp text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns uuid
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.complete_invitation_registration(
    registration_token,
    registration_user_id,
    registration_email,
    registration_full_name,
    registration_whatsapp,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.complete_invitation_registration(
  uuid,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
) from public;
revoke all on function private.complete_invitation_registration(
  uuid,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
) from public;
grant execute on function public.complete_invitation_registration(
  uuid,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
) to service_role;
grant execute on function private.complete_invitation_registration(
  uuid,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
) to service_role;

create function public.approve_membership(
  target_membership_id uuid,
  target_operation_id uuid,
  approved_roles text[],
  approved_permissions text[],
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.approve_membership(
    target_membership_id,
    target_operation_id,
    approved_roles,
    approved_permissions,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.approve_membership(
  uuid,
  uuid,
  text[],
  text[],
  uuid,
  uuid
) from public;
revoke all on function private.approve_membership(
  uuid,
  uuid,
  text[],
  text[],
  uuid,
  uuid
) from public;
grant execute on function public.approve_membership(
  uuid,
  uuid,
  text[],
  text[],
  uuid,
  uuid
) to authenticated;
grant execute on function private.approve_membership(
  uuid,
  uuid,
  text[],
  text[],
  uuid,
  uuid
) to authenticated;

create function public.get_member_deactivation_impact(
  target_membership_id uuid,
  target_operation_id uuid
)
returns table (
  future_calls bigint,
  calls_within_one_hour bigint,
  post_call_opportunities bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select *
  from private.get_member_deactivation_impact(
    target_membership_id,
    target_operation_id
  );
$$;

revoke all on function public.get_member_deactivation_impact(uuid, uuid)
  from public;
revoke all on function private.get_member_deactivation_impact(uuid, uuid)
  from public;
grant execute on function public.get_member_deactivation_impact(uuid, uuid)
  to authenticated;
grant execute on function private.get_member_deactivation_impact(uuid, uuid)
  to authenticated;

create function public.deactivate_membership_after_reauthentication(
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

revoke all on function public.deactivate_membership_after_reauthentication(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid
) from public;
revoke all on function private.deactivate_membership_after_reauthentication(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid
) from public;
grant execute on function public.deactivate_membership_after_reauthentication(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid
) to service_role;
grant execute on function private.deactivate_membership_after_reauthentication(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid
) to service_role;

create function public.get_member_workspace_v2()
returns table (
  organization_id uuid,
  organization_name text,
  operation_id uuid,
  operation_name text,
  member_role text,
  member_roles text[],
  member_permissions text[],
  production_enabled boolean,
  global_pause boolean,
  can_manage_members boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.get_member_workspace_v2();
$$;

revoke all on function public.get_member_workspace_v2() from public;
revoke all on function private.get_member_workspace_v2() from public;
grant execute on function public.get_member_workspace_v2() to authenticated;
grant execute on function private.get_member_workspace_v2() to authenticated;

create function public.get_team_management(
  target_operation_id uuid
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_team_management(target_operation_id);
$$;

revoke all on function public.get_team_management(uuid) from public;
revoke all on function private.get_team_management(uuid) from public;
grant execute on function public.get_team_management(uuid) to authenticated;
grant execute on function private.get_team_management(uuid) to authenticated;
