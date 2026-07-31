-- T04: Contact identity, opportunities and the fixed commercial pipeline.
-- Existing opportunities are extended because T02 already depends on
-- `stage` and `assigned_membership_id`.

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  display_name text check (
    display_name is null or char_length(display_name) between 1 and 160
  ),
  status text not null default 'active'
    check (status in ('active', 'merged')),
  merged_into_contact_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, id),
  foreign key (organization_id, merged_into_contact_id)
    references public.contacts(organization_id, id),
  check (
    (status = 'active' and merged_into_contact_id is null)
    or (
      status = 'merged'
      and merged_into_contact_id is not null
      and merged_into_contact_id <> id
    )
  )
);

create table public.contact_phones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  contact_id uuid not null,
  e164 text not null check (e164 ~ '^\+[1-9][0-9]{7,14}$'),
  original_value text not null check (char_length(original_value) between 1 and 80),
  is_primary boolean not null default false,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, e164),
  unique (organization_id, id),
  foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id) on delete cascade
);

create unique index contact_phones_one_primary_per_contact
  on public.contact_phones (contact_id)
  where is_primary;

create table public.contact_phone_observations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  contact_id uuid not null,
  contact_phone_id uuid not null,
  original_value text not null check (char_length(original_value) between 1 and 80),
  source_type text not null check (char_length(source_type) between 1 and 80),
  observed_at timestamptz not null default now(),
  foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id) on delete cascade,
  foreign key (organization_id, contact_phone_id)
    references public.contact_phones(organization_id, id) on delete cascade
);

alter table public.opportunities
  add column contact_id uuid,
  add column source_type text not null default 'manual'
    check (char_length(source_type) between 1 and 80),
  add column unit_count integer not null default 1
    check (unit_count between 1 and 100),
  add column amount_scope text not null default 'total'
    check (amount_scope in ('total', 'per_unit')),
  add column pedro_context text
    check (pedro_context is null or char_length(pedro_context) <= 4000),
  add column loss_reason text,
  add constraint opportunities_organization_contact_fkey
    foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id);

alter table public.opportunities
  alter column contact_id set not null;

alter table public.opportunities
  drop constraint opportunities_stage_check;

alter table public.opportunities
  add constraint opportunities_stage_check
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
  add constraint opportunities_loss_reason_length_check
    check (
      loss_reason is null
      or char_length(loss_reason) between 1 and 500
    ),
  add constraint opportunities_loss_reason_check
    check (
      (stage = 'lost' and loss_reason is not null)
      or (stage <> 'lost' and loss_reason is null)
    );

create table public.opportunity_participants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  opportunity_id uuid not null,
  contact_id uuid,
  role text not null default 'co_buyer'
    check (role in ('co_buyer', 'family', 'advisor', 'other')),
  display_name text not null check (char_length(display_name) between 1 and 160),
  phone_e164 text check (
    phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'
  ),
  phone_original text check (
    phone_original is null or char_length(phone_original) between 1 and 80
  ),
  consent_context text check (
    consent_context is null or char_length(consent_context) <= 1000
  ),
  created_at timestamptz not null default now(),
  foreign key (organization_id, opportunity_id)
    references public.opportunities(organization_id, id) on delete cascade,
  foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id)
);

create table public.source_attributions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  contact_id uuid not null,
  opportunity_id uuid not null,
  source_type text not null check (char_length(source_type) between 1 and 80),
  source_label text check (
    source_label is null or char_length(source_label) between 1 and 200
  ),
  details jsonb not null default '{}'::jsonb,
  attributed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id) on delete cascade,
  foreign key (organization_id, opportunity_id)
    references public.opportunities(organization_id, id) on delete cascade
);

create table public.opportunity_stage_history (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  opportunity_id uuid not null,
  from_stage text,
  to_stage text not null,
  reason text,
  actor_user_id uuid references auth.users(id),
  actor_membership_id uuid,
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, opportunity_id)
    references public.opportunities(organization_id, id) on delete cascade,
  foreign key (organization_id, actor_membership_id)
    references public.memberships(organization_id, id),
  check (
    from_stage is null
    or from_stage in (
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
  check (
    to_stage in (
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
  )
);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  contact_id uuid not null,
  opportunity_id uuid not null,
  status text not null default 'active'
    check (status in ('active', 'sleeping', 'closed')),
  ownership_type text not null default 'pedro'
    check (ownership_type in ('pedro', 'human')),
  assigned_membership_id uuid,
  opened_at timestamptz not null default now(),
  sleeping_since timestamptz,
  closed_at timestamptz,
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id) on delete cascade,
  foreign key (organization_id, opportunity_id)
    references public.opportunities(organization_id, id) on delete cascade,
  foreign key (organization_id, assigned_membership_id)
    references public.memberships(organization_id, id),
  check (
    (status = 'active' and sleeping_since is null and closed_at is null)
    or (status = 'sleeping' and sleeping_since is not null and closed_at is null)
    or (status = 'closed' and closed_at is not null)
  )
);

create unique index conversations_one_open_per_opportunity
  on public.conversations (opportunity_id)
  where status in ('active', 'sleeping');

create table public.opt_outs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  contact_id uuid not null,
  phone_e164 text,
  status text not null default 'active'
    check (status in ('active', 'revoked')),
  reason text,
  requested_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id) on delete cascade,
  check (
    (status = 'active' and revoked_at is null)
    or (status = 'revoked' and revoked_at is not null)
  )
);

create table public.proactive_approach_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  opportunity_id uuid not null,
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'scheduled', 'cancelled')),
  requested_by_user_id uuid not null references auth.users(id),
  requested_at timestamptz not null default now(),
  authorization_confirmed boolean not null default false,
  context text check (context is null or char_length(context) <= 2000),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, opportunity_id)
    references public.opportunities(organization_id, id) on delete cascade
);

create table private.opportunity_internal_notes (
  opportunity_id uuid primary key,
  organization_id uuid not null,
  note text not null check (char_length(note) between 1 and 8000),
  created_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, opportunity_id)
    references public.opportunities(organization_id, id) on delete cascade
);

create index contacts_organization_created_idx
  on public.contacts (organization_id, created_at desc);
create index contacts_organization_merged_into_idx
  on public.contacts (organization_id, merged_into_contact_id);
create index contact_phones_contact_idx
  on public.contact_phones (organization_id, contact_id, is_primary desc);
