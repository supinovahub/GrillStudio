-- T05: synthetic WhatsApp ingress, Inbox and canonical Conversation Ownership.
--
-- This slice deliberately stays synchronous. T06 owns the durable webhook
-- inbox/outbox, queues, leases, retries and reconciliation. T07 will replace
-- the small capacity predicate without changing the Ownership command API.

create table public.whatsapp_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  adapter_type text not null
    check (adapter_type in ('simulator', 'uazapi', 'meta_cloud')),
  provider_connection_id text not null
    check (char_length(provider_connection_id) between 1 and 300),
  display_name text not null
    check (char_length(display_name) between 1 and 160),
  display_address text
    check (
      display_address is null
      or char_length(display_address) between 1 and 160
    ),
  status text not null default 'active'
    check (status in ('active', 'degraded', 'disabled')),
  inbound_enabled boolean not null default true,
  is_test boolean not null default false,
  capabilities jsonb not null default '{}'::jsonb
    check (jsonb_typeof(capabilities) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, operation_id, id),
  unique (operation_id, adapter_type, provider_connection_id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (adapter_type <> 'simulator' or is_test)
);

create table public.provider_identities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  connection_id uuid not null,
  contact_id uuid not null,
  display_name text
    check (
      display_name is null
      or char_length(display_name) between 1 and 160
    ),
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, operation_id, connection_id, id),
  foreign key (organization_id, operation_id, connection_id)
    references public.whatsapp_connections(organization_id, operation_id, id)
    on delete cascade,
  foreign key (organization_id, contact_id)
    references public.contacts(organization_id, id) on delete cascade,
  check (last_seen_at >= first_seen_at)
);

create table public.provider_identity_aliases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  connection_id uuid not null,
  provider_identity_id uuid not null,
  alias_type text not null
    check (
      alias_type in (
        'simulator_user',
        'uazapi_sender',
        'uazapi_lid',
        'uazapi_pn',
        'meta_bsuid',
        'meta_parent_bsuid',
        'meta_wa_id',
        'meta_username',
        'phone_e164'
      )
    ),
  alias_value text not null
    check (char_length(alias_value) between 1 and 500),
  valid_from timestamptz not null,
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, operation_id, connection_id, id),
  foreign key (
    organization_id,
    operation_id,
    connection_id,
    provider_identity_id
  )
    references public.provider_identities(
      organization_id,
      operation_id,
      connection_id,
      id
    ) on delete cascade,
  check (valid_until is null or valid_until > valid_from)
);

create unique index provider_identity_aliases_one_active_value
  on public.provider_identity_aliases (
    connection_id,
    alias_type,
    alias_value
  )
  where valid_until is null;

create table private.simulator_inbound_reviews (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  connection_id uuid not null,
  provider_message_id text not null,
  reason text not null
    check (
      reason in (
        'ambiguous_identity',
        'ambiguous_opportunity',
        'identity_phone_conflict'
      )
    ),
  normalized_event jsonb not null
    check (jsonb_typeof(normalized_event) = 'object'),
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  unique (connection_id, provider_message_id),
  foreign key (organization_id, operation_id, connection_id)
    references public.whatsapp_connections(organization_id, operation_id, id)
    on delete cascade
);

alter table public.conversations
  add column connection_id uuid,
  add column provider_chat_id text
    check (
      provider_chat_id is null
      or char_length(provider_chat_id) between 1 and 500
    ),
  add column automation_mode text not null default 'shadow'
    check (automation_mode in ('shadow', 'assisted', 'production')),
  add column is_paused boolean not null default false,
  add column pause_reason text
    check (
      pause_reason is null
      or char_length(pause_reason) between 1 and 500
    ),
  add column paused_at timestamptz,
  add column paused_by_membership_id uuid,
  add column pending_return boolean not null default false,
  add column pending_return_target_mode text
    check (
      pending_return_target_mode is null
      or pending_return_target_mode in ('shadow', 'assisted', 'production')
    ),
  add column pending_return_action text
    check (
      pending_return_action is null
      or pending_return_action = 'resume_service'
    ),
  add column pending_return_requested_at timestamptz,
  add column pending_return_requested_by_membership_id uuid,
  add column pending_return_requested_version bigint
    check (
      pending_return_requested_version is null
      or pending_return_requested_version > 0
    ),
  add column requires_human_review boolean not null default false,
  add column review_reason text
    check (
      review_reason is null
      or review_reason in (
        'ambiguous_identity',
        'identity_phone_conflict',
        'post_call_return'
      )
    ),
  add column last_inbound_at timestamptz,
  add column last_outbound_at timestamptz,
  add constraint conversations_organization_operation_id_key
    unique (organization_id, operation_id, id),
  add constraint conversations_operation_connection_fkey
    foreign key (organization_id, operation_id, connection_id)
    references public.whatsapp_connections(organization_id, operation_id, id),
  add constraint conversations_paused_by_membership_fkey
    foreign key (organization_id, paused_by_membership_id)
    references public.memberships(organization_id, id),
  add constraint conversations_pending_return_by_membership_fkey
    foreign key (
      organization_id,
      pending_return_requested_by_membership_id
    )
    references public.memberships(organization_id, id),
  add constraint conversations_origin_pair_check
    check (
      (connection_id is null and provider_chat_id is null)
      or (connection_id is not null and provider_chat_id is not null)
    ),
  add constraint conversations_pause_metadata_check
    check (
      (
        is_paused
        and pause_reason is not null
        and paused_at is not null
      )
      or (
        not is_paused
        and pause_reason is null
        and paused_at is null
        and paused_by_membership_id is null
      )
    ),
  add constraint conversations_pending_return_metadata_check
    check (
      (
        pending_return
        and ownership_type = 'human'
        and assigned_membership_id is not null
        and pending_return_target_mode is not null
        and pending_return_action is not null
        and pending_return_requested_at is not null
        and pending_return_requested_by_membership_id is not null
        and pending_return_requested_version is not null
      )
      or (
        not pending_return
        and pending_return_target_mode is null
        and pending_return_action is null
        and pending_return_requested_at is null
        and pending_return_requested_by_membership_id is null
        and pending_return_requested_version is null
      )
    ),
  add constraint conversations_review_metadata_check
    check (
      (requires_human_review and review_reason is not null)
      or (not requires_human_review and review_reason is null)
    );

alter table public.conversations
  add constraint conversations_connection_identity_key
    unique (
      organization_id,
      operation_id,
      id,
      connection_id
    );

drop index public.conversations_one_open_per_opportunity;

create unique index conversations_one_open_per_opportunity_connection
  on public.conversations (opportunity_id, connection_id)
  where
    connection_id is not null
    and status in ('active', 'sleeping');

create unique index conversations_one_open_manual_per_opportunity
  on public.conversations (opportunity_id)
  where
    connection_id is null
    and status in ('active', 'sleeping');

create unique index conversations_one_open_provider_thread
  on public.conversations (connection_id, provider_chat_id)
  where
    connection_id is not null
    and status in ('active', 'sleeping');

