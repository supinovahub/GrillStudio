-- T04 review hardening.
--
-- This migration deliberately keeps T21 (Call assignment/release) and T24
-- (post-Call commands) fail-closed. It only strengthens the Contact,
-- Opportunity and minimal Conversation aggregates already owned by T04.

alter table public.opportunities
  add column stage_entered_at timestamptz;

update public.opportunities as opportunity
set stage_entered_at = coalesce(
  (
    select history.created_at
    from public.opportunity_stage_history as history
    where history.opportunity_id = opportunity.id
      and history.to_stage = opportunity.stage
    order by history.created_at desc, history.id desc
    limit 1
  ),
  opportunity.created_at
);

alter table public.opportunities
  alter column stage_entered_at set default now(),
  alter column stage_entered_at set not null,
  add constraint opportunities_organization_operation_id_key
    unique (organization_id, operation_id, id),
  add constraint opportunities_organization_contact_id_key
    unique (organization_id, contact_id, id);

drop index public.opportunities_operation_stage_entered_idx;
create index opportunities_operation_stage_entered_idx
  on public.opportunities (
    organization_id,
    operation_id,
    stage,
    stage_entered_at desc,
    id
  );

create index opportunities_operation_assignee_stage_idx
  on public.opportunities (
    organization_id,
    operation_id,
    assigned_membership_id,
    stage,
    stage_entered_at desc
  )
  where assigned_membership_id is not null;

alter table public.contact_phones
  add constraint contact_phones_organization_contact_id_key
    unique (organization_id, contact_id, id);

alter table public.contact_phone_observations
  add constraint contact_phone_observations_contact_phone_fkey
    foreign key (organization_id, contact_id, contact_phone_id)
    references public.contact_phones(organization_id, contact_id, id)
    on delete cascade
    deferrable initially deferred;

alter table public.source_attributions
  add constraint source_attributions_operation_opportunity_fkey
    foreign key (organization_id, operation_id, opportunity_id)
    references public.opportunities(organization_id, operation_id, id)
    on delete cascade,
  add constraint source_attributions_contact_opportunity_fkey
    foreign key (organization_id, contact_id, opportunity_id)
    references public.opportunities(organization_id, contact_id, id)
    on delete cascade
    deferrable initially deferred;

alter table public.opportunity_stage_history
  add constraint opportunity_stage_history_operation_opportunity_fkey
    foreign key (organization_id, operation_id, opportunity_id)
    references public.opportunities(organization_id, operation_id, id)
    on delete cascade;

alter table public.conversations
  add constraint conversations_ownership_writer_check
    check (
      (ownership_type = 'pedro' and assigned_membership_id is null)
      or (
        ownership_type = 'human'
        and assigned_membership_id is not null
      )
    ),
  add constraint conversations_operation_opportunity_fkey
    foreign key (organization_id, operation_id, opportunity_id)
    references public.opportunities(organization_id, operation_id, id)
    on delete cascade,
  add constraint conversations_contact_opportunity_fkey
    foreign key (organization_id, contact_id, opportunity_id)
    references public.opportunities(organization_id, contact_id, id)
    on delete cascade
    deferrable initially deferred;

alter table public.proactive_approach_requests
  add constraint proactive_requests_operation_opportunity_fkey
    foreign key (organization_id, operation_id, opportunity_id)
    references public.opportunities(organization_id, operation_id, id)
    on delete cascade;

alter table public.calls
  add constraint calls_organization_operation_id_key
    unique (organization_id, operation_id, id),
  add constraint calls_operation_opportunity_fkey
    foreign key (organization_id, operation_id, opportunity_id)
    references public.opportunities(organization_id, operation_id, id)
    on delete cascade;

alter table public.call_assignments
  add constraint call_assignments_operation_call_fkey
    foreign key (organization_id, operation_id, call_id)
    references public.calls(organization_id, operation_id, id)
    on delete cascade;

alter table public.call_offers
  add constraint call_offers_operation_call_fkey
    foreign key (organization_id, operation_id, call_id)
    references public.calls(organization_id, operation_id, id)
    on delete cascade;

create index calls_personal_pipeline_release_idx
  on public.calls (
    organization_id,
    operation_id,
    assigned_membership_id,
    scheduled_for,
    opportunity_id
  )
  where status in ('assigned', 'scheduled');

create index call_assignments_active_membership_call_idx
  on public.call_assignments (
    organization_id,
    operation_id,
    membership_id,
    call_id
  )
  where revoked_at is null;

-- Contact merge is a reversible, audited mapping rather than an
-- untraceable destructive rewrite.
create table public.contact_merges (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  survivor_contact_id uuid not null,
  merged_contact_id uuid not null,
  survivor_version_before bigint not null check (survivor_version_before > 0),
  merged_version_before bigint not null check (merged_version_before > 0),
  snapshot jsonb not null,
  merged_by_user_id uuid not null references auth.users(id),
  merged_by_membership_id uuid not null,
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (merged_contact_id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, survivor_contact_id)
    references public.contacts(organization_id, id),
  foreign key (organization_id, merged_contact_id)
    references public.contacts(organization_id, id),
  foreign key (organization_id, merged_by_membership_id)
    references public.memberships(organization_id, id),
  check (survivor_contact_id <> merged_contact_id),
  check (jsonb_typeof(snapshot) = 'object')
);

