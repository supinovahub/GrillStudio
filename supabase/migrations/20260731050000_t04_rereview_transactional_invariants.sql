-- T04 re-review: close the remaining transactional invariants without
-- implementing the T21 Call or T24 post-Call domain commands.

-- The immutable merge log may contain multiple merge/reversal cycles for the
-- same Contact. A small private projection owns the one-active-merge
-- invariant while both the merge and reversal logs remain append-only.
create table private.active_contact_merges (
  organization_id uuid not null,
  merged_contact_id uuid not null,
  contact_merge_id uuid not null,
  activated_at timestamptz not null default now(),
  primary key (organization_id, merged_contact_id),
  unique (contact_merge_id),
  foreign key (organization_id, merged_contact_id)
    references public.contacts(organization_id, id),
  foreign key (organization_id, contact_merge_id)
    references public.contact_merges(organization_id, id)
    on delete cascade
);

revoke all on table private.active_contact_merges
  from public, anon, authenticated, service_role;

insert into private.active_contact_merges (
  organization_id,
  merged_contact_id,
  contact_merge_id,
  activated_at
)
select
  contact_merge.organization_id,
  contact_merge.merged_contact_id,
  contact_merge.id,
  contact_merge.created_at
from public.contact_merges as contact_merge
where not exists (
  select 1
  from public.contact_merge_reversals as reversal
  where reversal.contact_merge_id = contact_merge.id
);

alter table public.contact_merges
  drop constraint contact_merges_merged_contact_id_key;

create index active_contact_merges_log_fk_idx
  on private.active_contact_merges (organization_id, contact_merge_id);

-- A canonical state includes every row currently owned by either Contact.
-- Exact jsonb equality plus the stored hash detects insertions, deletions,
-- ownership changes and field/version mutations.
create or replace function private.contact_merge_canonical_state(
  first_contact_id uuid,
  second_contact_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'contacts',
    coalesce((
      select jsonb_agg(to_jsonb(contact_row) order by contact_row.id)
      from (
        select contact.*
        from public.contacts as contact
        where contact.id in (first_contact_id, second_contact_id)
      ) as contact_row
    ), '[]'::jsonb),
    'phones',
    coalesce((
      select jsonb_agg(to_jsonb(phone_row) order by phone_row.id)
      from (
        select phone.*
        from public.contact_phones as phone
        where phone.contact_id in (first_contact_id, second_contact_id)
      ) as phone_row
    ), '[]'::jsonb),
    'phone_observations',
    coalesce((
      select jsonb_agg(
        to_jsonb(observation_row)
        order by observation_row.id
      )
      from (
        select observation.*
        from public.contact_phone_observations as observation
        where observation.contact_id in (
          first_contact_id,
          second_contact_id
        )
      ) as observation_row
    ), '[]'::jsonb),
    'opportunities',
    coalesce((
      select jsonb_agg(
        to_jsonb(opportunity_row)
        order by opportunity_row.id
      )
      from (
        select opportunity.*
        from public.opportunities as opportunity
        where opportunity.contact_id in (
          first_contact_id,
          second_contact_id
        )
      ) as opportunity_row
    ), '[]'::jsonb),
    'participants',
    coalesce((
      select jsonb_agg(
        to_jsonb(participant_row)
        order by participant_row.id
      )
      from (
        select participant.*
        from public.opportunity_participants as participant
        where participant.contact_id in (
          first_contact_id,
          second_contact_id
        )
      ) as participant_row
    ), '[]'::jsonb),
    'sources',
    coalesce((
      select jsonb_agg(to_jsonb(source_row) order by source_row.id)
      from (
        select source.*
        from public.source_attributions as source
        where source.contact_id in (first_contact_id, second_contact_id)
      ) as source_row
    ), '[]'::jsonb),
    'conversations',
    coalesce((
      select jsonb_agg(
        to_jsonb(conversation_row)
        order by conversation_row.id
      )
      from (
        select conversation.*
        from public.conversations as conversation
        where conversation.contact_id in (
          first_contact_id,
          second_contact_id
        )
      ) as conversation_row
    ), '[]'::jsonb),
    'opt_outs',
    coalesce((
      select jsonb_agg(to_jsonb(opt_out_row) order by opt_out_row.id)
      from (
        select opt_out.*
        from public.opt_outs as opt_out
        where opt_out.contact_id in (first_contact_id, second_contact_id)
      ) as opt_out_row
    ), '[]'::jsonb)
  );
$$;

create or replace function private.canonical_jsonb_hash(value jsonb)
returns text
language sql
immutable
strict
set search_path = ''
as $$
  select pg_catalog.md5(value::text);
$$;

