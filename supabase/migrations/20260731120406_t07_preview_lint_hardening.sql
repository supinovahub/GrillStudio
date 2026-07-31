-- Hosted Preview lint hardening. Keep the already-applied T07 migrations
-- immutable and correct only volatility metadata and unused PL/pgSQL state.

alter function private.capacity_delay_seconds(text, text, boolean) stable;

create or replace function private.enqueue_capacity_command(
  target_organization_id uuid,
  target_operation_id uuid,
  target_scheduled_job_id uuid,
  target_conversation_id uuid,
  target_backlog_id uuid,
  target_command_type text,
  target_payload jsonb,
  target_effect_key text,
  target_run_at timestamptz,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  command_record private.operation_capacity_commands%rowtype;
  request_hash_value text;
begin
  request_hash_value := private.sha256_json(
    jsonb_build_object(
      'organization_id', target_organization_id,
      'operation_id', target_operation_id,
      'scheduled_job_id', target_scheduled_job_id,
      'conversation_id', target_conversation_id,
      'backlog_id', target_backlog_id,
      'command_type', target_command_type,
      'payload', target_payload
    )
  );

  insert into private.operation_capacity_commands (
    organization_id,
    operation_id,
    scheduled_job_id,
    conversation_id,
    backlog_id,
    command_type,
    payload,
    request_hash,
    effect_key,
    run_at,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    target_scheduled_job_id,
    target_conversation_id,
    target_backlog_id,
    target_command_type,
    target_payload,
    request_hash_value,
    target_effect_key,
    target_run_at,
    request_trace_id,
    request_correlation_id
  )
  on conflict (organization_id, operation_id, effect_key)
  do update
  set
    status = case
      when private.operation_capacity_commands.status = 'failed'
        then 'pending'
      else private.operation_capacity_commands.status
    end,
    run_at = case
      when private.operation_capacity_commands.status = 'failed'
        then excluded.run_at
      when private.operation_capacity_commands.status = 'pending'
        then least(
          private.operation_capacity_commands.run_at,
          excluded.run_at
        )
      else private.operation_capacity_commands.run_at
    end,
    attempts = case
      when private.operation_capacity_commands.status = 'failed' then 0
      else private.operation_capacity_commands.attempts
    end,
    last_error_code = case
      when private.operation_capacity_commands.status = 'failed' then null
      else private.operation_capacity_commands.last_error_code
    end,
    updated_at = case
      when private.operation_capacity_commands.status = 'failed' then now()
      else private.operation_capacity_commands.updated_at
    end;

  select command.*
  into strict command_record
  from private.operation_capacity_commands as command
  where command.organization_id = target_organization_id
    and command.operation_id = target_operation_id
    and command.effect_key = target_effect_key;

  if command_record.request_hash <> request_hash_value
    or command_record.command_type <> target_command_type
    or command_record.payload <> target_payload
  then
    raise exception 'capacity command replay conflict'
      using errcode = '23505';
  end if;

  return command_record.id;
end;
$$;

revoke all on function private.enqueue_capacity_command(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, text,
  timestamptz, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.lock_response_batch_automation_context(
  target_operation_id uuid,
  target_batch_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  batch_snapshot private.pedro_response_batches%rowtype;
  locked_batch private.pedro_response_batches%rowtype;
  locked_operation_id uuid;
  conversation_record public.conversations%rowtype;
  slot_conversation_id uuid;
begin
  -- Snapshot only supplies routing keys. The global lock order is then
  -- OperationCapacity -> Slot -> Conversation -> ResponseBatch.
  select batch.*
  into strict batch_snapshot
  from private.pedro_response_batches as batch
  where batch.operation_id = target_operation_id
    and batch.id = target_batch_id;

  select state.operation_id
  into strict locked_operation_id
  from private.operation_capacity_state as state
  where state.operation_id = target_operation_id
  for update;

  if locked_operation_id is distinct from target_operation_id then
    raise exception 'response batch OperationCapacity lock mismatch'
      using errcode = '40001';
  end if;

  select slot.conversation_id
  into slot_conversation_id
  from private.conversation_capacity_slots as slot
  where slot.operation_id = target_operation_id
    and slot.conversation_id = batch_snapshot.conversation_id
  for update;

  select conversation.*
  into strict conversation_record
  from public.conversations as conversation
  where conversation.operation_id = target_operation_id
    and conversation.id = batch_snapshot.conversation_id
  for update;

  select batch.*
  into strict locked_batch
  from private.pedro_response_batches as batch
  where batch.operation_id = target_operation_id
    and batch.id = target_batch_id
  for update;

  if locked_batch.conversation_id
      is distinct from batch_snapshot.conversation_id
    or locked_batch.operation_id is distinct from batch_snapshot.operation_id
  then
    raise exception 'response batch routing changed while locking'
      using errcode = '40001';
  end if;

  return case
    when conversation_record.status <> 'active'
      then 'conversation_inactive'
    when conversation_record.ownership_type <> 'pedro'
      then 'human_owned'
    when conversation_record.is_paused
      then 'conversation_paused'
    when exists (
      select 1
      from public.opt_outs as opt_out
      where opt_out.organization_id = conversation_record.organization_id
        and opt_out.contact_id = conversation_record.contact_id
        and opt_out.status = 'active'
    ) then 'active_opt_out'
    when conversation_record.capacity_state <> 'active'
      or slot_conversation_id is null
      then 'capacity_not_active'
    else null
  end;
end;
$$;

revoke all on function private.lock_response_batch_automation_context(
  uuid, uuid
) from public, anon, authenticated, service_role;