create index conversations_connection_updated_idx
  on public.conversations (
    organization_id,
    operation_id,
    connection_id,
    updated_at desc
  );

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  conversation_id uuid not null,
  connection_id uuid not null,
  direction text not null check (direction in ('inbound', 'outbound')),
  kind text not null default 'text'
    check (kind in ('text', 'image', 'document', 'audio', 'video', 'unknown')),
  body text check (body is null or char_length(body) <= 12000),
  status text not null
    check (status in ('received', 'captured')),
  provider_message_id text
    check (
      provider_message_id is null
      or char_length(provider_message_id) between 1 and 500
    ),
  provider_occurred_at timestamptz,
  idempotency_key uuid,
  created_by_type text not null
    check (created_by_type in ('provider', 'human')),
  created_by_membership_id uuid,
  created_at timestamptz not null default now(),
  unique (organization_id, operation_id, connection_id, id),
  foreign key (
    organization_id,
    operation_id,
    conversation_id,
    connection_id
  )
    references public.conversations(
      organization_id,
      operation_id,
      id,
      connection_id
    )
    on delete cascade,
  foreign key (organization_id, operation_id, connection_id)
    references public.whatsapp_connections(organization_id, operation_id, id),
  foreign key (organization_id, created_by_membership_id)
    references public.memberships(organization_id, id),
  check (
    (direction = 'inbound' and created_by_type = 'provider')
    or (
      direction = 'outbound'
      and created_by_type = 'human'
      and created_by_membership_id is not null
    )
  ),
  check (
    (direction = 'inbound' and provider_message_id is not null)
    or direction = 'outbound'
  )
);

create unique index messages_provider_message_dedupe
  on public.messages (connection_id, provider_message_id)
  where provider_message_id is not null;

create unique index messages_human_command_dedupe
  on public.messages (conversation_id, idempotency_key)
  where idempotency_key is not null;

create index messages_conversation_timeline_idx
  on public.messages (conversation_id, created_at, id);

create table private.simulator_outbound_captures (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  connection_id uuid not null,
  conversation_id uuid not null,
  message_id uuid not null unique,
  provider_chat_id text not null,
  command_payload jsonb not null
    check (jsonb_typeof(command_payload) = 'object'),
  captured_at timestamptz not null default now(),
  foreign key (
    organization_id,
    operation_id,
    connection_id,
    message_id
  )
    references public.messages(
      organization_id,
      operation_id,
      connection_id,
      id
    ) on delete cascade,
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade
);

create index provider_identities_contact_idx
  on public.provider_identities (organization_id, contact_id);
create index provider_identities_connection_seen_idx
  on public.provider_identities (connection_id, last_seen_at desc);
create index provider_identity_aliases_identity_idx
  on public.provider_identity_aliases (provider_identity_id, valid_from desc);
create index provider_identity_aliases_connection_fk_idx
  on public.provider_identity_aliases (
    organization_id,
    operation_id,
    connection_id
  );
create index simulator_inbound_reviews_connection_idx
  on private.simulator_inbound_reviews (connection_id, created_at desc);
create index messages_connection_fk_idx
  on public.messages (
    organization_id,
    operation_id,
    connection_id
  );
create index messages_conversation_fk_idx
  on public.messages (
    organization_id,
    operation_id,
    conversation_id
  );
create index messages_creator_membership_fk_idx
  on public.messages (organization_id, created_by_membership_id)
  where created_by_membership_id is not null;
create index simulator_outbound_captures_conversation_idx
  on private.simulator_outbound_captures (conversation_id, captured_at desc);

alter table public.whatsapp_connections enable row level security;
alter table public.provider_identities enable row level security;
alter table public.provider_identity_aliases enable row level security;
alter table public.messages enable row level security;

revoke all on table public.whatsapp_connections from anon, authenticated;
revoke all on table public.provider_identities from anon, authenticated;
revoke all on table public.provider_identity_aliases from anon, authenticated;
revoke all on table public.messages from anon, authenticated;
revoke all on table private.simulator_inbound_reviews
  from public, anon, authenticated, service_role;
revoke all on table private.simulator_outbound_captures
  from public, anon, authenticated, service_role;

grant select on table public.whatsapp_connections to authenticated;
grant select on table public.messages to authenticated;
grant select, insert, update, delete
  on table public.whatsapp_connections to service_role;
grant select, insert, update, delete
  on table public.provider_identities to service_role;
grant select, insert, update, delete
  on table public.provider_identity_aliases to service_role;
grant select, insert, update, delete
  on table public.messages to service_role;

create or replace function private.can_manage_conversation_operation(
  target_operation_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and private.has_membership_permission(
      target_operation_id,
      'manage_conversations'
    );
$$;

create or replace function private.can_view_conversation(
  target_conversation_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.conversations as conversation
    where conversation.id = target_conversation_id
      and private.can_manage_conversation_operation(
        conversation.operation_id
      )
  );
$$;

revoke all on function private.can_manage_conversation_operation(uuid)
  from public, anon;
revoke all on function private.can_view_conversation(uuid)
  from public, anon;
grant execute on function private.can_manage_conversation_operation(uuid)
  to authenticated;
grant execute on function private.can_view_conversation(uuid)
  to authenticated;

drop policy conversations_select_by_opportunity_scope
  on public.conversations;
create policy conversations_select_operation_management
  on public.conversations
  for select
  to authenticated
  using (private.can_manage_conversation_operation(operation_id));

create policy whatsapp_connections_select_operation_management
  on public.whatsapp_connections
  for select
  to authenticated
  using (private.can_manage_conversation_operation(operation_id));

create policy messages_select_conversation_management
  on public.messages
  for select
  to authenticated
  using (private.can_view_conversation(conversation_id));

create or replace function private.guard_conversation_t05_invariants()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.connection_id is not null
    and (
      new.connection_id is distinct from old.connection_id
      or new.provider_chat_id is distinct from old.provider_chat_id
    )
  then
    raise exception 'Conversation origin is immutable'
      using errcode = '23514';
  end if;

  if old.connection_id is null and new.connection_id is not null then
    if current_setting('grillstudio.pin_conversation_id', true)
      is distinct from old.id::text
    then
      raise exception 'Conversation origin can only be pinned by inbound'
        using errcode = '42501';
    end if;
  end if;

  if old.pending_return
    and new.ownership_type = 'human'
    and new.assigned_membership_id is distinct from old.assigned_membership_id
  then
    new.pending_return := false;
    new.pending_return_target_mode := null;
    new.pending_return_action := null;
    new.pending_return_requested_at := null;
    new.pending_return_requested_by_membership_id := null;
    new.pending_return_requested_version := null;
  end if;

  return new;
end;
$$;

create trigger conversations_t05_invariant_guard
before update on public.conversations
for each row execute function private.guard_conversation_t05_invariants();

create or replace function private.audit_pending_return_invalidation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.pending_return
    and not new.pending_return
    and new.ownership_type = 'human'
    and new.assigned_membership_id is distinct from old.assigned_membership_id
  then
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
      new.organization_id,
      new.operation_id,
      coalesce(
        nullif(
          current_setting('grillstudio.actor_user_id', true),
          ''
        )::uuid,
        auth.uid()
      ),
      'conversation.pending_return_invalidated',
      'conversation',
      new.id,
      jsonb_build_object(
        'owner_membership_id', old.assigned_membership_id,
        'pending_return', true,
        'target_mode', old.pending_return_target_mode,
        'requested_version', old.pending_return_requested_version
      ),
      jsonb_build_object(
        'owner_membership_id', new.assigned_membership_id,
        'pending_return', false,
        'reason', 'human_owner_changed'
      ),
      coalesce(
        nullif(current_setting('grillstudio.trace_id', true), '')::uuid,
        gen_random_uuid()
      ),
      coalesce(
        nullif(
          current_setting('grillstudio.correlation_id', true),
          ''
        )::uuid,
        gen_random_uuid()
      )
    );
  end if;
  return new;