create table public.contact_merge_reversals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  contact_merge_id uuid not null unique,
  reversed_by_user_id uuid not null references auth.users(id),
  reversed_by_membership_id uuid not null,
  survivor_version_before bigint not null check (survivor_version_before > 0),
  merged_version_before bigint not null check (merged_version_before > 0),
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, contact_merge_id)
    references public.contact_merges(organization_id, id),
  foreign key (organization_id, reversed_by_membership_id)
    references public.memberships(organization_id, id)
);

create index contact_merges_operation_created_idx
  on public.contact_merges (organization_id, operation_id, created_at desc);
create index contact_merges_survivor_idx
  on public.contact_merges (organization_id, survivor_contact_id, created_at desc);

alter table public.contact_merges enable row level security;
alter table public.contact_merge_reversals enable row level security;

revoke all on table public.contact_merges from anon, authenticated;
revoke all on table public.contact_merge_reversals from anon, authenticated;
grant select on table public.contact_merges to authenticated;
grant select on table public.contact_merge_reversals to authenticated;
grant select, insert on table public.contact_merges to service_role;
grant select, insert on table public.contact_merge_reversals to service_role;

create policy contact_merges_select_operation_management
  on public.contact_merges
  for select
  to authenticated
  using (
    private.has_operation_role(operation_id, array['owner', 'manager'])
  );

create policy contact_merge_reversals_select_operation_management
  on public.contact_merge_reversals
  for select
  to authenticated
  using (
    private.has_operation_role(operation_id, array['owner', 'manager'])
  );

create or replace function private.reject_append_only_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end;
$$;

create trigger opportunity_stage_history_append_only
before update or delete on public.opportunity_stage_history
for each row execute function private.reject_append_only_mutation();

create trigger contact_merges_append_only
before update or delete on public.contact_merges
for each row execute function private.reject_append_only_mutation();

create trigger contact_merge_reversals_append_only
before update or delete on public.contact_merge_reversals
for each row execute function private.reject_append_only_mutation();

revoke update, delete on table public.opportunity_stage_history
  from service_role;
revoke all on function private.reject_append_only_mutation() from public;

-- A stage timestamp changes only with an authorized stage transition.
create or replace function private.guard_opportunity_stage_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.stage is distinct from old.stage then
    if current_setting('grillstudio.stage_transition_id', true)
      is distinct from new.id::text
    then
      raise exception 'opportunity stage must change through transition RPC'
        using errcode = '42501';
    end if;
    new.stage_entered_at := now();
  elsif new.stage_entered_at is distinct from old.stage_entered_at then
    raise exception 'stage_entered_at changes only with stage'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- Audit/history may be written by a service RPC after reauthentication. The
-- real human actor remains explicit instead of becoming the service role.
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
  actor_user_value uuid;
  actor_membership_value uuid;
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
  actor_user_value := coalesce(
    nullif(current_setting('grillstudio.actor_user_id', true), '')::uuid,
    auth.uid()
  );
  actor_membership_value := coalesce(
    nullif(current_setting('grillstudio.actor_membership_id', true), '')::uuid,
    private.actor_membership_id(new.operation_id)
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
    actor_user_value,
    actor_membership_value,
    trace_value,
    correlation_value
  );

  return new;
end;
$$;

-- Operation-scoped access. A management membership in another Operation of
-- the same organization no longer exposes this Contact.
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
      and private.has_operation_role(
        opportunity.operation_id,
        array['owner', 'manager']
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
    from public.opportunities as opportunity
    where opportunity.contact_id = target_contact_id
      and private.has_operation_role(
        opportunity.operation_id,
        array['owner', 'manager']
      )
  );
$$;

drop policy contact_phone_observations_select_managers
  on public.contact_phone_observations;
create policy contact_phone_observations_select_operation_management
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

drop policy opt_outs_select_operation_managers on public.opt_outs;
create policy opt_outs_select_operation_management
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

-- These variable-detail relations are available only through the authorized
-- Lead detail RPC, never as direct browser tables.
revoke select on table public.contact_phone_observations from authenticated;
revoke select on table public.source_attributions from authenticated;

-- Serialize Contact identity creation by (organization, exact E.164), then
-- delegate the established T04 base transaction.
alter function private.create_manual_lead(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) rename to create_manual_lead_t04_base;

revoke all on function private.create_manual_lead_t04_base(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) from public, anon, authenticated;