create index contact_phone_observations_contact_idx
  on public.contact_phone_observations (
    organization_id,
    contact_id,
    observed_at
  );
create index contact_phone_observations_phone_idx
  on public.contact_phone_observations (
    organization_id,
    contact_phone_id
  );
create index opportunity_participants_opportunity_idx
  on public.opportunity_participants (
    organization_id,
    opportunity_id,
    created_at
  );
create index opportunity_participants_contact_idx
  on public.opportunity_participants (organization_id, contact_id);
create index source_attributions_opportunity_idx
  on public.source_attributions (
    organization_id,
    opportunity_id,
    attributed_at
  );
create index source_attributions_contact_idx
  on public.source_attributions (
    organization_id,
    contact_id,
    attributed_at
  );
create index source_attributions_operation_idx
  on public.source_attributions (
    organization_id,
    operation_id,
    attributed_at
  );
create index opportunity_stage_history_opportunity_idx
  on public.opportunity_stage_history (
    organization_id,
    opportunity_id,
    created_at
  );
create index opportunity_stage_history_operation_idx
  on public.opportunity_stage_history (
    organization_id,
    operation_id,
    created_at
  );
create index opportunity_stage_history_actor_membership_idx
  on public.opportunity_stage_history (
    organization_id,
    actor_membership_id
  );
create index opportunity_stage_history_actor_user_idx
  on public.opportunity_stage_history (actor_user_id);
create index opportunities_operation_stage_entered_idx
  on public.opportunities (
    organization_id,
    operation_id,
    stage,
    updated_at desc
  );
create index opportunities_contact_created_idx
  on public.opportunities (
    organization_id,
    contact_id,
    created_at desc
  );
create index opportunities_assigned_membership_idx
  on public.opportunities (
    organization_id,
    assigned_membership_id,
    updated_at desc
  );
create index conversations_contact_status_idx
  on public.conversations (organization_id, contact_id, status);
create index conversations_operation_status_idx
  on public.conversations (organization_id, operation_id, status);
create index conversations_opportunity_idx
  on public.conversations (organization_id, opportunity_id);
create index conversations_assigned_membership_idx
  on public.conversations (
    organization_id,
    assigned_membership_id,
    status
  );
create index opt_outs_contact_status_idx
  on public.opt_outs (organization_id, contact_id, status);
create unique index opt_outs_one_active_per_contact
  on public.opt_outs (contact_id)
  where status = 'active';
create index proactive_approach_requests_operation_status_idx
  on public.proactive_approach_requests (
    organization_id,
    operation_id,
    status,
    requested_at
  );
create index proactive_approach_requests_opportunity_idx
  on public.proactive_approach_requests (
    organization_id,
    opportunity_id,
    requested_at
  );
create index proactive_approach_requests_requested_by_user_idx
  on public.proactive_approach_requests (requested_by_user_id);
create index opportunity_internal_notes_opportunity_idx
  on private.opportunity_internal_notes (
    organization_id,
    opportunity_id
  );
create index opportunity_internal_notes_created_by_user_idx
  on private.opportunity_internal_notes (created_by_user_id);

alter table public.contacts enable row level security;
alter table public.contact_phones enable row level security;
alter table public.contact_phone_observations enable row level security;
alter table public.opportunity_participants enable row level security;
alter table public.source_attributions enable row level security;
alter table public.opportunity_stage_history enable row level security;
alter table public.conversations enable row level security;
alter table public.opt_outs enable row level security;
alter table public.proactive_approach_requests enable row level security;

revoke all on table public.contacts from anon, authenticated;
revoke all on table public.contact_phones from anon, authenticated;
revoke all on table public.contact_phone_observations from anon, authenticated;
revoke all on table public.opportunity_participants from anon, authenticated;
revoke all on table public.source_attributions from anon, authenticated;
revoke all on table public.opportunity_stage_history from anon, authenticated;
revoke all on table public.conversations from anon, authenticated;
revoke all on table public.opt_outs from anon, authenticated;
revoke all on table public.proactive_approach_requests from anon, authenticated;
revoke all on table private.opportunity_internal_notes from public, anon, authenticated;

grant select on table public.contacts to authenticated;
grant select on table public.contact_phones to authenticated;
grant select on table public.contact_phone_observations to authenticated;
grant select on table public.opportunity_participants to authenticated;
grant select on table public.source_attributions to authenticated;
grant select on table public.opportunity_stage_history to authenticated;
grant select on table public.conversations to authenticated;
grant select on table public.opt_outs to authenticated;
grant select on table public.proactive_approach_requests to authenticated;

grant select, insert, update, delete on table public.contacts to service_role;
grant select, insert, update, delete on table public.contact_phones to service_role;
grant select, insert, update, delete on table public.contact_phone_observations to service_role;
grant select, insert, update, delete on table public.opportunity_participants to service_role;
grant select, insert, update, delete on table public.source_attributions to service_role;
grant select, insert, update, delete on table public.opportunity_stage_history to service_role;
grant select, insert, update, delete on table public.conversations to service_role;
grant select, insert, update, delete on table public.opt_outs to service_role;
grant select, insert, update, delete on table public.proactive_approach_requests to service_role;
grant select, insert, update, delete on table public.opportunities to service_role;

