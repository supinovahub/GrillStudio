-- T05 review hardening.
--
-- Keep Membership deactivation and Conversation commands in one lock order,
-- reject divergent command replays, redact free-form pause reasons from audit
-- and serialize cross-connection identity materialization by canonical phone.

create or replace function private.assert_conversation_command_access(
  target_conversation_id uuid
)
returns table (
  conversation_id uuid,
  operation_id uuid,
  actor_membership_id uuid
)
language plpgsql
volatile
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

  if target_operation_id is null then
    raise exception 'Conversation permission denied' using errcode = '42501';
  end if;

  select membership.id
  into membership_id
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.organization_id = membership.organization_id
    and membership_operation.membership_id = membership.id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  if membership_id is null then
    raise exception 'active Membership required' using errcode = '42501';
  end if;

  -- Membership deactivation takes this lock before it snapshots Conversations.
  -- Commands take it before the Conversation row lock, so a revoked Membro can
  -- never become the committed human owner after the deactivation snapshot.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'membership-ownership:' || membership_id::text,
      0
    )
  );

  if not exists (
    select 1
    from public.memberships as membership
    join public.membership_operations as membership_operation
      on membership_operation.organization_id = membership.organization_id
      and membership_operation.membership_id = membership.id
    where membership.id = membership_id
      and membership.user_id = auth.uid()
      and membership.status = 'active'
      and membership_operation.operation_id = target_operation_id
  )
    or not private.can_manage_conversation_operation(target_operation_id)
  then
    raise exception 'Conversation permission denied' using errcode = '42501';
  end if;

  return query
  select target_conversation_id, target_operation_id, membership_id;
end;
$$;

revoke all on function private.assert_conversation_command_access(uuid)
  from public, anon, authenticated, service_role;

create or replace function private.enforce_active_human_conversation_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'conversations' then
    if new.status in ('active', 'sleeping')
      and new.ownership_type = 'human'
      and not exists (
        select 1
        from public.memberships as membership
        join public.membership_operations as membership_operation
          on membership_operation.organization_id = membership.organization_id
          and membership_operation.membership_id = membership.id
        where membership.id = new.assigned_membership_id
          and membership.organization_id = new.organization_id
          and membership.status = 'active'
          and membership_operation.operation_id = new.operation_id
      )
    then
      raise exception 'active Conversation human owner must be an active Membro'
        using errcode = '23514';
    end if;
  elsif tg_table_name = 'memberships' then
    if old.status = 'active'
      and new.status <> 'active'
      and exists (
        select 1
        from public.conversations as conversation
        where conversation.organization_id = new.organization_id
          and conversation.assigned_membership_id = new.id
          and conversation.ownership_type = 'human'
          and conversation.status in ('active', 'sleeping')
      )
    then
      raise exception 'inactive Membro cannot own an active Conversation'
        using errcode = '23514';
    end if;
  end if;

  return null;
end;
$$;

revoke all on function private.enforce_active_human_conversation_owner()
  from public, anon, authenticated, service_role;

create constraint trigger conversations_require_active_human_owner
after insert or update on public.conversations
deferrable initially deferred
for each row execute function private.enforce_active_human_conversation_owner();

create constraint trigger memberships_release_active_conversation_ownership
after update on public.memberships
deferrable initially deferred
for each row execute function private.enforce_active_human_conversation_owner();

alter function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) rename to deactivate_membership_after_reauthentication_t04_ownership_base;

revoke all on function
  private.deactivate_membership_after_reauthentication_t04_ownership_base(
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
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'membership-ownership:' || target_membership_id::text,
      0
    )
  );

  return query
  select *
  from private.deactivate_membership_after_reauthentication_t04_ownership_base(
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
grant execute on function private.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) to service_role;

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
  uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.deactivate_membership_after_reauthentication(
  uuid, uuid, uuid, uuid, uuid
) to service_role;

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
  normalized_reason := nullif(
    left(btrim(coalesce(pause_reason_value, '')), 500),
    ''
  );
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
      'reason_code', 'human_requested_pause',
      'operational_reason_recorded', true,
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

create or replace function private.raise_conversation_command_replay_conflict()
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise sqlstate 'PGRST' using
    message = jsonb_build_object(
      'code', '40001',
      'message', 'Conversation command replay conflict',
      'details', 'command_id was already used by another actor or payload',
      'hint', 'generate a new command_id for a different command'
    )::text,
    detail = jsonb_build_object(
      'status', 409,
      'headers', jsonb_build_object()
    )::text;
end;
$$;

revoke all on function private.raise_conversation_command_replay_conflict()
  from public, anon, authenticated, service_role;

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
  if message_text is not null and char_length(message_text) > 12000 then
    raise exception 'message text exceeds 12000 characters'
      using errcode = '22001';
  end if;

  normalized_text := case
    when nullif(btrim(coalesce(message_text, '')), '') is null then null
    else message_text
  end;
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
    if existing_message.created_by_membership_id
        = access_record.actor_membership_id
      and existing_message.direction = 'outbound'
      and existing_message.kind = 'text'
      and existing_message.body is not distinct from normalized_text
    then
      return jsonb_build_object(
        'status', 'duplicate',
        'message_id', existing_message.id,
        'conversation_id', existing_message.conversation_id,
        'version', conversation_record.version
      );
    end if;

    perform private.raise_conversation_command_replay_conflict();
  end if;

  if conversation_record.version <> expected_version then
    perform private.raise_conversation_version_conflict();
  end if;
  if conversation_record.status = 'closed'
    or conversation_record.ownership_type <> 'human'
    or conversation_record.assigned_membership_id
      <> access_record.actor_membership_id
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

alter function private.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) rename to ingest_simulated_inbound_t05_connection_base;

revoke all on function private.ingest_simulated_inbound_t05_connection_base(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;

create function private.ingest_simulated_inbound(
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
  target_organization_id uuid;
  phone_original text;
  normalized_phone text;
  result jsonb;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select connection.organization_id
  into target_organization_id
  from public.whatsapp_connections as connection
  where connection.id = target_connection_id;

  phone_original := nullif(
    btrim(coalesce(normalized_event #>> '{identity,phone_original}', '')),
    ''
  );

  if target_organization_id is not null and phone_original is not null then
    normalized_phone := private.normalize_phone_e164(phone_original, '+55');
    perform pg_advisory_xact_lock(
      hashtextextended(
        'contact-phone:' || target_organization_id::text
          || ':' || normalized_phone,
        0
      )
    );
  end if;

  result := private.ingest_simulated_inbound_t05_connection_base(
    target_connection_id,
    normalized_event,
    request_trace_id,
    request_correlation_id
  );
  return result;
end;
$$;

revoke all on function private.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;

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

revoke all on function public.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.ingest_simulated_inbound(
  uuid, jsonb, uuid, uuid
) to service_role;