create function private.create_manual_lead(
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
  operation_organization_id uuid;
  normalized_phone text;
  actor_membership_id uuid;
  result jsonb;
  created_opportunity_id uuid;
  created_contact_id uuid;
  created_conversation_id uuid;
begin
  if auth.uid() is null
    or not private.has_operation_role(
      target_operation_id,
      array['owner', 'manager']
    )
  then
    raise exception 'manual lead permission denied' using errcode = '42501';
  end if;

  select operation.organization_id
  into strict operation_organization_id
  from public.operations as operation
  where operation.id = target_operation_id
    and operation.status = 'active';

  normalized_phone := private.normalize_phone_e164(phone_original, '+55');
  perform pg_advisory_xact_lock(
    hashtextextended(
      operation_organization_id::text || ':' || normalized_phone,
      0
    )
  );

  result := private.create_manual_lead_t04_base(
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

  created_opportunity_id := (result ->> 'opportunity_id')::uuid;
  created_contact_id := (result ->> 'contact_id')::uuid;

  if registration_action = 'assume' then
    actor_membership_id := private.actor_membership_id(target_operation_id);
    if actor_membership_id is null then
      raise exception 'manual lead permission denied' using errcode = '42501';
    end if;

    -- assigned_membership_id is the commercial assignee, not Conversation
    -- ownership. The ownership lives in exactly one open Conversation.
    update public.opportunities
    set assigned_membership_id = null
    where id = created_opportunity_id;

    insert into public.conversations (
      organization_id,
      operation_id,
      contact_id,
      opportunity_id,
      status,
      ownership_type,
      assigned_membership_id
    )
    values (
      operation_organization_id,
      target_operation_id,
      created_contact_id,
      created_opportunity_id,
      'active',
      'human',
      actor_membership_id
    )
    returning id into created_conversation_id;

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
      operation_organization_id,
      target_operation_id,
      auth.uid(),
      'conversation.assumed_on_manual_registration',
      'conversation',
      created_conversation_id,
      null,
      jsonb_build_object(
        'ownership_type', 'human',
        'assigned_membership_id', actor_membership_id,
        'opportunity_id', created_opportunity_id,
        'egress_created', false
      ),
      request_trace_id,
      request_correlation_id
    );

    result := result || jsonb_build_object(
      'conversation_id', created_conversation_id,
      'ownership_type', 'human'
    );
  end if;

  return result;
end;
$$;

revoke all on function private.create_manual_lead(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) from public;
grant execute on function private.create_manual_lead(
  uuid, text, text, text, text, text, text, integer, text, text, text, uuid, uuid
) to authenticated;

-- The generic T04 transition command manages only pre-Call stages and human
-- reactivation. T21 owns entry into Call agendada; T24 owns every post-Call
-- outcome and subsequent human stage.
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
  preliminary_operation_id uuid;
  opportunity_record public.opportunities%rowtype;
  post_call boolean;
  allowed boolean := false;
  before_state jsonb;
begin
  if auth.uid() is null then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;

  select opportunity.operation_id
  into preliminary_operation_id
  from public.opportunities as opportunity
  where opportunity.id = target_opportunity_id;

  if preliminary_operation_id is null
    or not private.has_operation_role(
      preliminary_operation_id,
      array['owner', 'manager']
    )
  then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;

  select opportunity.*
  into strict opportunity_record
  from public.opportunities as opportunity
  where opportunity.id = target_opportunity_id
  for update;

  if expected_version is null
    or opportunity_record.version <> expected_version
  then
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
    where call_record.organization_id = opportunity_record.organization_id
      and call_record.operation_id = opportunity_record.operation_id
      and call_record.opportunity_id = opportunity_record.id
      and call_record.status in ('completed', 'no_show')
  ) or exists (
    select 1
    from public.opportunity_stage_history as history
    where history.organization_id = opportunity_record.organization_id
      and history.operation_id = opportunity_record.operation_id
      and history.opportunity_id = opportunity_record.id
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
    when 'in_service' then target_stage = 'lost'
    when 'lost' then target_stage = 'in_service'
      and coalesce(human_decision, false)
    else false
  end;

  if not allowed then
    raise exception 'stage transition requires its domain command'
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
    'loss_reason', opportunity_record.loss_reason,
    'stage_entered_at', opportunity_record.stage_entered_at
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
      'stage_entered_at', opportunity_record.stage_entered_at,
      'human_decision', coalesce(human_decision, false)
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'id', opportunity_record.id,
    'stage', opportunity_record.stage,
    'stage_entered_at', opportunity_record.stage_entered_at,
    'version', opportunity_record.version
  );
end;
$$;

-- Reversible merge implementation with canonical locks and optimistic
-- versions on both Contacts.
drop function public.merge_contacts(uuid, uuid, uuid, uuid, uuid);
drop function private.merge_contacts(uuid, uuid, uuid, uuid, uuid);