create or replace function private.normalize_phone_e164(
  raw_phone text,
  default_country_calling_code text default '+55'
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  compact text;
  digits text;
  country_digits text;
  normalized text;
begin
  compact := btrim(coalesce(raw_phone, ''));
  if compact = '' then
    raise exception 'phone is required' using errcode = '22023';
  end if;

  country_digits := regexp_replace(
    coalesce(default_country_calling_code, ''),
    '[^0-9]',
    '',
    'g'
  );
  if country_digits = '' then
    raise exception 'default country calling code is invalid'
      using errcode = '22023';
  end if;

  digits := regexp_replace(compact, '[^0-9]', '', 'g');
  if left(compact, 1) = '+' then
    normalized := '+' || digits;
  elsif country_digits = '55' then
    if char_length(digits) in (10, 11) then
      normalized := '+55' || digits;
    elsif left(digits, 2) = '55' and char_length(digits) in (12, 13) then
      normalized := '+' || digits;
    else
      raise exception 'Brazilian phone must include DDD'
        using errcode = '22023';
    end if;
  else
    normalized := '+' || country_digits || digits;
  end if;

  if normalized !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'phone is not valid E.164' using errcode = '22023';
  end if;

  return normalized;
end;
$$;

create or replace function private.can_access_opportunity(
  target_opportunity_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.opportunities as opportunity
    where opportunity.id = target_opportunity_id
      and (
        private.has_operation_role(
          opportunity.operation_id,
          array['owner', 'manager']
        )
        or exists (
          select 1
          from public.memberships as membership
          join public.membership_operations as membership_operation
            on membership_operation.membership_id = membership.id
            and membership_operation.organization_id = membership.organization_id
          where membership.id = opportunity.assigned_membership_id
            and membership.user_id = auth.uid()
            and membership.status = 'active'
            and membership.role = 'broker'
            and membership_operation.operation_id = opportunity.operation_id
            and opportunity.stage in (
              'call_scheduled',
              'negotiation',
              'proposal_reservation',
              'documentation',
              'payment',
              'purchased',
              'lost'
            )
        )
      )
  );
$$;

create or replace function private.can_access_contact(
  target_contact_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.contacts as contact
    where contact.id = target_contact_id
      and (
        private.has_active_membership(contact.organization_id)
        and (
          exists (
            select 1
            from public.memberships as membership
            where membership.organization_id = contact.organization_id
              and membership.user_id = auth.uid()
              and membership.status = 'active'
              and membership.role in ('owner', 'manager')
          )
          or exists (
            select 1
            from public.opportunities as opportunity
            where opportunity.contact_id = contact.id
              and private.can_access_opportunity(opportunity.id)
          )
        )
      )
  );
$$;

revoke all on function private.normalize_phone_e164(text, text) from public;
revoke all on function private.can_access_opportunity(uuid) from public;
revoke all on function private.can_access_contact(uuid) from public;
grant execute on function private.can_access_opportunity(uuid) to authenticated;
grant execute on function private.can_access_contact(uuid) to authenticated;

drop policy opportunities_select_operation_managers_or_assignee
  on public.opportunities;

create policy opportunities_select_by_pipeline_scope
  on public.opportunities
  for select
  to authenticated
  using (private.can_access_opportunity(id));

create policy contacts_select_by_opportunity_scope
  on public.contacts
  for select
  to authenticated
  using (private.can_access_contact(id));

create policy contact_phones_select_by_contact_scope
  on public.contact_phones
  for select
  to authenticated
  using (private.can_access_contact(contact_id));

create policy contact_phone_observations_select_managers
  on public.contact_phone_observations
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.opportunities as opportunity
      where opportunity.contact_id = contact_phone_observations.contact_id
        and private.has_operation_role(
          opportunity.operation_id,
          array['owner', 'manager']
        )
    )
  );

create policy opportunity_participants_select_by_opportunity_scope
  on public.opportunity_participants
  for select
  to authenticated
  using (private.can_access_opportunity(opportunity_id));

create policy source_attributions_select_by_opportunity_scope
  on public.source_attributions
  for select
  to authenticated
  using (private.can_access_opportunity(opportunity_id));

create policy opportunity_stage_history_select_by_opportunity_scope
  on public.opportunity_stage_history
  for select
  to authenticated
  using (private.can_access_opportunity(opportunity_id));

create policy conversations_select_by_opportunity_scope
  on public.conversations
  for select
  to authenticated
  using (private.can_access_opportunity(opportunity_id));

create policy opt_outs_select_operation_managers
  on public.opt_outs
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.opportunities as opportunity
      where opportunity.contact_id = opt_outs.contact_id
        and private.has_operation_role(
          opportunity.operation_id,
          array['owner', 'manager']
        )
    )
  );

create policy proactive_approach_requests_select_operation_managers
  on public.proactive_approach_requests
  for select
  to authenticated
  using (
    private.has_operation_role(operation_id, array['owner', 'manager'])
  );

create or replace function private.capture_opportunity_stage_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  trace_value uuid;
  correlation_value uuid;
  reason_value text;
begin
  trace_value := coalesce(
    nullif(current_setting('grillstudio.trace_id', true), '')::uuid,
    gen_random_uuid()
  );
  correlation_value := coalesce(
    nullif(current_setting('grillstudio.correlation_id', true), '')::uuid,
    gen_random_uuid()
  );
  reason_value := nullif(
    current_setting('grillstudio.stage_reason', true),
    ''
  );

  insert into public.opportunity_stage_history (
    organization_id,
    operation_id,
    opportunity_id,
    from_stage,
    to_stage,
    reason,
    actor_user_id,
    actor_membership_id,
    trace_id,
    correlation_id
  )
  values (
    new.organization_id,
    new.operation_id,
    new.id,
    case when tg_op = 'INSERT' then null else old.stage end,
    new.stage,
    reason_value,
    auth.uid(),
    private.actor_membership_id(new.operation_id),
    trace_value,
    correlation_value
  );

  return new;
end;
$$;

create or replace function private.guard_opportunity_stage_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.stage is distinct from old.stage
    and current_setting('grillstudio.stage_transition_id', true)
      is distinct from new.id::text
  then
    raise exception 'opportunity stage must change through transition RPC'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger opportunities_guard_stage_transition
before update of stage on public.opportunities
for each row execute function private.guard_opportunity_stage_transition();

create trigger opportunities_capture_initial_stage
after insert on public.opportunities
for each row execute function private.capture_opportunity_stage_history();

create trigger opportunities_capture_stage_transition
after update of stage on public.opportunities
for each row
when (old.stage is distinct from new.stage)
execute function private.capture_opportunity_stage_history();