end;
$$;

create trigger conversations_pending_return_invalidation_audit
after update on public.conversations
for each row execute function private.audit_pending_return_invalidation();

revoke all on function private.guard_conversation_t05_invariants()
  from public;
revoke all on function private.audit_pending_return_invalidation()
  from public;

create or replace function private.can_accept_ai_ownership(
  target_operation_id uuid,
  excluded_conversation_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Minimal T05 seam. T07 replaces this predicate with reservations,
  -- thresholds 10/25/30 and backlog without changing the command contract.
  select count(*) < 30
  from public.conversations as conversation
  where conversation.operation_id = target_operation_id
    and conversation.id <> excluded_conversation_id
    and conversation.status = 'active'
    and conversation.ownership_type = 'pedro'
    and not conversation.is_paused;
$$;

revoke all on function private.can_accept_ai_ownership(uuid, uuid)
  from public;

create or replace function private.assert_conversation_command_access(
  target_conversation_id uuid
)
returns table (
  conversation_id uuid,
  operation_id uuid,
  actor_membership_id uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_operation_id uuid;
  membership_id uuid;
begin
  select conversation.operation_id
  into target_operation_id
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  if target_operation_id is null
    or not private.can_manage_conversation_operation(target_operation_id)
  then
    raise exception 'Conversation permission denied' using errcode = '42501';
  end if;

  membership_id := private.actor_membership_id(target_operation_id);
  if membership_id is null then
    raise exception 'active Membership required' using errcode = '42501';
  end if;

  return query
  select target_conversation_id, target_operation_id, membership_id;
end;
$$;

revoke all on function private.assert_conversation_command_access(uuid)
  from public;

create or replace function private.raise_conversation_version_conflict()
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise sqlstate 'PGRST' using
    message = jsonb_build_object(
      'code', '40001',
      'message', 'Conversation version conflict',
      'details', 'reload the Conversation before retrying',
      'hint', 'the command did not run'
    )::text,
    detail = jsonb_build_object(
      'status', 409,
      'headers', jsonb_build_object()
    )::text;
end;
$$;

revoke all on function private.raise_conversation_version_conflict()
  from public;

create or replace function private.assume_conversation(
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
  access_record record;
  before_record public.conversations%rowtype;
  after_record public.conversations%rowtype;
begin
  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);

  select * into strict before_record
  from public.conversations
  where id = target_conversation_id
  for update;

  if before_record.version <> expected_version then
    perform private.raise_conversation_version_conflict();
  end if;
  if before_record.status = 'closed' then
    raise exception 'closed Conversation cannot be assumed'
      using errcode = '23514';
  end if;
  if before_record.ownership_type = 'human'
    and before_record.assigned_membership_id <> access_record.actor_membership_id
  then
    raise exception 'Conversation already has another human owner'
      using errcode = '40001';
  end if;

  update public.conversations
  set
    ownership_type = 'human',
    assigned_membership_id = access_record.actor_membership_id,
    is_paused = false,
    pause_reason = null,
    paused_at = null,
    paused_by_membership_id = null,
    pending_return = false,
    pending_return_target_mode = null,
    pending_return_action = null,
    pending_return_requested_at = null,
    pending_return_requested_by_membership_id = null,
    pending_return_requested_version = null,
    updated_at = now(),
    version = version + 1
  where id = before_record.id
  returning * into strict after_record;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    after_record.organization_id,
    after_record.operation_id,
    auth.uid(),
    'conversation.assumed',
    'conversation',
    after_record.id,
    jsonb_build_object(
      'ownership_type', before_record.ownership_type,
      'owner_membership_id', before_record.assigned_membership_id,
      'is_paused', before_record.is_paused,
      'pending_return', before_record.pending_return,
      'automation_mode', before_record.automation_mode,
      'version', before_record.version
    ),
    jsonb_build_object(
      'ownership_type', after_record.ownership_type,
      'owner_membership_id', after_record.assigned_membership_id,
      'is_paused', after_record.is_paused,
      'pending_return', after_record.pending_return,
      'automation_mode', after_record.automation_mode,
      'version', after_record.version
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'conversation_id', after_record.id,
    'ownership_type', after_record.ownership_type,
    'owner_membership_id', after_record.assigned_membership_id,
    'automation_mode', after_record.automation_mode,
    'is_paused', after_record.is_paused,
    'pending_return', after_record.pending_return,
    'version', after_record.version
  );
end;
$$;

create or replace function private.pause_conversation(
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
  access_record record;
  before_record public.conversations%rowtype;
  after_record public.conversations%rowtype;
  normalized_reason text;
begin
  normalized_reason := nullif(left(btrim(coalesce(pause_reason_value, '')), 500), '');
  if normalized_reason is null then
    raise exception 'pause reason is required' using errcode = '22023';
  end if;

  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);

  select * into strict before_record
  from public.conversations
  where id = target_conversation_id
  for update;

  if before_record.version <> expected_version then
    perform private.raise_conversation_version_conflict();
  end if;
  if before_record.status = 'closed' then
    raise exception 'closed Conversation cannot be paused'
      using errcode = '23514';
  end if;
  if before_record.ownership_type = 'human'
    and before_record.assigned_membership_id <> access_record.actor_membership_id
  then
    raise exception 'Conversation already has another human owner'
      using errcode = '40001';
  end if;

  update public.conversations
  set
    ownership_type = 'human',
    assigned_membership_id = access_record.actor_membership_id,
    is_paused = true,
    pause_reason = normalized_reason,
    paused_at = now(),
    paused_by_membership_id = access_record.actor_membership_id,
    pending_return = false,
    pending_return_target_mode = null,
    pending_return_action = null,
    pending_return_requested_at = null,
    pending_return_requested_by_membership_id = null,
    pending_return_requested_version = null,
    updated_at = now(),
    version = version + 1
  where id = before_record.id
  returning * into strict after_record;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    after_record.organization_id,
    after_record.operation_id,
    auth.uid(),
    'conversation.paused',
    'conversation',
    after_record.id,
    jsonb_build_object(
      'ownership_type', before_record.ownership_type,
      'owner_membership_id', before_record.assigned_membership_id,
      'is_paused', before_record.is_paused,
      'pending_return', before_record.pending_return,
      'version', before_record.version
    ),
    jsonb_build_object(
      'ownership_type', 'human',
      'owner_membership_id', after_record.assigned_membership_id,
      'is_paused', true,
      'reason', normalized_reason,
      'version', after_record.version
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'conversation_id', after_record.id,
    'ownership_type', after_record.ownership_type,
    'owner_membership_id', after_record.assigned_membership_id,
    'automation_mode', after_record.automation_mode,
    'is_paused', after_record.is_paused,
    'pending_return', after_record.pending_return,
    'version', after_record.version
  );
end;
$$;

create or replace function private.return_conversation_to_pedro(
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
  access_record record;
  before_record public.conversations%rowtype;
  after_record public.conversations%rowtype;
  capacity_available boolean;
begin
  if target_automation_mode not in ('shadow', 'assisted', 'production')
    or return_action <> 'resume_service'
  then
    raise exception 'invalid Pedro return target' using errcode = '22023';
  end if;

  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);

  select * into strict before_record
  from public.conversations
  where id = target_conversation_id
  for update;

  if before_record.version <> expected_version then
    perform private.raise_conversation_version_conflict();
  end if;
  if before_record.status = 'closed'
    or before_record.ownership_type <> 'human'
    or before_record.assigned_membership_id <> access_record.actor_membership_id
  then
    raise exception 'only the current human owner can return Conversation'
      using errcode = '42501';
  end if;
  if target_automation_mode = 'production'
    and (
      not exists (
        select 1
        from public.operation_settings as settings
        where settings.operation_id = before_record.operation_id
          and settings.production_enabled
      )
      or exists (
        select 1
        from public.system_pauses as pause
        where pause.operation_id = before_record.operation_id
          and pause.status = 'active'
      )
    )
  then
    raise exception 'production mode gate is closed'
      using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'conversation-capacity:' || before_record.operation_id::text,
      0
    )
  );
  capacity_available := private.can_accept_ai_ownership(
    before_record.operation_id,
    before_record.id
  );

  if capacity_available then
    update public.conversations
    set
      ownership_type = 'pedro',
      assigned_membership_id = null,
      automation_mode = target_automation_mode,
      is_paused = false,
      pause_reason = null,
      paused_at = null,
      paused_by_membership_id = null,
      pending_return = false,
      pending_return_target_mode = null,
      pending_return_action = null,
      pending_return_requested_at = null,
      pending_return_requested_by_membership_id = null,
      pending_return_requested_version = null,
      updated_at = now(),
      version = version + 1
    where id = before_record.id
    returning * into strict after_record;
  else
    update public.conversations
    set
      automation_mode = target_automation_mode,
      is_paused = false,
      pause_reason = null,
      paused_at = null,
      paused_by_membership_id = null,
      pending_return = true,
      pending_return_target_mode = target_automation_mode,
      pending_return_action = return_action,
      pending_return_requested_at = now(),
      pending_return_requested_by_membership_id =
        access_record.actor_membership_id,
      pending_return_requested_version = version + 1,
      updated_at = now(),
      version = version + 1
    where id = before_record.id
    returning * into strict after_record;
  end if;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    after_record.organization_id,
    after_record.operation_id,
    auth.uid(),
    case
      when capacity_available then 'conversation.returned_to_pedro'
      else 'conversation.return_pending'
    end,
    'conversation',
    after_record.id,
    jsonb_build_object(
      'ownership_type', before_record.ownership_type,
      'owner_membership_id', before_record.assigned_membership_id,
      'automation_mode', before_record.automation_mode,
      'version', before_record.version
    ),
    jsonb_build_object(
      'ownership_type', after_record.ownership_type,
      'owner_membership_id', after_record.assigned_membership_id,
      'automation_mode', after_record.automation_mode,
      'pending_return', after_record.pending_return,
      'target_action', return_action,
      'requested_version', after_record.pending_return_requested_version,
      'version', after_record.version
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'conversation_id', after_record.id,
    'ownership_type', after_record.ownership_type,
    'owner_membership_id', after_record.assigned_membership_id,
    'automation_mode', after_record.automation_mode,
    'is_paused', after_record.is_paused,
    'pending_return', after_record.pending_return,
    'version', after_record.version
  );