revoke all on function private.contact_merge_canonical_state(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.canonical_jsonb_hash(jsonb)
  from public, anon, authenticated, service_role;

-- The generic T04 command cannot decide a loss after any completed/no-show
-- Call or post-Call history. That decision belongs to T24.
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
    and opportunity_record.stage in ('new', 'in_service')
    and post_call
  then
    raise exception 'post-call loss requires the T24 domain command'
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

create or replace function private.merge_contacts(
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
  pre_merge_snapshot jsonb;
  post_merge_snapshot jsonb;
  merge_snapshot jsonb;
  merge_id uuid := gen_random_uuid();
  merge_timestamp timestamptz := transaction_timestamp();
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

  if exists (
    select 1
    from private.active_contact_merges as active_merge
    where active_merge.organization_id = duplicate_contact.organization_id
      and active_merge.merged_contact_id = duplicate_contact.id
  ) then
    raise exception 'duplicate Contact already has an active merge'
      using errcode = '23514';
  end if;

  -- Lock the complete two-Contact aggregate in a stable table/id order.
  perform 1
  from public.contact_phones as phone
  where phone.contact_id in (primary_contact.id, duplicate_contact.id)
  order by phone.id
  for update;

  perform 1
  from public.contact_phone_observations as observation
  where observation.contact_id in (
    primary_contact.id,
    duplicate_contact.id
  )
  order by observation.id
  for update;

  perform 1
  from public.opportunities as opportunity
  where opportunity.contact_id in (
    primary_contact.id,
    duplicate_contact.id
  )
  order by opportunity.id
  for update;

  perform 1
  from public.opportunity_participants as participant
  where participant.contact_id in (
    primary_contact.id,
    duplicate_contact.id
  )
  order by participant.id
  for update;

  perform 1
  from public.source_attributions as source
  where source.contact_id in (primary_contact.id, duplicate_contact.id)
  order by source.id
  for update;

  perform 1
  from public.conversations as conversation
  where conversation.contact_id in (
    primary_contact.id,
    duplicate_contact.id
  )
  order by conversation.id
  for update;

  perform 1
  from public.opt_outs as opt_out
  where opt_out.contact_id in (primary_contact.id, duplicate_contact.id)
  order by opt_out.id
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

  pre_merge_snapshot := private.contact_merge_canonical_state(
    primary_contact.id,
    duplicate_contact.id
  );

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
    updated_at = merge_timestamp,
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
    updated_at = merge_timestamp,
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
      revoked_at = merge_timestamp,
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
    updated_at = merge_timestamp,
    version = version + 1
  where id = primary_contact.id;

  update public.contacts
  set
    status = 'merged',
    merged_into_contact_id = primary_contact.id,
    updated_at = merge_timestamp,
    version = version + 1
  where id = duplicate_contact.id;

  post_merge_snapshot := private.contact_merge_canonical_state(
    primary_contact.id,
    duplicate_contact.id
  );
  merge_snapshot := jsonb_build_object(
    'schema_version', 2,
    'pre_merge', pre_merge_snapshot,
    'post_merge', post_merge_snapshot,
    'post_merge_hash',
    private.canonical_jsonb_hash(post_merge_snapshot)
  );
  actor_membership_id := private.actor_membership_id(target_operation_id);

  insert into public.contact_merges (
    id,
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
    correlation_id,
    created_at
  )
  values (
    merge_id,
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
    request_correlation_id,
    merge_timestamp
  );

  insert into private.active_contact_merges (
    organization_id,
    merged_contact_id,
    contact_merge_id,
    activated_at
  )
  values (
    duplicate_contact.organization_id,
    duplicate_contact.id,
    merge_id,
    merge_timestamp
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
      'reversible', true,
      'snapshot_hash',
      private.canonical_jsonb_hash(post_merge_snapshot)
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

create or replace function private.reverse_contact_merge(
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
  pre_merge_snapshot jsonb;
  expected_post_merge_snapshot jsonb;
  current_post_merge_snapshot jsonb;
  deleted_active_projection bigint;
  reversal_timestamp timestamptz := transaction_timestamp();
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

  if coalesce((merge_record.snapshot ->> 'schema_version')::integer, 0) <> 2
  then
    raise exception 'contact merge snapshot cannot be safely reversed'
      using errcode = '23514';
  end if;

  perform 1
  from private.active_contact_merges as active_merge
  where active_merge.organization_id = merge_record.organization_id
    and active_merge.merged_contact_id = merge_record.merged_contact_id
    and active_merge.contact_merge_id = merge_record.id
  for update;

  if not found or exists (
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

  -- Lock every row in the state before recomputing its canonical hash.
  perform 1
  from public.contact_phones as phone
  where phone.contact_id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by phone.id
  for update;

  perform 1
  from public.contact_phone_observations as observation
  where observation.contact_id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by observation.id
  for update;

  perform 1
  from public.opportunities as opportunity
  where opportunity.contact_id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by opportunity.id
  for update;

  perform 1
  from public.opportunity_participants as participant
  where participant.contact_id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by participant.id
  for update;

  perform 1
  from public.source_attributions as source
  where source.contact_id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by source.id
  for update;

  perform 1
  from public.conversations as conversation
  where conversation.contact_id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by conversation.id
  for update;

  perform 1
  from public.opt_outs as opt_out
  where opt_out.contact_id in (
    merge_record.survivor_contact_id,
    merge_record.merged_contact_id
  )
  order by opt_out.id
  for update;

  select contact.*
  into strict primary_contact
  from public.contacts as contact
  where contact.id = merge_record.survivor_contact_id;

  select contact.*
  into strict duplicate_contact
  from public.contacts as contact
  where contact.id = merge_record.merged_contact_id;

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

  pre_merge_snapshot := merge_record.snapshot -> 'pre_merge';
  expected_post_merge_snapshot := merge_record.snapshot -> 'post_merge';
  current_post_merge_snapshot := private.contact_merge_canonical_state(
    primary_contact.id,
    duplicate_contact.id
  );

  if current_post_merge_snapshot is distinct from expected_post_merge_snapshot
    or private.canonical_jsonb_hash(current_post_merge_snapshot)
      is distinct from merge_record.snapshot ->> 'post_merge_hash'
  then
    raise exception
      'contact merge aggregate changed after merge; reversal aborted'
      using errcode = '23514';
  end if;

  -- Validation is complete. Only now may the reversal mutate aggregate rows.
  update public.contact_phones as phone
  set is_primary = false
  where phone.id in (
    select (item ->> 'id')::uuid
    from jsonb_array_elements(pre_merge_snapshot -> 'phones') as item
  );

  update public.contact_phones as phone
  set
    contact_id = (snapshot_phone.item ->> 'contact_id')::uuid,
    is_primary = (snapshot_phone.item ->> 'is_primary')::boolean
  from jsonb_array_elements(
    pre_merge_snapshot -> 'phones'
  ) as snapshot_phone(item)
  where phone.id = (snapshot_phone.item ->> 'id')::uuid;

  update public.contact_phone_observations as observation
  set contact_id = (snapshot_observation.item ->> 'contact_id')::uuid
  from jsonb_array_elements(
    pre_merge_snapshot -> 'phone_observations'
  ) as snapshot_observation(item)
  where observation.id = (snapshot_observation.item ->> 'id')::uuid;

  update public.opportunities as opportunity
  set
    contact_id = duplicate_contact.id,
    updated_at = reversal_timestamp,
    version = opportunity.version + 1
  from jsonb_array_elements(
    pre_merge_snapshot -> 'opportunities'
  ) as snapshot_opportunity(item)
  where opportunity.id = (snapshot_opportunity.item ->> 'id')::uuid
    and (snapshot_opportunity.item ->> 'contact_id')::uuid =
      duplicate_contact.id;

  update public.opportunity_participants as participant
  set contact_id = duplicate_contact.id
  from jsonb_array_elements(
    pre_merge_snapshot -> 'participants'
  ) as snapshot_participant(item)
  where participant.id = (snapshot_participant.item ->> 'id')::uuid
    and (snapshot_participant.item ->> 'contact_id')::uuid =
      duplicate_contact.id;

  update public.source_attributions as source
  set contact_id = duplicate_contact.id
  from jsonb_array_elements(
    pre_merge_snapshot -> 'sources'
  ) as snapshot_source(item)
  where source.id = (snapshot_source.item ->> 'id')::uuid
    and (snapshot_source.item ->> 'contact_id')::uuid =
      duplicate_contact.id;

  update public.conversations as conversation
  set
    contact_id = duplicate_contact.id,
    updated_at = reversal_timestamp,
    version = conversation.version + 1
  from jsonb_array_elements(
    pre_merge_snapshot -> 'conversations'
  ) as snapshot_conversation(item)
  where conversation.id = (snapshot_conversation.item ->> 'id')::uuid
    and (snapshot_conversation.item ->> 'contact_id')::uuid =
      duplicate_contact.id;

  update public.opt_outs as opt_out
  set
    contact_id = duplicate_contact.id,
    status = snapshot_opt_out.item ->> 'status',
    reason = snapshot_opt_out.item ->> 'reason',
    requested_at =
      (snapshot_opt_out.item ->> 'requested_at')::timestamptz,
    revoked_at = nullif(
      snapshot_opt_out.item ->> 'revoked_at',
      ''
    )::timestamptz
  from jsonb_array_elements(
    pre_merge_snapshot -> 'opt_outs'
  ) as snapshot_opt_out(item)
  where opt_out.id = (snapshot_opt_out.item ->> 'id')::uuid
    and (snapshot_opt_out.item ->> 'contact_id')::uuid =
      duplicate_contact.id;

  update public.contacts
  set
    display_name = snapshot_contact.item ->> 'display_name',
    updated_at = reversal_timestamp,
    version = version + 1
  from jsonb_array_elements(
    pre_merge_snapshot -> 'contacts'
  ) as snapshot_contact(item)
  where id = primary_contact.id
    and (snapshot_contact.item ->> 'id')::uuid = primary_contact.id;

  update public.contacts
  set
    display_name = snapshot_contact.item ->> 'display_name',
    status = 'active',
    merged_into_contact_id = null,
    updated_at = reversal_timestamp,
    version = version + 1
  from jsonb_array_elements(
    pre_merge_snapshot -> 'contacts'
  ) as snapshot_contact(item)
  where id = duplicate_contact.id
    and (snapshot_contact.item ->> 'id')::uuid = duplicate_contact.id;

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
    correlation_id,
    created_at
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
    request_correlation_id,
    reversal_timestamp
  );

  delete from private.active_contact_merges
  where organization_id = merge_record.organization_id
    and merged_contact_id = merge_record.merged_contact_id
    and contact_merge_id = merge_record.id;
  get diagnostics deleted_active_projection = row_count;

  if deleted_active_projection <> 1 then
    raise exception 'active contact merge projection changed'
      using errcode = '40001';
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
    merge_record.organization_id,
    merge_record.operation_id,
    auth.uid(),
    'contact.merge_reversed',
    'contact_merge',
    merge_record.id,
    jsonb_build_object(
      'survivor_contact_id', primary_contact.id,
      'merged_contact_id', duplicate_contact.id,
      'validated_snapshot_hash',
      merge_record.snapshot ->> 'post_merge_hash'
    ),
    jsonb_build_object(
      'primary_contact_status', 'active',
      'duplicate_contact_status', 'active',
      'active_projection_removed', true
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

-- Revoke a member's open human ownership safely: the authorized actor who
-- performs the deactivation becomes the human owner. Status is preserved,
-- no third party is selected, and Pedro never receives the Conversation.
create or replace function private.deactivate_membership_after_reauthentication(
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
  ownership_snapshot jsonb;
  ownership_item jsonb;
  transferred_conversation public.conversations%rowtype;
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

  if actor_membership_id is null then
    raise exception 'active actor membership not found'
      using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(to_jsonb(conversation_row) order by conversation_row.id),
    '[]'::jsonb
  )
  into ownership_snapshot
  from (
    select conversation.*
    from public.conversations as conversation
    where conversation.operation_id = target_operation_id
      and conversation.ownership_type = 'human'
      and conversation.assigned_membership_id = target_membership_id
      and conversation.status in ('active', 'sleeping')
    order by conversation.id
    for update
  ) as conversation_row;

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

  for ownership_item in
    select item
    from jsonb_array_elements(ownership_snapshot) as item
  loop
    update public.conversations
    set
      ownership_type = 'human',
      assigned_membership_id = actor_membership_id,
      updated_at = now(),
      version = version + 1
    where id = (ownership_item ->> 'id')::uuid
      and operation_id = target_operation_id
      and ownership_type = 'human'
      and assigned_membership_id = target_membership_id
      and status = ownership_item ->> 'status'
      and version = (ownership_item ->> 'version')::bigint
    returning * into transferred_conversation;

    if transferred_conversation.id is null then
      raise exception 'Conversation ownership changed during deactivation'
        using errcode = '40001';
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
      transferred_conversation.organization_id,
      transferred_conversation.operation_id,
      actor_user_id,
      'conversation.ownership_transferred_on_member_deactivation',
      'conversation',
      transferred_conversation.id,
      jsonb_build_object(
        'ownership_type', ownership_item ->> 'ownership_type',
        'assigned_membership_id',
        ownership_item ->> 'assigned_membership_id',
        'status', ownership_item ->> 'status',
        'version', (ownership_item ->> 'version')::bigint
      ),
      jsonb_build_object(
        'ownership_type', transferred_conversation.ownership_type,
        'assigned_membership_id',
        transferred_conversation.assigned_membership_id,
        'status', transferred_conversation.status,
        'version', transferred_conversation.version,
        'random_reassignment', false,
        'pedro_ownership', false,
        'reason', 'member_deactivated'
      ),
      request_trace_id,
      request_correlation_id
    );

    transferred_conversation := null;
  end loop;

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
) from public, anon, authenticated;
grant execute on function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) to service_role;