create or replace function private.create_manual_lead(
  target_operation_id uuid,
  lead_name text,
  phone_original text,
  lead_source text,
  registration_action text,
  pedro_context_value text,
  internal_note_value text,
  unit_count_value integer,
  amount_scope_value text,
  participant_name text,
  participant_phone_original text,
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
  operation_record public.operations%rowtype;
  normalized_phone text;
  normalized_participant_phone text;
  target_contact public.contacts%rowtype;
  target_phone public.contact_phones%rowtype;
  created_opportunity public.opportunities%rowtype;
  initial_stage text;
  contact_was_existing boolean := false;
begin
  if auth.uid() is null
    or not private.has_operation_role(
      target_operation_id,
      array['owner', 'manager']
    )
  then
    raise exception 'manual lead permission denied' using errcode = '42501';
  end if;

  if registration_action not in ('register', 'assume', 'request_proactive') then
    raise exception 'invalid manual registration action' using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(lead_source, '')), '') is null then
    raise exception 'lead source is required' using errcode = '22023';
  end if;

  if coalesce(unit_count_value, 0) not between 1 and 100
    or amount_scope_value not in ('total', 'per_unit')
  then
    raise exception 'invalid unit information' using errcode = '22023';
  end if;

  select operation.*
  into strict operation_record
  from public.operations as operation
  where operation.id = target_operation_id
    and operation.status = 'active';

  select membership.*
  into strict actor_membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  normalized_phone := private.normalize_phone_e164(phone_original, '+55');

  select phone.*
  into target_phone
  from public.contact_phones as phone
  where phone.organization_id = operation_record.organization_id
    and phone.e164 = normalized_phone
  for update;

  if found then
    contact_was_existing := true;
    select contact.*
    into strict target_contact
    from public.contacts as contact
    where contact.id = target_phone.contact_id
    for update;

    if target_contact.status = 'merged' then
      select contact.*
      into strict target_contact
      from public.contacts as contact
      where contact.id = target_contact.merged_into_contact_id
      for update;

      select phone.*
      into strict target_phone
      from public.contact_phones as phone
      where phone.organization_id = operation_record.organization_id
        and phone.e164 = normalized_phone;
    end if;

    if target_contact.display_name is null
      and nullif(btrim(coalesce(lead_name, '')), '') is not null
    then
      update public.contacts
      set
        display_name = left(btrim(lead_name), 160),
        updated_at = now(),
        version = version + 1
      where id = target_contact.id
      returning * into target_contact;
    end if;
  else
    insert into public.contacts (
      organization_id,
      display_name
    )
    values (
      operation_record.organization_id,
      nullif(left(btrim(coalesce(lead_name, '')), 160), '')
    )
    returning * into target_contact;

    insert into public.contact_phones (
      organization_id,
      contact_id,
      e164,
      original_value,
      is_primary
    )
    values (
      operation_record.organization_id,
      target_contact.id,
      normalized_phone,
      btrim(phone_original),
      true
    )
    returning * into target_phone;
  end if;

  insert into public.contact_phone_observations (
    organization_id,
    contact_id,
    contact_phone_id,
    original_value,
    source_type
  )
  values (
    operation_record.organization_id,
    target_contact.id,
    target_phone.id,
    btrim(phone_original),
    left(btrim(lead_source), 80)
  );

  initial_stage := case
    when registration_action = 'assume' then 'in_service'
    else 'new'
  end;

  perform set_config('grillstudio.trace_id', request_trace_id::text, true);
  perform set_config(
    'grillstudio.correlation_id',
    request_correlation_id::text,
    true
  );
  perform set_config(
    'grillstudio.stage_reason',
    'manual_registration',
    true
  );

  insert into public.opportunities (
    organization_id,
    operation_id,
    contact_id,
    stage,
    assigned_membership_id,
    source_type,
    unit_count,
    amount_scope,
    pedro_context
  )
  values (
    operation_record.organization_id,
    operation_record.id,
    target_contact.id,
    initial_stage,
    case
      when registration_action = 'assume' then actor_membership.id
      else null
    end,
    left(btrim(lead_source), 80),
    unit_count_value,
    amount_scope_value,
    nullif(left(btrim(coalesce(pedro_context_value, '')), 4000), '')
  )
  returning * into created_opportunity;

  insert into public.source_attributions (
    organization_id,
    operation_id,
    contact_id,
    opportunity_id,
    source_type,
    source_label,
    details
  )
  values (
    operation_record.organization_id,
    operation_record.id,
    target_contact.id,
    created_opportunity.id,
    left(btrim(lead_source), 80),
    left(btrim(lead_source), 200),
    jsonb_build_object(
      'entry', 'manual',
      'phone_original', btrim(phone_original)
    )
  );

  if nullif(btrim(coalesce(participant_name, '')), '') is not null then
    normalized_participant_phone := case
      when nullif(btrim(coalesce(participant_phone_original, '')), '') is null
        then null
      else private.normalize_phone_e164(participant_phone_original, '+55')
    end;

    insert into public.opportunity_participants (
      organization_id,
      opportunity_id,
      display_name,
      phone_e164,
      phone_original
    )
    values (
      operation_record.organization_id,
      created_opportunity.id,
      left(btrim(participant_name), 160),
      normalized_participant_phone,
      nullif(left(btrim(coalesce(participant_phone_original, '')), 80), '')
    );
  end if;

  if nullif(btrim(coalesce(internal_note_value, '')), '') is not null then
    insert into private.opportunity_internal_notes (
      opportunity_id,
      organization_id,
      note,
      created_by_user_id
    )
    values (
      created_opportunity.id,
      operation_record.organization_id,
      left(btrim(internal_note_value), 8000),
      auth.uid()
    );
  end if;

  if registration_action = 'request_proactive' then
    insert into public.proactive_approach_requests (
      organization_id,
      operation_id,
      opportunity_id,
      requested_by_user_id,
      authorization_confirmed,
      context
    )
    values (
      operation_record.organization_id,
      operation_record.id,
      created_opportunity.id,
      auth.uid(),
      false,
      nullif(left(btrim(coalesce(pedro_context_value, '')), 2000), '')
    );
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
    operation_record.organization_id,
    operation_record.id,
    auth.uid(),
    'lead.manual_created',
    'opportunity',
    created_opportunity.id,
    null,
    jsonb_build_object(
      'contact_id', target_contact.id,
      'contact_deduplicated', contact_was_existing,
      'stage', initial_stage,
      'registration_action', registration_action,
      'has_pedro_context', created_opportunity.pedro_context is not null,
      'has_internal_note',
        nullif(btrim(coalesce(internal_note_value, '')), '') is not null,
      'unit_count', unit_count_value,
      'amount_scope', amount_scope_value
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'contact_id', target_contact.id,
    'opportunity_id', created_opportunity.id,
    'phone_e164', normalized_phone,
    'stage', created_opportunity.stage
  );
end;
$$;