end;
$$;

create or replace function private.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  connection_record public.whatsapp_connections%rowtype;
  existing_message public.messages%rowtype;
  conversation_record public.conversations%rowtype;
  manual_conversation public.conversations%rowtype;
  contact_record public.contacts%rowtype;
  phone_record public.contact_phones%rowtype;
  opportunity_record public.opportunities%rowtype;
  identity_record public.provider_identities%rowtype;
  provider_message_id text;
  provider_chat_id text;
  message_kind text;
  message_body text;
  identity_display_name text;
  phone_original text;
  normalized_phone text;
  occurred_at timestamptz;
  aliases jsonb;
  alias_item jsonb;
  alias_type_value text;
  alias_value_value text;
  identity_ids uuid[];
  identity_contact_ids uuid[];
  identity_contact_id uuid;
  phone_contact_id uuid;
  active_opportunity_ids uuid[];
  terminal_opportunity_ids uuid[];
  reopen_result text;
  requires_review boolean := false;
  review_reason_value text;
  created_contact boolean := false;
  created_opportunity boolean := false;
  created_conversation boolean := false;
  pinned_manual_conversation boolean := false;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  if jsonb_typeof(normalized_event) <> 'object'
    or normalized_event ->> 'provider' <> 'simulator'
  then
    raise exception 'invalid normalized simulator event'
      using errcode = '22023';
  end if;

  provider_message_id := nullif(
    left(btrim(coalesce(normalized_event ->> 'provider_message_id', '')), 500),
    ''
  );
  provider_chat_id := nullif(
    left(btrim(coalesce(normalized_event ->> 'provider_chat_id', '')), 500),
    ''
  );
  message_kind := nullif(
    btrim(coalesce(normalized_event ->> 'kind', '')),
    ''
  );
  message_body := nullif(
    left(coalesce(normalized_event ->> 'text', ''), 12000),
    ''
  );
  identity_display_name := nullif(
    left(
      btrim(coalesce(normalized_event #>> '{identity,display_name}', '')),
      160
    ),
    ''
  );
  phone_original := nullif(
    left(
      btrim(coalesce(normalized_event #>> '{identity,phone_original}', '')),
      80
    ),
    ''
  );
  aliases := coalesce(
    normalized_event #> '{identity,aliases}',
    '[]'::jsonb
  );

  if provider_message_id is null
    or provider_chat_id is null
    or message_kind not in (
      'text', 'image', 'document', 'audio', 'video', 'unknown'
    )
    or jsonb_typeof(aliases) <> 'array'
    or jsonb_array_length(aliases) = 0
  then
    raise exception 'normalized simulator event is incomplete'
      using errcode = '22023';
  end if;

  begin
    occurred_at := (normalized_event ->> 'occurred_at')::timestamptz;
  exception when others then
    raise exception 'normalized simulator timestamp is invalid'
      using errcode = '22023';
  end;

  for alias_item in
    select value
    from jsonb_array_elements(aliases)
  loop
    alias_type_value := alias_item ->> 'type';
    alias_value_value := nullif(
      left(btrim(coalesce(alias_item ->> 'value', '')), 500),
      ''
    );
    if alias_type_value not in (
      'simulator_user',
      'uazapi_sender',
      'uazapi_lid',
      'uazapi_pn',
      'meta_bsuid',
      'meta_parent_bsuid',
      'meta_wa_id',
      'meta_username'
    )
      or alias_value_value is null
    then
      raise exception 'normalized provider identity alias is invalid'
        using errcode = '22023';
    end if;
  end loop;

  select connection.*
  into connection_record
  from public.whatsapp_connections as connection
  where connection.id = target_connection_id
  for update;

  if connection_record.id is null
    or connection_record.adapter_type <> 'simulator'
    or not connection_record.is_test
    or connection_record.status <> 'active'
    or not connection_record.inbound_enabled
  then
    raise exception 'simulator connection is not available'
      using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'simulator-inbound:' || target_connection_id::text
        || ':' || provider_message_id,
      0
    )
  );

  select message.*
  into existing_message
  from public.messages as message
  where message.connection_id = target_connection_id
    and message.provider_message_id = provider_message_id;

  if existing_message.id is not null then
    return jsonb_build_object(
      'status', 'duplicate',
      'message_id', existing_message.id,
      'conversation_id', existing_message.conversation_id
    );
  end if;

  if exists (
    select 1
    from private.simulator_inbound_reviews as review
    where review.connection_id = target_connection_id
      and review.provider_message_id = provider_message_id
  ) then
    return jsonb_build_object('status', 'requires_review');
  end if;

  select conversation.*
  into conversation_record
  from public.conversations as conversation
  where conversation.connection_id = target_connection_id
    and conversation.provider_chat_id = provider_chat_id
    and conversation.status in ('active', 'sleeping')
  for update;

  if conversation_record.id is not null then
    select contact.*
    into strict contact_record
    from public.contacts as contact
    where contact.id = conversation_record.contact_id;
    select opportunity.*
    into strict opportunity_record
    from public.opportunities as opportunity
    where opportunity.id = conversation_record.opportunity_id;

    select
      coalesce(
        array_agg(distinct matched_alias.provider_identity_id)
          filter (where matched_alias.provider_identity_id is not null),
        array[]::uuid[]
      ),
      coalesce(
        array_agg(
          distinct case
            when matched_contact.status = 'merged'
              then matched_contact.merged_into_contact_id
            else matched_contact.id
          end
        ) filter (where matched_contact.id is not null),
        array[]::uuid[]
      )
    into identity_ids, identity_contact_ids
    from jsonb_array_elements(aliases) as incoming_alias(item)
    left join public.provider_identity_aliases as matched_alias
      on matched_alias.connection_id = target_connection_id
      and matched_alias.alias_type = incoming_alias.item ->> 'type'
      and matched_alias.alias_value = incoming_alias.item ->> 'value'
      and matched_alias.valid_until is null
    left join public.provider_identities as matched_identity
      on matched_identity.id = matched_alias.provider_identity_id
    left join public.contacts as matched_contact
      on matched_contact.id = matched_identity.contact_id;

    if coalesce(array_length(identity_ids, 1), 0) > 1
      or coalesce(array_length(identity_contact_ids, 1), 0) > 1
      or (
        coalesce(array_length(identity_contact_ids, 1), 0) = 1
        and identity_contact_ids[1] <> contact_record.id
      )
    then
      requires_review := true;
      review_reason_value := 'ambiguous_identity';
    end if;

    if phone_original is not null then
      normalized_phone := private.normalize_phone_e164(phone_original, '+55');
      select
        case
          when contact.status = 'merged' then contact.merged_into_contact_id
          else contact.id
        end
      into phone_contact_id
      from public.contact_phones as phone
      join public.contacts as contact on contact.id = phone.contact_id
      where phone.organization_id = connection_record.organization_id
        and phone.e164 = normalized_phone;

      if phone_contact_id is not null
        and phone_contact_id <> contact_record.id
      then
        requires_review := true;
        review_reason_value := 'identity_phone_conflict';
      end if;
    end if;

    if requires_review then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id,
        review_reason_value,
        normalized_event,
        request_trace_id,
        request_correlation_id
      );

      update public.conversations
      set
        is_paused = true,
        pause_reason = 'human_review_required',
        paused_at = now(),
        requires_human_review = true,
        review_reason = review_reason_value,
        updated_at = now(),
        version = version + 1
      where id = conversation_record.id
      returning * into strict conversation_record;
    elsif coalesce(array_length(identity_ids, 1), 0) <= 1 then
      if coalesce(array_length(identity_ids, 1), 0) = 1 then
        select identity.*
        into strict identity_record
        from public.provider_identities as identity
        where identity.id = identity_ids[1]
        for update;

        update public.provider_identities as target
        set
          display_name = coalesce(
            target.display_name,
            identity_display_name
          ),
          last_seen_at = greatest(target.last_seen_at, occurred_at),
          updated_at = now(),
          version = target.version + 1
        where target.id = identity_record.id
        returning target.* into strict identity_record;
      else
        select identity.*
        into identity_record
        from public.provider_identities as identity
        where identity.connection_id = target_connection_id
          and identity.contact_id = contact_record.id
        order by identity.last_seen_at desc, identity.id
        limit 1
        for update;

        if identity_record.id is null then
          insert into public.provider_identities (
            organization_id,
            operation_id,
            connection_id,
            contact_id,
            display_name,
            first_seen_at,
            last_seen_at
          )
          values (
            connection_record.organization_id,
            connection_record.operation_id,
            connection_record.id,
            contact_record.id,
            identity_display_name,
            occurred_at,
            occurred_at
          )
          returning * into strict identity_record;
        end if;
      end if;

      for alias_item in
        select value
        from jsonb_array_elements(aliases)
      loop
        insert into public.provider_identity_aliases (
          organization_id,
          operation_id,
          connection_id,
          provider_identity_id,
          alias_type,
          alias_value,
          valid_from
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          connection_record.id,
          identity_record.id,
          alias_item ->> 'type',
          alias_item ->> 'value',
          occurred_at
        )
        on conflict do nothing;
      end loop;
    end if;
  else
    select
      coalesce(
        array_agg(distinct matched_alias.provider_identity_id)
          filter (where matched_alias.provider_identity_id is not null),
        array[]::uuid[]
      ),
      coalesce(
        array_agg(
          distinct case
            when matched_contact.status = 'merged'
              then matched_contact.merged_into_contact_id
            else matched_contact.id
          end
        ) filter (where matched_contact.id is not null),
        array[]::uuid[]
      )
    into identity_ids, identity_contact_ids
    from jsonb_array_elements(aliases) as incoming_alias(item)
    left join public.provider_identity_aliases as matched_alias
      on matched_alias.connection_id = target_connection_id
      and matched_alias.alias_type = incoming_alias.item ->> 'type'
      and matched_alias.alias_value = incoming_alias.item ->> 'value'
      and matched_alias.valid_until is null
    left join public.provider_identities as matched_identity
      on matched_identity.id = matched_alias.provider_identity_id
    left join public.contacts as matched_contact
      on matched_contact.id = matched_identity.contact_id;

    if coalesce(array_length(identity_ids, 1), 0) > 1
      or coalesce(array_length(identity_contact_ids, 1), 0) > 1
    then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id,
        'ambiguous_identity',
        normalized_event,
        request_trace_id,
        request_correlation_id
      );
      return jsonb_build_object(
        'status', 'requires_review',
        'reason', 'ambiguous_identity'
      );
    end if;

    identity_contact_id := identity_contact_ids[1];

    if phone_original is not null then
      normalized_phone := private.normalize_phone_e164(phone_original, '+55');
      select
        case
          when contact.status = 'merged' then contact.merged_into_contact_id
          else contact.id
        end
      into phone_contact_id
      from public.contact_phones as phone
      join public.contacts as contact on contact.id = phone.contact_id
      where phone.organization_id = connection_record.organization_id
        and phone.e164 = normalized_phone;
    end if;

    if identity_contact_id is not null
      and phone_contact_id is not null
      and identity_contact_id <> phone_contact_id
    then
      requires_review := true;
      review_reason_value := 'identity_phone_conflict';
    end if;

    if identity_contact_id is not null then
      select contact.*
      into strict contact_record
      from public.contacts as contact
      where contact.id = identity_contact_id
      for update;
    elsif phone_contact_id is not null then
      select contact.*
      into strict contact_record
      from public.contacts as contact
      where contact.id = phone_contact_id
      for update;
    else
      insert into public.contacts (
        organization_id,
        display_name
      )
      values (
        connection_record.organization_id,
        identity_display_name
      )
      returning * into strict contact_record;
      created_contact := true;

      if normalized_phone is not null then
        insert into public.contact_phones (
          organization_id,
          contact_id,
          e164,
          original_value,
          is_primary
        )
        values (
          connection_record.organization_id,
          contact_record.id,
          normalized_phone,
          phone_original,
          true
        )
        returning * into phone_record;
      end if;
    end if;

    if phone_original is not null
      and normalized_phone is not null
      and not requires_review
    then
      if phone_record.id is null then
        select phone.*
        into phone_record
        from public.contact_phones as phone
        where phone.organization_id = connection_record.organization_id
          and phone.e164 = normalized_phone;
      end if;
      if phone_record.id is not null
        and phone_record.contact_id = contact_record.id
      then
        insert into public.contact_phone_observations (
          organization_id,
          contact_id,
          contact_phone_id,
          original_value,
          source_type
        )
        values (
          connection_record.organization_id,
          contact_record.id,
          phone_record.id,
          phone_original,
          'simulator_inbound'
        );
      end if;
    end if;

    if coalesce(array_length(identity_ids, 1), 0) = 1 then
      select identity.*
      into strict identity_record
      from public.provider_identities as identity
      where identity.id = identity_ids[1]
      for update;

      update public.provider_identities as target
      set
        display_name = coalesce(
          target.display_name,
          identity_display_name
        ),
        last_seen_at = greatest(target.last_seen_at, occurred_at),
        updated_at = now(),
        version = target.version + 1
      where target.id = identity_record.id
      returning target.* into strict identity_record;
    else
      insert into public.provider_identities (
        organization_id,
        operation_id,
        connection_id,
        contact_id,
        display_name,
        first_seen_at,
        last_seen_at
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        contact_record.id,
        identity_display_name,
        occurred_at,
        occurred_at
      )
      returning * into strict identity_record;
    end if;

    for alias_item in
      select value
      from jsonb_array_elements(aliases)
    loop
      insert into public.provider_identity_aliases (
        organization_id,
        operation_id,
        connection_id,
        provider_identity_id,
        alias_type,
        alias_value,
        valid_from
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        identity_record.id,
        alias_item ->> 'type',
        alias_item ->> 'value',
        occurred_at
      )
      on conflict do nothing;
    end loop;

    if normalized_phone is not null and not requires_review then
      insert into public.provider_identity_aliases (
        organization_id,
        operation_id,
        connection_id,
        provider_identity_id,
        alias_type,
        alias_value,
        valid_from
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        identity_record.id,
        'phone_e164',
        normalized_phone,
        occurred_at
      )
      on conflict do nothing;
    end if;

    select coalesce(array_agg(opportunity.id order by opportunity.id), array[]::uuid[])
    into active_opportunity_ids
    from public.opportunities as opportunity
    where opportunity.organization_id = connection_record.organization_id
      and opportunity.operation_id = connection_record.operation_id
      and opportunity.contact_id = contact_record.id
      and opportunity.stage not in ('lost', 'purchased');

    if coalesce(array_length(active_opportunity_ids, 1), 0) > 1 then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id,
        'ambiguous_opportunity',
        normalized_event,
        request_trace_id,
        request_correlation_id
      );
      return jsonb_build_object(
        'status', 'requires_review',
        'reason', 'ambiguous_opportunity'
      );
    elsif coalesce(array_length(active_opportunity_ids, 1), 0) = 1 then
      select * into strict opportunity_record
      from public.opportunities
      where id = active_opportunity_ids[1]
      for update;
    else
      select coalesce(
        array_agg(opportunity.id order by opportunity.id),
        array[]::uuid[]
      )
      into terminal_opportunity_ids
      from public.opportunities as opportunity
      where opportunity.organization_id = connection_record.organization_id
        and opportunity.operation_id = connection_record.operation_id
        and opportunity.contact_id = contact_record.id
        and opportunity.stage in ('lost', 'purchased');

      if coalesce(array_length(terminal_opportunity_ids, 1), 0) > 1 then
        insert into private.simulator_inbound_reviews (
          organization_id, operation_id, connection_id,
          provider_message_id, reason, normalized_event,
          trace_id, correlation_id
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          connection_record.id,
          provider_message_id,
          'ambiguous_opportunity',
          normalized_event,
          request_trace_id,
          request_correlation_id
        );
        return jsonb_build_object(
          'status', 'requires_review',
          'reason', 'ambiguous_opportunity'
        );
      elsif coalesce(array_length(terminal_opportunity_ids, 1), 0) = 1 then
        reopen_result := private.reopen_opportunity_on_inbound(
          terminal_opportunity_ids[1],
          request_trace_id,
          request_correlation_id
        );
        if reopen_result = 'human_review_required' then
          select * into strict opportunity_record
          from public.opportunities
          where id = terminal_opportunity_ids[1]
          for update;
          requires_review := true;
          review_reason_value := 'post_call_return';
        elsif reopen_result = 'reopened' then
          select * into strict opportunity_record
          from public.opportunities
          where id = terminal_opportunity_ids[1]
          for update;
        end if;
      end if;

      if opportunity_record.id is null then
        perform set_config('grillstudio.trace_id', request_trace_id::text, true);
        perform set_config(
          'grillstudio.correlation_id',
          request_correlation_id::text,
          true
        );
        perform set_config(
          'grillstudio.stage_reason',
          case
            when reopen_result = 'sale_closed'
              then 'new_inbound_after_purchased'
            else 'simulator_inbound'
          end,
          true
        );

        insert into public.opportunities (
          organization_id,
          operation_id,
          contact_id,
          stage,
          source_type
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          contact_record.id,
          'new',
          'simulator_inbound'
        )
        returning * into strict opportunity_record;
        created_opportunity := true;

        insert into public.source_attributions (
          organization_id,
          operation_id,
          contact_id,
          opportunity_id,
          source_type,
          source_label,
          details,
          attributed_at
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          contact_record.id,
          opportunity_record.id,
          'simulator_inbound',
          connection_record.display_name,
          jsonb_build_object(
            'connection_id', connection_record.id,
            'adapter_type', 'simulator'
          ),
          occurred_at
        );
      end if;
    end if;

    select conversation.*
    into manual_conversation
    from public.conversations as conversation
    where conversation.opportunity_id = opportunity_record.id
      and conversation.connection_id is null
      and conversation.status in ('active', 'sleeping')
    for update;

    if manual_conversation.id is not null then
      perform set_config(
        'grillstudio.pin_conversation_id',
        manual_conversation.id::text,
        true
      );
      update public.conversations
      set
        connection_id = connection_record.id,
        provider_chat_id = provider_chat_id,
        requires_human_review =
          requires_human_review or requires_review,
        review_reason = case
          when requires_review then review_reason_value
          else review_reason
        end,
        is_paused = case
          when requires_review then true
          else is_paused
        end,
        pause_reason = case
          when requires_review then 'human_review_required'
          else pause_reason
        end,
        paused_at = case
          when requires_review then now()
          else paused_at
        end,
        last_inbound_at = occurred_at,
        updated_at = now(),
        version = version + 1
      where id = manual_conversation.id
        and connection_id is null
        and version = manual_conversation.version
      returning * into conversation_record;

      if conversation_record.id is null then
        raise exception 'manual Conversation changed before origin pin'
          using errcode = '40001';
      end if;
      pinned_manual_conversation := true;
    else
      insert into public.conversations (
        organization_id,
        operation_id,
        contact_id,
        opportunity_id,
        connection_id,
        provider_chat_id,
        status,
        ownership_type,
        automation_mode,
        is_paused,
        pause_reason,
        paused_at,
        requires_human_review,
        review_reason,
        last_inbound_at
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        contact_record.id,
        opportunity_record.id,
        connection_record.id,
        provider_chat_id,
        'active',
        'pedro',
        'shadow',
        requires_review,
        case when requires_review then 'human_review_required' else null end,
        case when requires_review then now() else null end,
        requires_review,
        review_reason_value,
        occurred_at
      )
      returning * into strict conversation_record;
      created_conversation := true;
    end if;

    if requires_review then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id,
        review_reason_value,
        normalized_event,
        request_trace_id,
        request_correlation_id
      )
      on conflict (connection_id, provider_message_id) do nothing;
    end if;
  end if;

  if conversation_record.id is not null
    and conversation_record.connection_id <> connection_record.id
  then
    raise exception 'Conversation is pinned to another connection'
      using errcode = '23514';
  end if;

  insert into public.messages (
    organization_id,
    operation_id,
    conversation_id,
    connection_id,
    direction,
    kind,
    body,
    status,
    provider_message_id,
    provider_occurred_at,
    created_by_type
  )
  values (
    connection_record.organization_id,
    connection_record.operation_id,
    conversation_record.id,
    connection_record.id,
    'inbound',
    message_kind,
    message_body,
    'received',
    provider_message_id,
    occurred_at,
    'provider'
  )
  returning * into strict existing_message;

  update public.conversations
  set
    last_inbound_at = greatest(
      coalesce(last_inbound_at, occurred_at),
      occurred_at
    ),
    updated_at = now(),
    version = version + 1
  where id = conversation_record.id
  returning * into strict conversation_record;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    connection_record.organization_id,
    connection_record.operation_id,
    null,
    'message.inbound_received',
    'message',
    existing_message.id,
    null,
    jsonb_build_object(
      'conversation_id', conversation_record.id,
      'connection_id', connection_record.id,
      'provider_message_id_hash',
        md5(provider_message_id),
      'created_contact', created_contact,
      'created_opportunity', created_opportunity,
      'created_conversation', created_conversation,
      'pinned_manual_conversation', pinned_manual_conversation,
      'requires_human_review', conversation_record.requires_human_review,
      'ownership_type', conversation_record.ownership_type,
      'version', conversation_record.version
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'status', 'received',
    'contact_id', contact_record.id,
    'opportunity_id', opportunity_record.id,
    'conversation_id', conversation_record.id,
    'message_id', existing_message.id,
    'ownership_type', conversation_record.ownership_type,
    'requires_human_review', conversation_record.requires_human_review,
    'version', conversation_record.version
  );
