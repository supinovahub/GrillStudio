-- T06 maintenance and replay lock-order corrections.

-- The replay guard only needs to lock a binding-mismatch letter because it
-- resolves that letter locally. Every replayable case delegates without
-- retaining a DeadLetter lock so the established Stream -> Inbox ->
-- DeadLetter order remains intact.
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
begin
  select letter.*
  into strict letter_record
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id;

  if letter_record.operation_id is null
    or not private.has_membership_permission(
      letter_record.operation_id,
      'manage_conversations'
    )
  then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;

  if letter_record.source_queue = 'reconciliation'
    and letter_record.failure_code = 'queue_binding_mismatch'
  then
    select letter.*
    into strict letter_record
    from private.dead_letters as letter
    where letter.id = target_dead_letter_id
    for update;

    if letter_record.status = 'pending' then
      update private.dead_letters
      set
        status = 'resolved',
        resolved_at = now(),
        resolution_reason = 'non_replayable_queue_binding_mismatch'
      where id = letter_record.id;
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
      letter_record.organization_id,
      letter_record.operation_id,
      auth.uid(),
      'dead_letter.replay_binding_mismatch_rejected',
      'dead_letter',
      letter_record.id,
      jsonb_build_object(
        'status', letter_record.status,
        'source_queue', letter_record.source_queue,
        'failure_code', letter_record.failure_code
      ),
      jsonb_build_object(
        'status', 'resolved',
        'reason', 'queue_binding_mismatch',
        'event_republished', false
      ),
      request_trace_id,
      request_correlation_id
    );

    return jsonb_build_object(
      'status', 'rejected_non_replayable',
      'reason', 'queue_binding_mismatch',
      'dead_letter_id', letter_record.id
    );
  end if;

  return public.replay_dead_letter_t06_nonreplayable_base(
    target_dead_letter_id,
    request_trace_id,
    request_correlation_id
  );
end;
$$;