create or replace function private.transition_opportunity(
  target_opportunity_id uuid,
  target_stage text,
  transition_reason text,
  human_decision boolean,
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
  opportunity_record public.opportunities%rowtype;
  actor_membership_id uuid;
  post_call boolean;
  allowed boolean := false;
  before_state jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select opportunity.*
  into strict opportunity_record
  from public.opportunities as opportunity
  where opportunity.id = target_opportunity_id
  for update;

  if expected_version is null
    or opportunity_record.version <> expected_version
  then
    -- A SQLSTATE 40001 is retried by the managed transaction boundary and
    -- would turn an optimistic conflict into a long request. Preserve the
    -- domain code in a deterministic HTTP 409 without triggering retries.
    raise sqlstate 'PGRST' using
      message = jsonb_build_object(
        'code', '40001',
        'message', 'opportunity version conflict',
        'details', format(
          'expected version %s but current version is %s',
          expected_version,
          opportunity_record.version
        ),
        'hint', 'reload the opportunity before retrying'
      )::text,
      detail = jsonb_build_object(
        'status', 409,
        'headers', jsonb_build_object()
      )::text;
  end if;

  actor_membership_id := private.actor_membership_id(
    opportunity_record.operation_id
  );
  if actor_membership_id is null then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;

  if not private.has_operation_role(
    opportunity_record.operation_id,
    array['owner', 'manager']
  ) and not (
    opportunity_record.assigned_membership_id = actor_membership_id
    and opportunity_record.stage in (
      'call_scheduled',
      'negotiation',
      'proposal_reservation',
      'documentation',
      'payment',
      'lost'
    )
  ) then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;

  if opportunity_record.stage = 'purchased' then
    raise exception 'purchased opportunity cannot reopen'
      using errcode = '23514';
  end if;

  if target_stage = opportunity_record.stage then
    raise exception 'opportunity is already in target stage'
      using errcode = '22023';
  end if;

  post_call := exists (
    select 1
    from public.calls as call_record
    where call_record.opportunity_id = opportunity_record.id
      and call_record.status in ('completed', 'no_show')
  ) or exists (
    select 1
    from public.opportunity_stage_history as history
    where history.opportunity_id = opportunity_record.id
      and history.to_stage in (
        'negotiation',
        'proposal_reservation',
        'documentation',
        'payment',
        'purchased'
      )
  );

  allowed := case opportunity_record.stage
    when 'new' then target_stage in ('in_service', 'lost')
    when 'in_service' then target_stage in ('call_scheduled', 'lost')
    when 'call_scheduled' then target_stage in ('negotiation', 'lost')
    when 'negotiation' then target_stage in ('proposal_reservation', 'lost')
    when 'proposal_reservation' then target_stage in ('documentation', 'lost')
    when 'documentation' then target_stage in ('payment', 'lost')
    when 'payment' then target_stage in ('purchased', 'lost')
    when 'lost' then target_stage = 'in_service'
      and coalesce(human_decision, false)
    else false
  end;

  if not allowed then
    raise exception 'invalid pipeline transition'
      using errcode = '23514';
  end if;

  if opportunity_record.stage = 'in_service'
    and target_stage = 'call_scheduled'
    and not exists (
      select 1
      from public.calls as call_record
      where call_record.opportunity_id = opportunity_record.id
        and call_record.assigned_membership_id is not null
        and call_record.status in ('assigned', 'scheduled')
    )
  then
    raise exception 'call must be assigned before scheduling stage'
      using errcode = '23514';
  end if;

  if target_stage = 'lost'
    and nullif(btrim(coalesce(transition_reason, '')), '') is null
  then
    raise exception 'loss reason is required' using errcode = '22023';
  end if;

  if opportunity_record.stage = 'lost'
    and post_call
    and not coalesce(human_decision, false)
  then
    raise exception 'post-call reactivation requires human decision'
      using errcode = '23514';
  end if;

  before_state := jsonb_build_object(
    'stage', opportunity_record.stage,
    'loss_reason', opportunity_record.loss_reason
  );

  perform set_config(
    'grillstudio.stage_transition_id',
    opportunity_record.id::text,
    true
  );
  perform set_config('grillstudio.trace_id', request_trace_id::text, true);
  perform set_config(
    'grillstudio.correlation_id',
    request_correlation_id::text,
    true
  );
  perform set_config(
    'grillstudio.stage_reason',
    coalesce(nullif(btrim(transition_reason), ''), 'pipeline_transition'),
    true
  );

  update public.opportunities
  set
    stage = target_stage,
    loss_reason = case
      when target_stage = 'lost' then left(btrim(transition_reason), 500)
      else null
    end,
    updated_at = now(),
    version = version + 1
  where id = opportunity_record.id
  returning * into opportunity_record;

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
    opportunity_record.organization_id,
    opportunity_record.operation_id,
    auth.uid(),
    'opportunity.stage_changed',
    'opportunity',
    opportunity_record.id,
    before_state,
    jsonb_build_object(
      'stage', opportunity_record.stage,
      'loss_reason', opportunity_record.loss_reason,
      'human_decision', coalesce(human_decision, false)
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'id', opportunity_record.id,
    'stage', opportunity_record.stage,
    'version', opportunity_record.version
  );
end;
$$;

create or replace function private.merge_contacts(
  primary_contact_id uuid,
  duplicate_contact_id uuid,
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  primary_contact public.contacts%rowtype;
  duplicate_contact public.contacts%rowtype;
  primary_active_conversations bigint;
  duplicate_active_conversations bigint;
begin
  if auth.uid() is null
    or not private.has_operation_role(
      target_operation_id,
      array['owner', 'manager']
    )
  then
    raise exception 'contact merge permission denied' using errcode = '42501';
  end if;

  if primary_contact_id = duplicate_contact_id then
    raise exception 'contacts must be different' using errcode = '22023';
  end if;

  select contact.*
  into strict primary_contact
  from public.contacts as contact
  where contact.id = primary_contact_id
    and contact.status = 'active'
  for update;

  select contact.*
  into strict duplicate_contact
  from public.contacts as contact
  where contact.id = duplicate_contact_id
    and contact.organization_id = primary_contact.organization_id
    and contact.status = 'active'
  for update;

  if not exists (
    select 1
    from public.operations as operation
    where operation.id = target_operation_id
      and operation.organization_id = primary_contact.organization_id
  ) then
    raise exception 'contacts do not belong to target operation organization'
      using errcode = '42501';
  end if;

  select count(*)
  into primary_active_conversations
  from public.conversations as conversation
  where conversation.contact_id = primary_contact.id
    and conversation.status = 'active';

  select count(*)
  into duplicate_active_conversations
  from public.conversations as conversation
  where conversation.contact_id = duplicate_contact.id
    and conversation.status = 'active';

  if primary_active_conversations > 0
    and duplicate_active_conversations > 0
  then
    raise exception 'cannot merge two contacts with active conversations'
      using errcode = '23514';
  end if;

  update public.contact_phone_observations as observation
  set
    contact_id = primary_contact.id,
    contact_phone_id = primary_phone.id
  from public.contact_phones as duplicate_phone
  join public.contact_phones as primary_phone
    on primary_phone.organization_id = duplicate_phone.organization_id
    and primary_phone.e164 = duplicate_phone.e164
    and primary_phone.contact_id = primary_contact.id
  where observation.contact_id = duplicate_contact.id
    and observation.contact_phone_id = duplicate_phone.id;

  update public.contact_phone_observations
  set contact_id = primary_contact.id
  where contact_id = duplicate_contact.id;

  delete from public.contact_phones as duplicate_phone
  where duplicate_phone.contact_id = duplicate_contact.id
    and exists (
      select 1
      from public.contact_phones as primary_phone
      where primary_phone.contact_id = primary_contact.id
        and primary_phone.e164 = duplicate_phone.e164
    );

  update public.contact_phones
  set
    contact_id = primary_contact.id,
    is_primary = false
  where contact_id = duplicate_contact.id;

  if not exists (
    select 1
    from public.contact_phones
    where contact_id = primary_contact.id
      and is_primary
  ) then
    update public.contact_phones
    set is_primary = true
    where id = (
      select id
      from public.contact_phones
      where contact_id = primary_contact.id
      order by created_at, id
      limit 1
    );
  end if;

  update public.opportunities
  set
    contact_id = primary_contact.id,
    updated_at = now(),
    version = version + 1
  where contact_id = duplicate_contact.id;

  update public.opportunity_participants
  set contact_id = primary_contact.id
  where contact_id = duplicate_contact.id;

  update public.source_attributions
  set contact_id = primary_contact.id
  where contact_id = duplicate_contact.id;

  update public.conversations
  set
    contact_id = primary_contact.id,
    updated_at = now(),
    version = version + 1
  where contact_id = duplicate_contact.id;

  if exists (
    select 1
    from public.opt_outs
    where contact_id = primary_contact.id
      and status = 'active'
  ) then
    update public.opt_outs
    set
      status = 'revoked',
      revoked_at = now(),
      reason = concat_ws(
        ' · ',
        nullif(reason, ''),
        'Consolidado em fusão; opt-out ativo preservado no Contato principal'
      )
    where contact_id = duplicate_contact.id
      and status = 'active';
  end if;

  update public.opt_outs
  set contact_id = primary_contact.id
  where contact_id = duplicate_contact.id;

  update public.contacts
  set
    display_name = coalesce(display_name, duplicate_contact.display_name),
    updated_at = now(),
    version = version + 1
  where id = primary_contact.id;

  update public.contacts
  set
    status = 'merged',
    merged_into_contact_id = primary_contact.id,
    updated_at = now(),
    version = version + 1
  where id = duplicate_contact.id;

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
    primary_contact.organization_id,
    target_operation_id,
    auth.uid(),
    'contact.merged',
    'contact',
    primary_contact.id,
    jsonb_build_object(
      'primary_contact_id', primary_contact.id,
      'duplicate_contact_id', duplicate_contact.id,
      'primary_active_conversations', primary_active_conversations,
      'duplicate_active_conversations', duplicate_active_conversations
    ),
    jsonb_build_object(
      'survivor_contact_id', primary_contact.id,
      'merged_contact_id', duplicate_contact.id,
      'phones_preserved', true,
      'sources_preserved', true,
      'opt_outs_preserved', true,
      'opportunity_history_preserved', true
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'contact_id', primary_contact.id,
    'merged_contact_id', duplicate_contact.id
  );
end;
$$;

create or replace function private.reopen_opportunity_on_inbound(
  target_opportunity_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  opportunity_record public.opportunities%rowtype;
  post_call boolean;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select opportunity.*
  into strict opportunity_record
  from public.opportunities as opportunity
  where opportunity.id = target_opportunity_id
  for update;

  if opportunity_record.stage = 'purchased' then
    return 'sale_closed';
  end if;

  if opportunity_record.stage <> 'lost' then
    return 'not_lost';
  end if;

  post_call := exists (
    select 1
    from public.calls as call_record
    where call_record.opportunity_id = opportunity_record.id
      and call_record.status in ('completed', 'no_show')
  ) or exists (
    select 1
    from public.opportunity_stage_history as history
    where history.opportunity_id = opportunity_record.id
      and history.to_stage in (
        'negotiation',
        'proposal_reservation',
        'documentation',
        'payment',
        'purchased'
      )
  );

  if post_call then
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
      opportunity_record.organization_id,
      opportunity_record.operation_id,
      null,
      'opportunity.inbound_reactivation_requires_human',
      'opportunity',
      opportunity_record.id,
      jsonb_build_object('stage', opportunity_record.stage),
      jsonb_build_object('stage', opportunity_record.stage),
      request_trace_id,
      request_correlation_id
    );
    return 'human_review_required';
  end if;

  perform set_config(
    'grillstudio.stage_transition_id',
    opportunity_record.id::text,
    true
  );
  perform set_config('grillstudio.trace_id', request_trace_id::text, true);
  perform set_config(
    'grillstudio.correlation_id',
    request_correlation_id::text,
    true
  );
  perform set_config(
    'grillstudio.stage_reason',
    'inbound_return_before_call',
    true
  );

  update public.opportunities
  set
    stage = 'in_service',
    loss_reason = null,
    updated_at = now(),
    version = version + 1
  where id = opportunity_record.id;

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
    opportunity_record.organization_id,
    opportunity_record.operation_id,
    null,
    'opportunity.inbound_reactivated',
    'opportunity',
    opportunity_record.id,
    jsonb_build_object(
      'stage', 'lost',
      'loss_reason', opportunity_record.loss_reason
    ),
    jsonb_build_object('stage', 'in_service', 'loss_reason', null),
    request_trace_id,
    request_correlation_id
  );

  return 'reopened';
end;
$$;

create or replace function private.get_lead_list(
  target_operation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_id uuid;
  is_management boolean;
  result jsonb;
begin
  actor_id := private.actor_membership_id(target_operation_id);
  if actor_id is null then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;

  is_management := private.has_operation_role(
    target_operation_id,
    array['owner', 'manager']
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', opportunity.id,
        'contact_id', opportunity.contact_id,
        'display_name', contact.display_name,
        'phone_e164', phone.e164,
        'phone_original', phone.original_value,
        'source_type', opportunity.source_type,
        'stage', opportunity.stage,
        'assigned_membership_id', opportunity.assigned_membership_id,
        'assigned_name', staff_profile.full_name,
        'unit_count', opportunity.unit_count,
        'amount_scope', opportunity.amount_scope,
        'has_opt_out', exists (
          select 1
          from public.opt_outs as opt_out
          where opt_out.contact_id = contact.id
            and opt_out.status = 'active'
        ),
        'created_at', opportunity.created_at,
        'updated_at', opportunity.updated_at,
        'version', opportunity.version
      )
      order by opportunity.updated_at desc, opportunity.id
    ),
    '[]'::jsonb
  )
  into result
  from public.opportunities as opportunity
  join public.contacts as contact
    on contact.id = opportunity.contact_id
  left join lateral (
    select contact_phone.e164, contact_phone.original_value
    from public.contact_phones as contact_phone
    where contact_phone.contact_id = contact.id
    order by contact_phone.is_primary desc, contact_phone.created_at, contact_phone.id
    limit 1
  ) as phone on true
  left join public.staff_profiles as staff_profile
    on staff_profile.membership_id = opportunity.assigned_membership_id
  where opportunity.operation_id = target_operation_id
    and (
      is_management
      or (
        opportunity.assigned_membership_id = actor_id
        and opportunity.stage in (
          'call_scheduled',
          'negotiation',
          'proposal_reservation',
          'documentation',
          'payment',
          'purchased',
          'lost'
        )
      )
    );

  return result;