create function private.merge_contacts(
  primary_contact_id uuid,
  duplicate_contact_id uuid,
  target_operation_id uuid,
  expected_primary_version bigint,
  expected_duplicate_version bigint,
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
  actor_membership_id uuid;
  primary_active_conversations bigint;
  duplicate_active_conversations bigint;
  merge_snapshot jsonb;
  merge_id uuid;
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

  -- Lock both Contacts and every open Conversation in UUID order to avoid
  -- reciprocal merge deadlocks.
  perform 1
  from public.contacts as contact
  where contact.id in (primary_contact_id, duplicate_contact_id)
  order by contact.id
  for update;

  select contact.*
  into primary_contact
  from public.contacts as contact
  where contact.id = primary_contact_id
    and contact.status = 'active';

  select contact.*
  into duplicate_contact
  from public.contacts as contact
  where contact.id = duplicate_contact_id
    and contact.status = 'active';

  if primary_contact.id is null or duplicate_contact.id is null
    or primary_contact.organization_id <> duplicate_contact.organization_id
  then
    raise exception 'contact merge permission denied' using errcode = '42501';
  end if;

  if primary_contact.version <> expected_primary_version
    or duplicate_contact.version <> expected_duplicate_version
  then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object(
        'code', '40001',
        'message', 'contact version conflict',
        'details', 'reload both Contacts before retrying',
        'hint', 'the merge did not run'
      )::text,
      detail = jsonb_build_object(
        'status', 409,
        'headers', jsonb_build_object()
      )::text;
  end if;

  if not exists (
    select 1
    from public.opportunities as opportunity
    where opportunity.operation_id = target_operation_id
      and opportunity.contact_id = primary_contact.id
  ) or not exists (
    select 1
    from public.opportunities as opportunity
    where opportunity.operation_id = target_operation_id
      and opportunity.contact_id = duplicate_contact.id
  ) then
    raise exception 'both Contacts must be visible in target Operation'
      using errcode = '42501';
  end if;

  perform 1
  from public.conversations as conversation
  where conversation.contact_id in (
    primary_contact.id,
    duplicate_contact.id
  )
  order by conversation.id
  for update;

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

  select jsonb_build_object(
    'primary_contact', to_jsonb(primary_contact),
    'duplicate_contact', to_jsonb(duplicate_contact),
    'phones', coalesce((
      select jsonb_agg(to_jsonb(phone) order by phone.id)
      from public.contact_phones as phone
      where phone.contact_id = duplicate_contact.id
    ), '[]'::jsonb),
    'phone_observations', coalesce((
      select jsonb_agg(to_jsonb(observation) order by observation.id)
      from public.contact_phone_observations as observation
      where observation.contact_id = duplicate_contact.id
    ), '[]'::jsonb),
    'opportunities', coalesce((
      select jsonb_agg(
        jsonb_build_object('id', opportunity.id, 'version', opportunity.version)
        order by opportunity.id
      )
      from public.opportunities as opportunity
      where opportunity.contact_id = duplicate_contact.id
    ), '[]'::jsonb),
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object('id', participant.id) order by participant.id)
      from public.opportunity_participants as participant
      where participant.contact_id = duplicate_contact.id
    ), '[]'::jsonb),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object('id', source.id) order by source.id)
      from public.source_attributions as source
      where source.contact_id = duplicate_contact.id
    ), '[]'::jsonb),
    'conversations', coalesce((
      select jsonb_agg(
        jsonb_build_object('id', conversation.id, 'version', conversation.version)
        order by conversation.id
      )
      from public.conversations as conversation
      where conversation.contact_id = duplicate_contact.id
    ), '[]'::jsonb),
    'opt_outs', coalesce((
      select jsonb_agg(to_jsonb(opt_out) order by opt_out.id)
      from public.opt_outs as opt_out
      where opt_out.contact_id = duplicate_contact.id
    ), '[]'::jsonb)
  )
  into merge_snapshot;

  actor_membership_id := private.actor_membership_id(target_operation_id);

  insert into public.contact_merges (
    organization_id,
    operation_id,
    survivor_contact_id,
    merged_contact_id,
    survivor_version_before,
    merged_version_before,
    snapshot,
    merged_by_user_id,
    merged_by_membership_id,
    trace_id,
    correlation_id
  )
  values (
    primary_contact.organization_id,
    target_operation_id,
    primary_contact.id,
    duplicate_contact.id,
    primary_contact.version,
    duplicate_contact.version,
    merge_snapshot,
    auth.uid(),
    actor_membership_id,
    request_trace_id,
    request_correlation_id
  )
  returning id into merge_id;

  update public.contact_phone_observations
  set contact_id = primary_contact.id
  where contact_id = duplicate_contact.id;

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
    'contact_merge',
    merge_id,
    jsonb_build_object(
      'primary_contact_id', primary_contact.id,
      'duplicate_contact_id', duplicate_contact.id,
      'primary_version', primary_contact.version,
      'duplicate_version', duplicate_contact.version,
      'primary_active_conversations', primary_active_conversations,
      'duplicate_active_conversations', duplicate_active_conversations
    ),
    jsonb_build_object(
      'survivor_contact_id', primary_contact.id,
      'merged_contact_id', duplicate_contact.id,
      'reversible', true
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'contact_id', primary_contact.id,
    'merged_contact_id', duplicate_contact.id,
    'contact_merge_id', merge_id,
    'primary_version', primary_contact.version + 1,
    'duplicate_version', duplicate_contact.version + 1
  );
end;
$$;