revoke all on function public.replay_dead_letter(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.replay_dead_letter(uuid, uuid, uuid)
  to authenticated;

-- Expiry owns each Inbox before its pending DeadLetter. This matches replay
-- and worker ordering while still limiting the number of letter/alert
-- transitions to maximum_rows.
create or replace function private.prune_durable_sensitive_material(
  maximum_rows integer default 5000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate record;
  expired_letters integer := 0;
  purged_inbox integer := 0;
  purged_letters integer := 0;
begin
  if maximum_rows not between 1 and 25000 then
    raise exception 'invalid durable retention bound'
      using errcode = '22023';
  end if;

  -- Serialize this bounded maintenance routine without joining the domain
  -- lock graph. The advisory key is private to this pruner.
  if not pg_try_advisory_xact_lock(
    hashtextextended('t06:prune_durable_sensitive_material', 0)
  ) then
    return jsonb_build_object(
      'raw_webhooks_purged', 0,
      'pending_replays_expired', 0,
      'resolved_dead_letters_purged', 0,
      'skipped_locked', true
    );
  end if;

  for candidate in
    select
      inbox.id as inbox_id,
      letter.id as letter_id
    from private.dead_letters as letter
    join private.webhook_inbox as inbox
      on inbox.id = letter.envelope_id
      and letter.source_queue = 'inbound_whatsapp'
    left join private.durable_retention_policies as policy
      on policy.organization_id = inbox.organization_id
      and policy.operation_id = inbox.operation_id
    where letter.status = 'pending'
      and inbox.status = 'dead'
      and inbox.raw_payload_purged_at is null
      and coalesce(inbox.processed_at, inbox.updated_at)
        < now() - coalesce(
          policy.webhook_raw_retention,
          interval '24 hours'
        )
    order by
      coalesce(inbox.processed_at, inbox.updated_at),
      inbox.id,
      letter.created_at,
      letter.id
    limit maximum_rows
  loop
    perform inbox.id
    from private.webhook_inbox as inbox
    where inbox.id = candidate.inbox_id
    for update;

    perform letter.id
    from private.dead_letters as letter
    where letter.id = candidate.letter_id
      and letter.status = 'pending'
    for update;

    if found then
      update private.dead_letters
      set
        status = 'resolved',
        resolved_at = coalesce(resolved_at, now()),
        resolution_reason = 'payload_expired'
      where id = candidate.letter_id;
      expired_letters := expired_letters + 1;
    end if;
  end loop;

  with doomed as (
    select inbox.id
    from private.webhook_inbox as inbox
    left join private.durable_retention_policies as policy
      on policy.organization_id = inbox.organization_id
      and policy.operation_id = inbox.operation_id
    where inbox.status in ('processed', 'unsupported', 'dead')
      and inbox.raw_payload_purged_at is null
      and coalesce(inbox.processed_at, inbox.updated_at)
        < now() - coalesce(
          policy.webhook_raw_retention,
          interval '24 hours'
        )
      and (
        inbox.status <> 'dead'
        or not exists (
          select 1
          from private.dead_letters as pending_letter
          where pending_letter.source_queue = 'inbound_whatsapp'
            and pending_letter.envelope_id = inbox.id
            and pending_letter.status = 'pending'
        )
      )
    order by coalesce(inbox.processed_at, inbox.updated_at), inbox.id
    for update of inbox skip locked
    limit maximum_rows
  )
  update private.webhook_inbox as inbox
  set
    raw_body = null,
    raw_payload = '{}'::jsonb,
    normalized_payload = '{}'::jsonb,
    raw_payload_purged_at = now(),
    updated_at = now()
  from doomed
  where inbox.id = doomed.id;
  get diagnostics purged_inbox = row_count;

  with doomed as (
    select letter.id
    from private.dead_letters as letter
    left join private.durable_retention_policies as policy
      on policy.organization_id = letter.organization_id
      and policy.operation_id = letter.operation_id
    where letter.status in ('replayed', 'resolved')
      and coalesce(
        letter.resolved_at,
        letter.replayed_at,
        letter.created_at
      ) < now() - coalesce(
        policy.resolved_dead_letter_retention,
        interval '30 days'
      )
    order by coalesce(
      letter.resolved_at,
      letter.replayed_at,
      letter.created_at
    ), letter.id
    for update of letter skip locked
    limit maximum_rows
  )
  delete from private.dead_letters as letter
  using doomed
  where letter.id = doomed.id;
  get diagnostics purged_letters = row_count;

  return jsonb_build_object(
    'raw_webhooks_purged', purged_inbox,
    'pending_replays_expired', expired_letters,
    'resolved_dead_letters_purged', purged_letters,
    'skipped_locked', false
  );
end;
$$;

revoke all on function private.prune_durable_sensitive_material(integer)
  from public, anon, authenticated, service_role;

-- Quarantine and dead-letter status transitions lock DeadLetter before Alert.
-- Resolve infrastructure alerts in the same order.
create or replace function public.resolve_infrastructure_durable_alert(
  target_alert_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  alert_snapshot private.durable_processing_alerts%rowtype;
  alert_record private.durable_processing_alerts%rowtype;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if target_alert_id is null
    or request_trace_id is null
    or request_correlation_id is null
  then
    raise exception 'alert, trace, and correlation identifiers are required'
      using errcode = '22023';
  end if;

  select alert.*
  into strict alert_snapshot
  from private.durable_processing_alerts as alert
  where alert.id = target_alert_id
    and alert.organization_id is null
    and alert.operation_id is null;

  perform letter.id
  from private.dead_letters as letter
  where letter.id = alert_snapshot.dead_letter_id
  for update;

  select alert.*
  into strict alert_record
  from private.durable_processing_alerts as alert
  where alert.id = target_alert_id
    and alert.organization_id is null
    and alert.operation_id is null
    and alert.dead_letter_id = alert_snapshot.dead_letter_id
  for update;

  if alert_record.status = 'resolved' then
    return jsonb_build_object(
      'status', 'duplicate',
      'alert_id', alert_record.id,
      'dead_letter_id', alert_record.dead_letter_id
    );
  end if;

  update private.dead_letters
  set
    status = 'resolved',
    resolved_at = coalesce(resolved_at, now()),
    resolution_reason = coalesce(
      resolution_reason,
      'service_acknowledged'
    )
  where id = alert_record.dead_letter_id
    and status = 'pending';

  update private.durable_processing_alerts
  set
    status = 'resolved',
    resolved_at = now(),
    resolution_source = 'service_role',
    resolution_trace_id = request_trace_id,
    resolution_correlation_id = request_correlation_id
  where id = alert_record.id;

  insert into private.infrastructure_durable_alert_resolutions (
    alert_id,
    dead_letter_id,
    resolution_trace_id,
    resolution_correlation_id
  )
  values (
    alert_record.id,
    alert_record.dead_letter_id,
    request_trace_id,
    request_correlation_id
  )
  on conflict (alert_id) do nothing;

  return jsonb_build_object(
    'status', 'resolved',
    'alert_id', alert_record.id,
    'dead_letter_id', alert_record.dead_letter_id
  );
end;
$$;

revoke all on function public.resolve_infrastructure_durable_alert(
  uuid, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.resolve_infrastructure_durable_alert(
  uuid, uuid, uuid
) to service_role;