end;
$$;

create or replace function private.get_pipeline_board(
  target_operation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return jsonb_build_object(
    'stages',
    jsonb_build_array(
      jsonb_build_object('key', 'new', 'label', 'Novo'),
      jsonb_build_object('key', 'in_service', 'label', 'Em atendimento'),
      jsonb_build_object('key', 'call_scheduled', 'label', 'Call agendada'),
      jsonb_build_object('key', 'negotiation', 'label', 'Em negociação'),
      jsonb_build_object(
        'key',
        'proposal_reservation',
        'label',
        'Proposta/Reserva'
      ),
      jsonb_build_object('key', 'documentation', 'label', 'Documentação'),
      jsonb_build_object('key', 'payment', 'label', 'Pagamento'),
      jsonb_build_object('key', 'purchased', 'label', 'Comprado'),
      jsonb_build_object('key', 'lost', 'label', 'Perdido')
    ),
    'cards',
    private.get_lead_list(target_operation_id)
  );
end;
$$;

create or replace function private.get_lead_detail(
  target_opportunity_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  opportunity_record public.opportunities%rowtype;
  can_manage boolean;
  result jsonb;
begin
  select opportunity.*
  into strict opportunity_record
  from public.opportunities as opportunity
  where opportunity.id = target_opportunity_id;

  if not private.can_access_opportunity(opportunity_record.id) then
    raise exception 'lead detail permission denied' using errcode = '42501';
  end if;

  can_manage := private.has_operation_role(
    opportunity_record.operation_id,
    array['owner', 'manager']
  );

  select jsonb_build_object(
    'id', opportunity.id,
    'contact_id', opportunity.contact_id,
    'display_name', contact.display_name,
    'contact_status', contact.status,
    'stage', opportunity.stage,
    'source_type', opportunity.source_type,
    'assigned_membership_id', opportunity.assigned_membership_id,
    'assigned_name', staff_profile.full_name,
    'unit_count', opportunity.unit_count,
    'amount_scope', opportunity.amount_scope,
    'pedro_context', opportunity.pedro_context,
    'internal_note', case
      when can_manage then (
        select internal_note.note
        from private.opportunity_internal_notes as internal_note
        where internal_note.opportunity_id = opportunity.id
      )
      else null
    end,
    'loss_reason', opportunity.loss_reason,
    'created_at', opportunity.created_at,
    'updated_at', opportunity.updated_at,
    'version', opportunity.version,
    'phones', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', phone.id,
            'e164', phone.e164,
            'original_value', phone.original_value,
            'is_primary', phone.is_primary,
            'observations', (
              select coalesce(
                jsonb_agg(
                  jsonb_build_object(
                    'original_value', observation.original_value,
                    'source_type', observation.source_type,
                    'observed_at', observation.observed_at
                  )
                  order by observation.observed_at
                ),
                '[]'::jsonb
              )
              from public.contact_phone_observations as observation
              where observation.contact_phone_id = phone.id
            )
          )
          order by phone.is_primary desc, phone.created_at
        )
        from public.contact_phones as phone
        where phone.contact_id = contact.id
      ),
      '[]'::jsonb
    ),
    'participants', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', participant.id,
            'role', participant.role,
            'display_name', participant.display_name,
            'phone_e164', participant.phone_e164,
            'phone_original', participant.phone_original
          )
          order by participant.created_at
        )
        from public.opportunity_participants as participant
        where participant.opportunity_id = opportunity.id
      ),
      '[]'::jsonb
    ),
    'sources', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', source.id,
            'source_type', source.source_type,
            'source_label', source.source_label,
            'attributed_at', source.attributed_at
          )
          order by source.attributed_at
        )
        from public.source_attributions as source
        where source.opportunity_id = opportunity.id
      ),
      '[]'::jsonb
    ),
    'history', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', history.id,
            'from_stage', history.from_stage,
            'to_stage', history.to_stage,
            'reason', history.reason,
            'actor_user_id', history.actor_user_id,
            'created_at', history.created_at
          )
          order by history.created_at, history.id
        )
        from public.opportunity_stage_history as history
        where history.opportunity_id = opportunity.id
      ),
      '[]'::jsonb
    ),
    'conversations', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', conversation.id,
            'status', conversation.status,
            'ownership_type', conversation.ownership_type,
            'opened_at', conversation.opened_at
          )
          order by conversation.opened_at desc
        )
        from public.conversations as conversation
        where conversation.opportunity_id = opportunity.id
      ),
      '[]'::jsonb
    ),
    'has_opt_out', exists (
      select 1
      from public.opt_outs as opt_out
      where opt_out.contact_id = contact.id
        and opt_out.status = 'active'
    ),
    'proactive_request', case
      when can_manage then (
        select jsonb_build_object(
          'id', request.id,
          'status', request.status,
          'authorization_confirmed', request.authorization_confirmed,
          'requested_at', request.requested_at
        )
        from public.proactive_approach_requests as request
        where request.opportunity_id = opportunity.id
        order by request.requested_at desc
        limit 1
      )
      else null
    end
  )
  into result
  from public.opportunities as opportunity
  join public.contacts as contact
    on contact.id = opportunity.contact_id
  left join public.staff_profiles as staff_profile
    on staff_profile.membership_id = opportunity.assigned_membership_id
  where opportunity.id = opportunity_record.id;

  return result;