create function public.merge_contacts(
  primary_contact_id uuid,
  duplicate_contact_id uuid,
  target_operation_id uuid,
  expected_primary_version bigint,
  expected_duplicate_version bigint,
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
    expected_primary_version,
    expected_duplicate_version,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function private.merge_contacts(
  uuid, uuid, uuid, bigint, bigint, uuid, uuid
) from public;
revoke all on function public.merge_contacts(
  uuid, uuid, uuid, bigint, bigint, uuid, uuid
) from public;
grant execute on function private.merge_contacts(
  uuid, uuid, uuid, bigint, bigint, uuid, uuid
) to authenticated;
grant execute on function public.merge_contacts(
  uuid, uuid, uuid, bigint, bigint, uuid, uuid
) to authenticated;

create function private.reverse_contact_merge(
  target_contact_merge_id uuid,
  expected_primary_version bigint,
  expected_duplicate_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  merge_record public.contact_merges%rowtype;
  primary_contact public.contacts%rowtype;
  duplicate_contact public.contacts%rowtype;
  actor_membership_id uuid;
  snapshot_item jsonb;
  expected_entity_version bigint;
begin
  if auth.uid() is null then
    raise exception 'contact merge reversal permission denied'
      using errcode = '42501';
  end if;

  select contact_merge.*
  into merge_record
  from public.contact_merges as contact_merge
  where contact_merge.id = target_contact_merge_id;

  if merge_record.id is null
    or not private.has_operation_role(
      merge_record.operation_id,
      array['owner', 'manager']
    )
  then
    raise exception 'contact merge reversal permission denied'
      using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.contact_merge_reversals as reversal
    where reversal.contact_merge_id = merge_record.id
  ) then
    raise exception 'contact merge is already reversed'
      using errcode = '23514';
  end if;

  perform 1
  from public.contacts as contact
  where contact.id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by contact.id
  for update;

  select * into strict primary_contact
  from public.contacts
  where id = merge_record.survivor_contact_id;
  select * into strict duplicate_contact
  from public.contacts
  where id = merge_record.merged_contact_id;

  if primary_contact.version <> expected_primary_version
    or duplicate_contact.version <> expected_duplicate_version
  then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object(
        'code', '40001',
        'message', 'contact version conflict',
        'details', 'reload both Contacts before reversing',
        'hint', 'the reversal did not run'
      )::text,
      detail = jsonb_build_object(
        'status', 409,
        'headers', jsonb_build_object()
      )::text;
  end if;

  if duplicate_contact.status <> 'merged'
    or duplicate_contact.merged_into_contact_id <> primary_contact.id
  then
    raise exception 'contact merge mapping changed after merge'
      using errcode = '23514';
  end if;

  perform 1
  from public.conversations as conversation
  where conversation.id in (
    select (item ->> 'id')::uuid
    from jsonb_array_elements(
      merge_record.snapshot -> 'conversations'
    ) as item
  )
  order by conversation.id
  for update;

  for snapshot_item in
    select item
    from jsonb_array_elements(
      merge_record.snapshot -> 'opportunities'
    ) as item
  loop
    expected_entity_version := (snapshot_item ->> 'version')::bigint + 1;
    if not exists (
      select 1
      from public.opportunities as opportunity
      where opportunity.id = (snapshot_item ->> 'id')::uuid
        and opportunity.contact_id = primary_contact.id
        and opportunity.version = expected_entity_version
    ) then
      raise exception 'merged Opportunity changed after merge'
        using errcode = '23514';
    end if;
  end loop;

  for snapshot_item in
    select item
    from jsonb_array_elements(
      merge_record.snapshot -> 'conversations'
    ) as item
  loop
    expected_entity_version := (snapshot_item ->> 'version')::bigint + 1;
    if not exists (
      select 1
      from public.conversations as conversation
      where conversation.id = (snapshot_item ->> 'id')::uuid
        and conversation.contact_id = primary_contact.id
        and conversation.version = expected_entity_version
    ) then
      raise exception 'merged Conversation changed after merge'
        using errcode = '23514';
    end if;
  end loop;

  update public.contact_phones as phone
  set
    contact_id = duplicate_contact.id,
    is_primary = (snapshot_phone.item ->> 'is_primary')::boolean
  from jsonb_array_elements(
    merge_record.snapshot -> 'phones'
  ) as snapshot_phone(item)
  where phone.id = (snapshot_phone.item ->> 'id')::uuid
    and phone.contact_id = primary_contact.id;

  update public.contact_phone_observations as observation
  set contact_id = duplicate_contact.id
  from jsonb_array_elements(
    merge_record.snapshot -> 'phone_observations'
  ) as snapshot_observation(item)
  where observation.id = (snapshot_observation.item ->> 'id')::uuid
    and observation.contact_id = primary_contact.id;

  update public.opportunities as opportunity
  set
    contact_id = duplicate_contact.id,
    updated_at = now(),
    version = opportunity.version + 1
  from jsonb_array_elements(
    merge_record.snapshot -> 'opportunities'
  ) as snapshot_opportunity(item)
  where opportunity.id = (snapshot_opportunity.item ->> 'id')::uuid
    and opportunity.contact_id = primary_contact.id;

  update public.opportunity_participants as participant
  set contact_id = duplicate_contact.id
  from jsonb_array_elements(
    merge_record.snapshot -> 'participants'
  ) as snapshot_participant(item)
  where participant.id = (snapshot_participant.item ->> 'id')::uuid
    and participant.contact_id = primary_contact.id;

  update public.source_attributions as source
  set contact_id = duplicate_contact.id
  from jsonb_array_elements(
    merge_record.snapshot -> 'sources'
  ) as snapshot_source(item)
  where source.id = (snapshot_source.item ->> 'id')::uuid
    and source.contact_id = primary_contact.id;

  update public.conversations as conversation
  set
    contact_id = duplicate_contact.id,
    updated_at = now(),
    version = conversation.version + 1
  from jsonb_array_elements(
    merge_record.snapshot -> 'conversations'
  ) as snapshot_conversation(item)
  where conversation.id = (snapshot_conversation.item ->> 'id')::uuid
    and conversation.contact_id = primary_contact.id;

  update public.opt_outs as opt_out
  set
    contact_id = duplicate_contact.id,
    status = snapshot_opt_out.item ->> 'status',
    reason = snapshot_opt_out.item ->> 'reason',
    requested_at = (snapshot_opt_out.item ->> 'requested_at')::timestamptz,
    revoked_at = nullif(
      snapshot_opt_out.item ->> 'revoked_at',
      ''
    )::timestamptz
  from jsonb_array_elements(
    merge_record.snapshot -> 'opt_outs'
  ) as snapshot_opt_out(item)
  where opt_out.id = (snapshot_opt_out.item ->> 'id')::uuid
    and opt_out.contact_id = primary_contact.id;

  update public.contacts
  set
    display_name = merge_record.snapshot
      -> 'primary_contact' ->> 'display_name',
    updated_at = now(),
    version = version + 1
  where id = primary_contact.id;

  update public.contacts
  set
    display_name = merge_record.snapshot
      -> 'duplicate_contact' ->> 'display_name',
    status = 'active',
    merged_into_contact_id = null,
    updated_at = now(),
    version = version + 1
  where id = duplicate_contact.id;

  actor_membership_id := private.actor_membership_id(
    merge_record.operation_id
  );

  insert into public.contact_merge_reversals (
    organization_id,
    operation_id,
    contact_merge_id,
    reversed_by_user_id,
    reversed_by_membership_id,
    survivor_version_before,
    merged_version_before,
    trace_id,
    correlation_id
  )
  values (
    merge_record.organization_id,
    merge_record.operation_id,
    merge_record.id,
    auth.uid(),
    actor_membership_id,
    primary_contact.version,
    duplicate_contact.version,
    request_trace_id,
    request_correlation_id
  );

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
    merge_record.organization_id,
    merge_record.operation_id,
    auth.uid(),
    'contact.merge_reversed',
    'contact_merge',
    merge_record.id,
    jsonb_build_object(
      'survivor_contact_id', primary_contact.id,
      'merged_contact_id', duplicate_contact.id
    ),
    jsonb_build_object(
      'primary_contact_status', 'active',
      'duplicate_contact_status', 'active',
      'mapping_preserved', true
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'contact_merge_id', merge_record.id,
    'primary_contact_id', primary_contact.id,
    'duplicate_contact_id', duplicate_contact.id,
    'primary_version', primary_contact.version + 1,
    'duplicate_version', duplicate_contact.version + 1,
    'reversed', true
  );
end;
$$;

create function public.reverse_contact_merge(
  target_contact_merge_id uuid,
  expected_primary_version bigint,
  expected_duplicate_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.reverse_contact_merge(
    target_contact_merge_id,
    expected_primary_version,
    expected_duplicate_version,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function private.reverse_contact_merge(
  uuid, bigint, bigint, uuid, uuid
) from public;
revoke all on function public.reverse_contact_merge(
  uuid, bigint, bigint, uuid, uuid
) from public;
grant execute on function private.reverse_contact_merge(
  uuid, bigint, bigint, uuid, uuid
) to authenticated;
grant execute on function public.reverse_contact_merge(
  uuid, bigint, bigint, uuid, uuid
) to authenticated;

-- Scope is explicit. `operation` is the full management projection.
-- `my_pipeline` is always the Corretor projection, even for dual-role users,
-- and remains redacted until T21 owns the release predicate.
drop function public.get_pipeline_board(uuid);
drop function public.get_lead_list(uuid);
drop function private.get_pipeline_board(uuid);
drop function private.get_lead_list(uuid);

create function private.get_lead_list(
  target_operation_id uuid,
  view_scope text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_id uuid;
  actor_is_broker boolean;
  actor_is_management boolean;
  result jsonb;
begin
  actor_id := private.actor_membership_id(target_operation_id);
  if actor_id is null then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;

  if view_scope not in ('operation', 'my_pipeline') then
    raise exception 'invalid pipeline view scope' using errcode = '22023';
  end if;

  actor_is_management := private.has_operation_role(
    target_operation_id,
    array['owner', 'manager']
  );
  actor_is_broker := exists (
    select 1
    from public.membership_roles as membership_role
    where membership_role.membership_id = actor_id
      and membership_role.role = 'broker'
  );

  if view_scope = 'operation' and not actor_is_management then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;
  if view_scope = 'my_pipeline' and not actor_is_broker then
    raise exception 'pipeline permission denied' using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(card.payload order by card.updated_at desc, card.id),
    '[]'::jsonb
  )
  into result
  from (
    select
      opportunity.id,
      opportunity.updated_at,
      case
        when view_scope = 'operation' then jsonb_build_object(
          'id', opportunity.id,
          'contact_id', opportunity.contact_id,
          'display_name', contact.display_name,
          'phone_e164', phone.e164,
          'phone_original', phone.original_value,
          'source_type', opportunity.source_type,
          'stage', opportunity.stage,
          'stage_entered_at', opportunity.stage_entered_at,
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
          'scheduled_for', released_call.scheduled_for,
          'redacted', false,
          'view_scope', 'operation',
          'allowed_actions', case opportunity.stage
            when 'new' then jsonb_build_array('in_service', 'lost')
            when 'in_service' then jsonb_build_array('lost')
            when 'lost' then jsonb_build_array('in_service')
            else '[]'::jsonb
          end,
          'created_at', opportunity.created_at,
          'updated_at', opportunity.updated_at,
          'version', opportunity.version
        )
        else jsonb_build_object(
          'id', opportunity.id,
          'contact_id', null,
          'display_name', null,
          'phone_e164', null,
          'phone_original', null,
          'source_type', null,
          'stage', opportunity.stage,
          'stage_entered_at', opportunity.stage_entered_at,
          'assigned_membership_id', actor_id,
          'assigned_name', null,
          'unit_count', null,
          'amount_scope', null,
          'has_opt_out', null,
          'scheduled_for', released_call.scheduled_for,
          'redacted', true,
          'view_scope', 'my_pipeline',
          'allowed_actions', '[]'::jsonb,
          'created_at', opportunity.created_at,
          'updated_at', opportunity.updated_at,
          'version', opportunity.version
        )
      end as payload
    from public.opportunities as opportunity
    join public.contacts as contact
      on contact.id = opportunity.contact_id
    left join lateral (
      select contact_phone.e164, contact_phone.original_value
      from public.contact_phones as contact_phone
      where contact_phone.contact_id = contact.id
      order by
        contact_phone.is_primary desc,
        contact_phone.created_at,
        contact_phone.id
      limit 1
    ) as phone on true
    left join public.staff_profiles as staff_profile
      on staff_profile.membership_id = opportunity.assigned_membership_id
    left join lateral (
      select call_record.id, call_record.scheduled_for
      from public.calls as call_record
      where call_record.organization_id = opportunity.organization_id
        and call_record.operation_id = opportunity.operation_id
        and call_record.opportunity_id = opportunity.id
        and call_record.assigned_membership_id =
          opportunity.assigned_membership_id
        and call_record.status in ('assigned', 'scheduled')
        and exists (
          select 1
          from public.call_assignments as assignment
          where assignment.organization_id = call_record.organization_id
            and assignment.operation_id = call_record.operation_id
            and assignment.call_id = call_record.id
            and assignment.membership_id =
              call_record.assigned_membership_id
            and assignment.revoked_at is null
        )
      order by call_record.scheduled_for, call_record.id
      limit 1
    ) as released_call on true
    where opportunity.operation_id = target_operation_id
      and (
        view_scope = 'operation'
        or (
          opportunity.assigned_membership_id = actor_id
          and released_call.id is not null
          and released_call.scheduled_for >= now()
          and released_call.scheduled_for <= now() + interval '30 minutes'
        )
      )
  ) as card;

  return result;
end;
$$;

create function private.get_pipeline_board(
  target_operation_id uuid,
  view_scope text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
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
    private.get_lead_list(target_operation_id, view_scope)
  );
$$;

create function public.get_lead_list(
  target_operation_id uuid,
  view_scope text
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_lead_list(target_operation_id, view_scope);
$$;

create function public.get_pipeline_board(
  target_operation_id uuid,
  view_scope text
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_pipeline_board(target_operation_id, view_scope);
$$;

revoke all on function private.get_lead_list(uuid, text) from public;
revoke all on function private.get_pipeline_board(uuid, text) from public;
revoke all on function public.get_lead_list(uuid, text) from public;
revoke all on function public.get_pipeline_board(uuid, text) from public;
grant execute on function private.get_lead_list(uuid, text) to authenticated;
grant execute on function private.get_pipeline_board(uuid, text) to authenticated;
grant execute on function public.get_lead_list(uuid, text) to authenticated;
grant execute on function public.get_pipeline_board(uuid, text) to authenticated;

-- Management-only detail; no Contact/phone/Conversation/source metadata is
-- released to a broker before T21.
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
  result jsonb;
begin
  select opportunity.*
  into opportunity_record
  from public.opportunities as opportunity
  where opportunity.id = target_opportunity_id;

  if opportunity_record.id is null
    or not private.has_operation_role(
      opportunity_record.operation_id,
      array['owner', 'manager']
    )
  then
    raise exception 'lead detail permission denied' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'id', opportunity.id,
    'contact_id', opportunity.contact_id,
    'contact_version', contact.version,
    'display_name', contact.display_name,
    'contact_status', contact.status,
    'stage', opportunity.stage,
    'stage_entered_at', opportunity.stage_entered_at,
    'allowed_actions', case opportunity.stage
      when 'new' then jsonb_build_array('in_service', 'lost')
      when 'in_service' then jsonb_build_array('lost')
      when 'lost' then jsonb_build_array('in_service')
      else '[]'::jsonb
    end,
    'source_type', opportunity.source_type,
    'assigned_membership_id', opportunity.assigned_membership_id,
    'assigned_name', staff_profile.full_name,
    'unit_count', opportunity.unit_count,
    'amount_scope', opportunity.amount_scope,
    'pedro_context', opportunity.pedro_context,
    'internal_note', (
      select internal_note.note
      from private.opportunity_internal_notes as internal_note
      where internal_note.opportunity_id = opportunity.id
    ),
    'loss_reason', opportunity.loss_reason,
    'created_at', opportunity.created_at,
    'updated_at', opportunity.updated_at,
    'version', opportunity.version,
    'phones', coalesce((
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
    ), '[]'::jsonb),
    'participants', coalesce((
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
    ), '[]'::jsonb),
    'sources', coalesce((
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
    ), '[]'::jsonb),
    'history', coalesce((
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
    ), '[]'::jsonb),
    'conversations', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', conversation.id,
          'status', conversation.status,
          'ownership_type', conversation.ownership_type,
          'assigned_membership_id', conversation.assigned_membership_id,
          'opened_at', conversation.opened_at
        )
        order by conversation.opened_at desc
      )
      from public.conversations as conversation
      where conversation.opportunity_id = opportunity.id
    ), '[]'::jsonb),
    'has_opt_out', exists (
      select 1
      from public.opt_outs as opt_out
      where opt_out.contact_id = contact.id
        and opt_out.status = 'active'
    ),
    'proactive_request', (
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
    ),
    'latest_merge', (
      select jsonb_build_object(
        'id', contact_merge.id,
        'merged_contact_id', contact_merge.merged_contact_id,
        'reversed', exists (
          select 1
          from public.contact_merge_reversals as reversal
          where reversal.contact_merge_id = contact_merge.id
        )
      )
      from public.contact_merges as contact_merge
      where contact_merge.survivor_contact_id = contact.id
      order by contact_merge.created_at desc
      limit 1
    )
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
  result jsonb;
begin
  if auth.uid() is null
    or not private.has_operation_role(
      target_operation_id,
      array['owner', 'manager']
    )
    or not exists (
      select 1
      from public.opportunities as opportunity
      where opportunity.operation_id = target_operation_id
        and opportunity.contact_id = excluded_contact_id
    )
  then
    raise exception 'contact merge permission denied' using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', contact.id,
        'version', contact.version,
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
    order by
      contact_phone.is_primary desc,
      contact_phone.created_at,
      contact_phone.id
    limit 1
  ) as phone on true
  where contact.status = 'active'
    and contact.id <> excluded_contact_id
    and exists (
      select 1
      from public.opportunities as opportunity
      where opportunity.operation_id = target_operation_id
        and opportunity.contact_id = contact.id
    );

  return result;
