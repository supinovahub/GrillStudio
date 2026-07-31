-- T06 review hardening: fail-closed PGMQ surface and state invariants.

-- Queue internals are never a service-role API. All runtime access goes
-- through explicitly granted public SECURITY DEFINER RPCs whose private
-- implementations use only read/send/set_vt/archive.
revoke all on schema pgmq from service_role;
revoke all on all tables in schema pgmq from service_role;
revoke all on all sequences in schema pgmq from service_role;
revoke all on all functions in schema pgmq from service_role;

alter table private.outbox_events
  add constraint outbox_events_state_artifacts_check
  check (
    (
      status = 'pending'
      and queue_message_id is null
      and published_at is null
      and completed_at is null
    )
    or (
      status in ('published', 'processing')
      and queue_message_id is not null
      and published_at is not null
      and completed_at is null
    )
    or (
      status = 'completed'
      and queue_message_id is not null
      and published_at is not null
      and completed_at is not null
    )
    or status = 'dead'
  );

alter table public.scheduled_jobs
  add constraint scheduled_jobs_state_artifacts_check
  check (
    (
      status = 'pending'
      and lease_token is null
      and lease_until is null
      and queue_message_id is null
      and published_at is null
      and completed_at is null
    )
    or (
      status = 'leased'
      and lease_token is not null
      and lease_until is not null
      and queue_message_id is null
      and published_at is null
      and completed_at is null
    )
    or (
      status = 'published'
      and lease_token is null
      and lease_until is null
      and queue_message_id is not null
      and published_at is not null
      and completed_at is null
    )
    or (
      status = 'completed'
      and lease_token is null
      and lease_until is null
      and queue_message_id is not null
      and published_at is not null
      and completed_at is not null
    )
    or (
      status in ('cancelled', 'dead')
      and lease_token is null
      and lease_until is null
    )
  );

alter table private.dead_letters
  add constraint dead_letters_state_artifacts_check
  check (
    (
      status = 'pending'
      and replayed_at is null
      and replayed_by_user_id is null
      and replay_queue_message_id is null
      and resolved_at is null
    )
    or (
      status = 'replayed'
      and replayed_at is not null
      and replayed_by_user_id is not null
      and replay_queue_message_id is not null
      and resolved_at is null
    )
    or (
      status = 'resolved'
      and resolved_at is not null
    )
  );

create index conversation_processing_leases_tenant_fk_idx
  on private.conversation_processing_leases (
    organization_id,
    operation_id,
    conversation_id
  );
create index processing_attempts_tenant_fk_idx
  on private.processing_attempts (organization_id, operation_id);
create index dead_letters_tenant_fk_idx
  on private.dead_letters (organization_id, operation_id);
create index dead_letters_replayed_by_user_fk_idx
  on private.dead_letters (replayed_by_user_id)
  where replayed_by_user_id is not null;

create or replace function public.replay_dead_letter(
  target_dead_letter_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  letter_record private.dead_letters%rowtype;
  event_record private.outbox_events%rowtype;
  queue_id bigint;
begin
  select letter.*
  into strict letter_record
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id
  for update;

  if not private.has_membership_permission(
    letter_record.operation_id,
    'manage_conversations'
  ) then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;
  if letter_record.status = 'replayed' then
    return jsonb_build_object(
      'status', 'duplicate',
      'dead_letter_id', letter_record.id,
      'queue_message_id', letter_record.replay_queue_message_id
    );
  end if;
  if letter_record.status <> 'pending' then
    raise exception 'only pending dead letters can be replayed'
      using errcode = '23514';
  end if;

  if letter_record.source_queue = 'inbound_whatsapp' then
    select sent.msg_id into strict queue_id
    from pgmq.send(
      queue_name => letter_record.source_queue,
      msg => letter_record.redacted_envelope
    ) as sent(msg_id);
    update private.webhook_inbox
    set
      status = 'accepted',
      attempts = 0,
      queue_message_id = queue_id,
      processing_started_at = null,
      processed_at = null,
      last_error_class = null,
      last_error_code = null,
      updated_at = now()
    where id = letter_record.envelope_id;
    if not found then
      raise exception 'dead-letter inbox artifact is missing'
        using errcode = 'P0002';
    end if;
  else
    select event.*
    into strict event_record
    from private.outbox_events as event
    where event.id = letter_record.envelope_id
    for update;

    select sent.msg_id into strict queue_id
    from pgmq.send(
      queue_name => letter_record.source_queue,
      msg => letter_record.redacted_envelope
    ) as sent(msg_id);

    update private.outbox_events
    set
      status = 'published',
      attempts = 1,
      queue_message_id = queue_id,
      published_at = now(),
      completed_at = null,
      last_error_class = null,
      last_error_code = null,
      updated_at = now()
    where id = event_record.id;
  end if;

  update private.dead_letters
  set
    status = 'replayed',
    replayed_at = now(),
    replayed_by_user_id = auth.uid(),
    replay_queue_message_id = queue_id
  where id = letter_record.id;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    letter_record.organization_id,
    letter_record.operation_id,
    auth.uid(),
    'dead_letter.replayed',
    'dead_letter',
    letter_record.id,
    jsonb_build_object(
      'status', letter_record.status,
      'source_queue', letter_record.source_queue,
      'effect_key_hash', md5(letter_record.effect_key)
    ),
    jsonb_build_object(
      'status', 'replayed',
      'effect_key_preserved', true,
      'queue_message_id', queue_id
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'status', 'replayed',
    'dead_letter_id', letter_record.id,
    'queue_message_id', queue_id
  );
end;
$$;

revoke all on function public.replay_dead_letter(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.replay_dead_letter(uuid, uuid, uuid)
  to authenticated;