end;
$$;

create or replace function private.get_contact_merge_candidates(
  target_operation_id uuid,
  excluded_contact_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  operation_organization_id uuid;
  result jsonb;
begin
  if auth.uid() is null
    or not private.has_operation_role(
      target_operation_id,
      array['owner', 'manager']
    )
  then
    raise exception 'contact merge permission denied' using errcode = '42501';
  end if;

  select operation.organization_id
  into strict operation_organization_id
  from public.operations as operation
  where operation.id = target_operation_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', contact.id,
        'display_name', contact.display_name,
        'phone_e164', phone.e164,
        'phone_original', phone.original_value,
        'active_conversations', (
          select count(*)
          from public.conversations as conversation
          where conversation.contact_id = contact.id
            and conversation.status = 'active'
        )
      )
      order by coalesce(contact.display_name, phone.e164), contact.id
    ),
    '[]'::jsonb
  )
  into result
  from public.contacts as contact
  left join lateral (
    select contact_phone.e164, contact_phone.original_value
    from public.contact_phones as contact_phone
    where contact_phone.contact_id = contact.id
    order by contact_phone.is_primary desc, contact_phone.created_at
    limit 1
  ) as phone on true
  where contact.organization_id = operation_organization_id
    and contact.status = 'active'
    and contact.id <> excluded_contact_id;

  return result;