end;
$$;

create or replace function private.send_human_message(
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
  access_record record;
  conversation_record public.conversations%rowtype;
  connection_record public.whatsapp_connections%rowtype;
  existing_message public.messages%rowtype;
  created_message public.messages%rowtype;
  cancelled_pending boolean;
  normalized_text text;
begin
  normalized_text := nullif(left(btrim(coalesce(message_text, '')), 12000), '');
  if command_id is null or normalized_text is null then
    raise exception 'message command and text are required'
      using errcode = '22023';
  end if;

  select * into strict access_record
  from private.assert_conversation_command_access(target_conversation_id);

  select * into strict conversation_record
  from public.conversations
  where id = target_conversation_id
  for update;

  select message.*
  into existing_message
  from public.messages as message
  where message.conversation_id = target_conversation_id
    and message.idempotency_key = command_id;

  if existing_message.id is not null then
    return jsonb_build_object(
      'status', 'duplicate',
      'message_id', existing_message.id,
      'conversation_id', existing_message.conversation_id,
      'version', conversation_record.version
    );
  end if;

  if conversation_record.version <> expected_version then
    perform private.raise_conversation_version_conflict();
  end if;
  if conversation_record.status = 'closed'
    or conversation_record.ownership_type <> 'human'
    or conversation_record.assigned_membership_id
      <> access_record.actor_membership_id
    or conversation_record.is_paused
  then
    raise exception 'current human owner cannot send this message'
      using errcode = '42501';
  end if;
  if conversation_record.connection_id is null then
    raise exception 'Conversation has no pinned connection'
      using errcode = '23514';
  end if;

  select * into strict connection_record
  from public.whatsapp_connections
  where id = conversation_record.connection_id
  for share;

  if connection_record.adapter_type <> 'simulator'
    or not connection_record.is_test
    or connection_record.status <> 'active'
  then
    raise exception 'real provider egress is not available in T05'
      using errcode = '42501';
  end if;

  cancelled_pending := conversation_record.pending_return;

  update public.conversations
  set
    pending_return = false,
    pending_return_target_mode = null,
    pending_return_action = null,
    pending_return_requested_at = null,
    pending_return_requested_by_membership_id = null,
    pending_return_requested_version = null,
    last_outbound_at = now(),
    updated_at = now(),
    version = version + 1
  where id = conversation_record.id
    and version = expected_version
  returning * into strict conversation_record;

  insert into public.messages (
    organization_id,
    operation_id,
    conversation_id,
    connection_id,
    direction,
    kind,
    body,
    status,
    idempotency_key,
    created_by_type,
    created_by_membership_id
  )
  values (
    conversation_record.organization_id,
    conversation_record.operation_id,
    conversation_record.id,
    conversation_record.connection_id,
    'outbound',
    'text',
    normalized_text,
    'captured',
    command_id,
    'human',
    access_record.actor_membership_id
  )
  returning * into strict created_message;

  insert into private.simulator_outbound_captures (
    organization_id,
    operation_id,
    connection_id,
    conversation_id,
    message_id,
    provider_chat_id,
    command_payload
  )
  values (
    conversation_record.organization_id,
    conversation_record.operation_id,
    conversation_record.connection_id,
    conversation_record.id,
    created_message.id,
    conversation_record.provider_chat_id,
    jsonb_build_object(
      'kind', 'text',
      'text', normalized_text,
      'adapter', 'simulator'
    )
  );

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    conversation_record.organization_id,
    conversation_record.operation_id,
    auth.uid(),
    'message.outbound_captured',
    'message',
    created_message.id,
    jsonb_build_object(
      'conversation_id', conversation_record.id,
      'pending_return', cancelled_pending,
      'expected_version', expected_version
    ),
    jsonb_build_object(
      'conversation_id', conversation_record.id,
      'pending_return', false,
      'pending_cancelled_by_human_message', cancelled_pending,
      'adapter', 'simulator',
      'egress_attempted', false,
      'version', conversation_record.version
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'status', 'captured',
    'message_id', created_message.id,
    'conversation_id', conversation_record.id,
    'pending_return', false,
    'pending_cancelled', cancelled_pending,
    'version', conversation_record.version
  );
end;
$$;

create or replace function private.get_inbox_list(
  target_operation_id uuid
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
  if not private.can_manage_conversation_operation(target_operation_id) then
    raise exception 'Inbox permission denied' using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', conversation.id,
        'contact_id', contact.id,
        'opportunity_id', opportunity.id,
        'display_name', contact.display_name,
        'stage', opportunity.stage,
        'source_type', opportunity.source_type,
        'status', conversation.status,
        'ownership_type', conversation.ownership_type,
        'assigned_membership_id', conversation.assigned_membership_id,
        'assigned_name', staff_profile.full_name,
        'is_owned_by_actor',
          conversation.assigned_membership_id =
            private.actor_membership_id(conversation.operation_id),
        'automation_mode', conversation.automation_mode,
        'is_paused', conversation.is_paused,
        'pending_return', conversation.pending_return,
        'requires_human_review', conversation.requires_human_review,
        'review_reason', conversation.review_reason,
        'connection_id', connection.id,
        'connection_name', connection.display_name,
        'connection_address', connection.display_address,
        'origin', connection.adapter_type,
        'last_message', coalesce(last_message.body, ''),
        'last_message_kind', last_message.kind,
        'last_message_direction', last_message.direction,
        'last_message_at', coalesce(
          last_message.provider_occurred_at,
          last_message.created_at,
          conversation.updated_at
        ),
        'updated_at', conversation.updated_at,
        'version', conversation.version
      )
      order by
        coalesce(
          last_message.provider_occurred_at,
          last_message.created_at,
          conversation.updated_at
        ) desc,
        conversation.id
    ),
    '[]'::jsonb
  )
  into result
  from public.conversations as conversation
  join public.contacts as contact
    on contact.id = conversation.contact_id
  join public.opportunities as opportunity
    on opportunity.id = conversation.opportunity_id
  left join public.whatsapp_connections as connection
    on connection.id = conversation.connection_id
  left join public.staff_profiles as staff_profile
    on staff_profile.membership_id = conversation.assigned_membership_id
  left join lateral (
    select message.*
    from public.messages as message
    where message.conversation_id = conversation.id
    order by
      coalesce(message.provider_occurred_at, message.created_at) desc,
      message.id desc
    limit 1
  ) as last_message on true
  where conversation.operation_id = target_operation_id
    and conversation.status in ('active', 'sleeping');

  return result;