end;
$$;

-- Extend T02 deactivation without reimplementing its authentication/session
-- boundary. Future accepted Calls return to distribution, their
-- call_scheduled Opportunities return to in_service and no replacement is
-- selected.
alter function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) rename to deactivate_membership_after_reauthentication_t02_base;

revoke all on function
  private.deactivate_membership_after_reauthentication_t02_base(
    uuid, uuid, uuid, uuid, uuid
  )
  from public, anon, authenticated, service_role;

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
declare
  result_record record;
  actor_membership_id uuid;
  affected_opportunity_id uuid;
  affected_opportunity_ids uuid[];
  before_record public.opportunities%rowtype;
  after_record public.opportunities%rowtype;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select membership.id
  into actor_membership_id
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = actor_user_id
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  select coalesce(array_agg(distinct opportunity.id), array[]::uuid[])
  into affected_opportunity_ids
  from public.opportunities as opportunity
  join public.calls as call_record
    on call_record.organization_id = opportunity.organization_id
    and call_record.operation_id = opportunity.operation_id
    and call_record.opportunity_id = opportunity.id
  where opportunity.operation_id = target_operation_id
    and opportunity.assigned_membership_id = target_membership_id
    and opportunity.stage = 'call_scheduled'
    and call_record.assigned_membership_id = target_membership_id
    and call_record.scheduled_for > now()
    and call_record.status in ('assigned', 'scheduled');

  select *
  into strict result_record
  from private.deactivate_membership_after_reauthentication_t02_base(
    actor_user_id,
    target_membership_id,
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );

  perform set_config(
    'grillstudio.actor_user_id',
    actor_user_id::text,
    true
  );
  perform set_config(
    'grillstudio.actor_membership_id',
    actor_membership_id::text,
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
    'call_redistributed_member_deactivated',
    true
  );

  foreach affected_opportunity_id in array affected_opportunity_ids
  loop
    select *
    into before_record
    from public.opportunities
    where id = affected_opportunity_id
    for update;

    perform set_config(
      'grillstudio.stage_transition_id',
      affected_opportunity_id::text,
      true
    );

    update public.opportunities
    set
      assigned_membership_id = null,
      stage = 'in_service',
      loss_reason = null,
      updated_at = now(),
      version = version + 1
    where id = affected_opportunity_id
      and stage = 'call_scheduled'
    returning * into after_record;

    if after_record.id is not null then
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
        after_record.organization_id,
        after_record.operation_id,
        actor_user_id,
        'opportunity.returned_to_service_on_member_deactivation',
        'opportunity',
        after_record.id,
        jsonb_build_object(
          'stage', before_record.stage,
          'assigned_membership_id', before_record.assigned_membership_id
        ),
        jsonb_build_object(
          'stage', after_record.stage,
          'assigned_membership_id', after_record.assigned_membership_id,
          'random_reassignment', false
        ),
        request_trace_id,
        request_correlation_id
      );
    end if;
  end loop;

  return query
  select
    result_record.future_calls,
    result_record.calls_within_one_hour,
    result_record.post_call_opportunities,
    result_record.revoked_sessions;
end;
$$;

revoke all on function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) from public;
grant execute on function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) to service_role;