end;
$$;

revoke all on function private.capture_opportunity_stage_history() from public;
revoke all on function private.guard_opportunity_stage_transition() from public;
revoke all on function private.create_manual_lead(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) from public;
revoke all on function private.transition_opportunity(
  uuid, text, text, boolean, bigint, uuid, uuid
) from public;
revoke all on function private.merge_contacts(
  uuid, uuid, uuid, uuid, uuid
) from public;
revoke all on function private.reopen_opportunity_on_inbound(
  uuid, uuid, uuid
) from public;
revoke all on function private.get_lead_list(uuid) from public;
revoke all on function private.get_pipeline_board(uuid) from public;
revoke all on function private.get_lead_detail(uuid) from public;
revoke all on function private.get_contact_merge_candidates(uuid, uuid)
  from public;

grant execute on function private.create_manual_lead(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) to authenticated;
grant execute on function private.transition_opportunity(
  uuid, text, text, boolean, bigint, uuid, uuid
) to authenticated;
grant execute on function private.merge_contacts(
  uuid, uuid, uuid, uuid, uuid
) to authenticated;
grant execute on function private.reopen_opportunity_on_inbound(
  uuid, uuid, uuid
) to service_role;
grant execute on function private.get_lead_list(uuid) to authenticated;
grant execute on function private.get_pipeline_board(uuid) to authenticated;
grant execute on function private.get_lead_detail(uuid) to authenticated;
grant execute on function private.get_contact_merge_candidates(uuid, uuid)
  to authenticated;

create or replace function public.create_manual_lead(
  target_operation_id uuid,
  lead_name text,
  phone_original text,
  lead_source text,
  registration_action text,
  pedro_context_value text,
  internal_note_value text,
  unit_count_value integer,
  amount_scope_value text,
  participant_name text,
  participant_phone_original text,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.create_manual_lead(
    target_operation_id,
    lead_name,
    phone_original,
    lead_source,
    registration_action,
    pedro_context_value,
    internal_note_value,
    unit_count_value,
    amount_scope_value,
    participant_name,
    participant_phone_original,
    request_trace_id,
    request_correlation_id
  );
$$;

create or replace function public.transition_opportunity(
  target_opportunity_id uuid,
  target_stage text,
  transition_reason text,
  human_decision boolean,
  expected_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.transition_opportunity(
    target_opportunity_id,
    target_stage,
    transition_reason,
    human_decision,
    expected_version,
    request_trace_id,
    request_correlation_id
  );
$$;

create or replace function public.merge_contacts(
  primary_contact_id uuid,
  duplicate_contact_id uuid,
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.merge_contacts(
    primary_contact_id,
    duplicate_contact_id,
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );
$$;

create or replace function public.reopen_opportunity_on_inbound(
  target_opportunity_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns text
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.reopen_opportunity_on_inbound(
    target_opportunity_id,
    request_trace_id,
    request_correlation_id
  );
$$;

create or replace function public.get_lead_list(
  target_operation_id uuid
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_lead_list(target_operation_id);
$$;

create or replace function public.get_pipeline_board(
  target_operation_id uuid
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_pipeline_board(target_operation_id);
$$;

create or replace function public.get_lead_detail(
  target_opportunity_id uuid
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_lead_detail(target_opportunity_id);
$$;

create or replace function public.get_contact_merge_candidates(
  target_operation_id uuid,
  excluded_contact_id uuid
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_contact_merge_candidates(
    target_operation_id,
    excluded_contact_id
  );
$$;

revoke all on function public.create_manual_lead(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) from public;
revoke all on function public.transition_opportunity(
  uuid, text, text, boolean, bigint, uuid, uuid
) from public;
revoke all on function public.merge_contacts(
  uuid, uuid, uuid, uuid, uuid
) from public;
revoke all on function public.reopen_opportunity_on_inbound(
  uuid, uuid, uuid
) from public;
revoke all on function public.get_lead_list(uuid) from public;
revoke all on function public.get_pipeline_board(uuid) from public;
revoke all on function public.get_lead_detail(uuid) from public;
revoke all on function public.get_contact_merge_candidates(uuid, uuid)
  from public;

grant execute on function public.create_manual_lead(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) to authenticated;
grant execute on function public.transition_opportunity(
  uuid, text, text, boolean, bigint, uuid, uuid
) to authenticated;
grant execute on function public.merge_contacts(
  uuid, uuid, uuid, uuid, uuid
) to authenticated;
grant execute on function public.reopen_opportunity_on_inbound(
  uuid, uuid, uuid
) to service_role;
grant execute on function public.get_lead_list(uuid) to authenticated;
grant execute on function public.get_pipeline_board(uuid) to authenticated;
grant execute on function public.get_lead_detail(uuid) to authenticated;
grant execute on function public.get_contact_merge_candidates(uuid, uuid)
  to authenticated;