end;
$$;

create or replace function private.get_conversation_detail(
  target_conversation_id uuid
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
  if not private.can_view_conversation(target_conversation_id) then
    raise exception 'Conversation permission denied' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'id', conversation.id,
    'contact', jsonb_build_object(
      'id', contact.id,
      'display_name', contact.display_name,
      'phones', coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', phone.id,
              'e164', phone.e164,
              'is_primary', phone.is_primary
            )
            order by phone.is_primary desc, phone.created_at
          )
          from public.contact_phones as phone
          where phone.contact_id = contact.id
        ),
        '[]'::jsonb
      )
    ),
    'opportunity', jsonb_build_object(
      'id', opportunity.id,
      'stage', opportunity.stage,
      'source_type', opportunity.source_type,
      'pedro_context', opportunity.pedro_context,
      'unit_count', opportunity.unit_count,
      'amount_scope', opportunity.amount_scope,
      'version', opportunity.version
    ),
    'connection', case
      when connection.id is null then null
      else jsonb_build_object(
        'id', connection.id,
        'name', connection.display_name,
        'display_address', connection.display_address,
        'adapter_type', connection.adapter_type,
        'is_test', connection.is_test
      )
    end,
    'status', conversation.status,
    'ownership_type', conversation.ownership_type,
    'assigned_membership_id', conversation.assigned_membership_id,
    'assigned_name', staff_profile.full_name,
    'is_owned_by_actor',
      conversation.assigned_membership_id =
        private.actor_membership_id(conversation.operation_id),
    'automation_mode', conversation.automation_mode,
    'allowed_return_modes', case
      when exists (
        select 1
        from public.operation_settings as settings
        where settings.operation_id = conversation.operation_id
          and settings.production_enabled
      )
      and not exists (
        select 1
        from public.system_pauses as pause
        where pause.operation_id = conversation.operation_id
          and pause.status = 'active'
      )
      then jsonb_build_array('shadow', 'assisted', 'production')
      else jsonb_build_array('shadow', 'assisted')
    end,
    'is_paused', conversation.is_paused,
    'pause_reason', conversation.pause_reason,
    'pending_return', conversation.pending_return,
    'pending_return_target_mode', conversation.pending_return_target_mode,
    'requires_human_review', conversation.requires_human_review,
    'review_reason', conversation.review_reason,
    'opened_at', conversation.opened_at,
    'updated_at', conversation.updated_at,
    'version', conversation.version,
    'messages', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', message.id,
            'direction', message.direction,
            'kind', message.kind,
            'body', message.body,
            'status', message.status,
            'occurred_at', coalesce(
              message.provider_occurred_at,
              message.created_at
            ),
            'created_by_type', message.created_by_type
          )
          order by
            coalesce(message.provider_occurred_at, message.created_at),
            message.id
        )
        from public.messages as message
        where message.conversation_id = conversation.id
      ),
      '[]'::jsonb
    )
  )
  into result
  from public.conversations as conversation
  join public.contacts as contact
    on contact.id = conversation.contact_id
  join public.opportunities as opportunity
    on opportunity.id = conversation.opportunity_id
  left join public.whatsapp_connections as connection
    on connection.id = conversation.connection_id
  left join public.staff_profiles as staff_profile
    on staff_profile.membership_id = conversation.assigned_membership_id
  where conversation.id = target_conversation_id;

  if result is null then
    raise exception 'Conversation not found' using errcode = 'P0002';
  end if;

  return result;
end;
$$;

create or replace function public.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.ingest_simulated_inbound(
    target_connection_id,
    normalized_event,
    request_trace_id,
    request_correlation_id
  );
$$;

create or replace function public.get_inbox_list(
  target_operation_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.get_inbox_list(target_operation_id);
$$;

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

revoke all on function private.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated;
revoke all on function private.get_inbox_list(uuid)
  from public, anon, authenticated;
revoke all on function private.get_conversation_detail(uuid)
  from public, anon, authenticated;
revoke all on function private.assume_conversation(
  uuid, bigint, uuid, uuid
) from public, anon, authenticated;
revoke all on function private.pause_conversation(
  uuid, bigint, text, uuid, uuid
) from public, anon, authenticated;
revoke all on function private.return_conversation_to_pedro(
  uuid, bigint, text, text, uuid, uuid
) from public, anon, authenticated;
revoke all on function private.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) from public, anon, authenticated;

revoke all on function public.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated;
revoke all on function public.get_inbox_list(uuid)
  from public, anon;
revoke all on function public.get_conversation_detail(uuid)
  from public, anon;
revoke all on function public.assume_conversation(
  uuid, bigint, uuid, uuid
) from public, anon;
revoke all on function public.pause_conversation(
  uuid, bigint, text, uuid, uuid
) from public, anon;
revoke all on function public.return_conversation_to_pedro(
  uuid, bigint, text, text, uuid, uuid
) from public, anon;
revoke all on function public.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) from public, anon;

grant execute on function public.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) to service_role;
grant execute on function public.get_inbox_list(uuid) to authenticated;
grant execute on function public.get_conversation_detail(uuid)
  to authenticated;
grant execute on function public.assume_conversation(
  uuid, bigint, uuid, uuid
) to authenticated;
grant execute on function public.pause_conversation(
  uuid, bigint, text, uuid, uuid
) to authenticated;
grant execute on function public.return_conversation_to_pedro(
  uuid, bigint, text, text, uuid, uuid
) to authenticated;
grant execute on function public.send_human_message(
  uuid, bigint, uuid, text, uuid, uuid
) to authenticated;
