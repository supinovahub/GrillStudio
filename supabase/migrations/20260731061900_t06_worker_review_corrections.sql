-- T06 post-review corrections: quarantined queue envelopes, bounded workers,
-- stable lock ordering and contention that never consumes failure attempts.

-- A command that fails its last preflight is terminal, not eternally queued.
alter table public.messages
  drop constraint messages_status_check,
  add constraint messages_status_check
    check (status in ('received', 'queued', 'captured', 'suppressed'));

create or replace function private.terminalize_suppressed_outbound()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'completed'
    and new.last_error_class = 'conflict'
    and new.last_error_code in (
      'event_status_stale',
      'event_contract_stale',
      'message_binding_stale',
      'message_status_stale',
      'aggregate_version_stale',
      'conversation_status_stale',
      'conversation_ownership_stale',
      'actor_stale',
      'connection_stale'
    )
    and old.status is distinct from new.status
  then
    update public.messages
    set status = 'suppressed'
    where id = nullif(new.payload ->> 'message_id', '')::uuid
      and organization_id = new.organization_id
      and operation_id = new.operation_id
      and status = 'queued';
  end if;
  return null;
end;
$$;

revoke all on function private.terminalize_suppressed_outbound()
  from public, anon, authenticated, service_role;

create trigger outbox_terminalize_suppressed_message
after update of status, last_error_class, last_error_code
on private.outbox_events
for each row execute function private.terminalize_suppressed_outbound();

create or replace function private.normalize_suppression_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.action = 'message.outbound_suppressed' then
    new.after_state := jsonb_set(
      coalesce(new.after_state, '{}'::jsonb),
      '{status}',
      '"suppressed"'::jsonb,
      true
    );
  end if;
  return new;
end;
$$;

revoke all on function private.normalize_suppression_audit()
  from public, anon, authenticated, service_role;

create trigger audit_normalize_outbound_suppression
before insert on audit.audit_events
for each row execute function private.normalize_suppression_audit();

-- FK and trigger lookups must remain bounded as alerts accumulate.
create index durable_processing_alerts_tenant_fk_idx
  on private.durable_processing_alerts (organization_id, operation_id)
  where organization_id is not null;
create index durable_processing_alerts_scheduled_job_fk_idx
  on private.durable_processing_alerts (
    organization_id,
    operation_id,
    scheduled_job_id
  )
  where scheduled_job_id is not null;
create index durable_processing_alerts_open_scheduled_job_idx
  on private.durable_processing_alerts (scheduled_job_id)
  where status = 'open' and scheduled_job_id is not null;

create or replace function private.resolve_dead_letter_processing_alert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('replayed', 'resolved')
    and old.status is distinct from new.status
  then
    update private.durable_processing_alerts
    set
      status = 'resolved',
      resolved_at = coalesce(resolved_at, now())
    where dead_letter_id = new.id
      and status = 'open';
  end if;
  return null;
end;
$$;

revoke all on function private.resolve_dead_letter_processing_alert()
  from public, anon, authenticated, service_role;

create trigger dead_letters_resolve_processing_alert
after update of status on private.dead_letters
for each row execute function private.resolve_dead_letter_processing_alert();

-- The original local variable had the same name as the alert FK column.
-- PL/pgSQL therefore rejected the ON CONFLICT clause as ambiguous precisely
-- when a worker attempted to quarantine a poison envelope.
create or replace function private.dead_letter_queue_message(
  target_queue text,
  target_message_id bigint,
  target_envelope_id uuid,
  target_effect_key text,
  target_envelope jsonb,
  target_attempts integer,
  target_failure_class text,
  target_failure_code text,
  target_organization_id uuid,
  target_operation_id uuid,
  target_trace_id uuid,
  target_correlation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_dead_letter_id uuid;
  scheduled_job_id_value uuid;
begin
  insert into private.dead_letters (
    organization_id,
    operation_id,
    source_queue,
    source_message_id,
    envelope_id,
    effect_key,
    redacted_envelope,
    attempts,
    failure_class,
    failure_code,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    target_queue,
    target_message_id,
    target_envelope_id,
    target_effect_key,
    target_envelope,
    target_attempts,
    left(target_failure_class, 120),
    left(target_failure_code, 120),
    target_trace_id,
    target_correlation_id
  )
  on conflict (source_queue, source_message_id)
  do update set
    attempts = excluded.attempts,
    failure_class = excluded.failure_class,
    failure_code = excluded.failure_code
  returning id into created_dead_letter_id;

  if target_queue = 'scheduled_actions' then
    select job.id
    into scheduled_job_id_value
    from public.scheduled_jobs as job
    where job.id = target_envelope_id
      and job.organization_id = target_organization_id
      and job.operation_id = target_operation_id;
  end if;

  insert into private.durable_processing_alerts (
    organization_id,
    operation_id,
    dead_letter_id,
    scheduled_job_id,
    source_queue,
    severity,
    failure_class,
    failure_code,
    effect_key_hash,
    trace_id,
    correlation_id
  )
  values (
    target_organization_id,
    target_operation_id,
    created_dead_letter_id,
    scheduled_job_id_value,
    target_queue,
    case
      when target_queue = 'scheduled_actions' then 'action_required'
      else 'critical'
    end,
    left(target_failure_class, 120),
    left(target_failure_code, 120),
    encode(sha256(convert_to(target_effect_key, 'UTF8')), 'hex'),
    target_trace_id,
    target_correlation_id
  )
  on conflict (dead_letter_id)
  do update set
    failure_class = excluded.failure_class,
    failure_code = excluded.failure_code,
    severity = excluded.severity;

  perform pgmq.send(
    queue_name => 'dead_letter',
    msg => jsonb_build_object(
      'dead_letter_id', created_dead_letter_id,
      'source_queue', target_queue,
      'envelope_id', target_envelope_id,
      'trace_id', target_trace_id,
      'correlation_id', target_correlation_id
    )
  );
  perform pgmq.archive(target_queue, target_message_id);
  return created_dead_letter_id;
end;
$$;

revoke all on function private.dead_letter_queue_message(
  text, bigint, uuid, text, jsonb, integer, text, text,
  uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

-- Raw provider material is useful briefly for diagnosis but is not a
-- permanent message store. Hashes and canonical domain rows are preserved.
alter table private.webhook_inbox
  alter column raw_body drop not null,
  add column raw_payload_purged_at timestamptz;

create or replace function private.capture_webhook_raw_body()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  configured_body text := current_setting('app.t06_raw_body', true);
  configured_hash text := current_setting('app.t06_raw_body_hash', true);
  effective_body text;
  computed_hash text;
begin
  effective_body := coalesce(
    nullif(configured_body, ''),
    new.raw_body,
    new.raw_payload::text
  );
  computed_hash := encode(
    sha256(convert_to(effective_body, 'UTF8')),
    'hex'
  );

  if nullif(configured_hash, '') is not null
    and configured_hash <> computed_hash
  then
    raise exception 'raw webhook hash does not match raw body'
      using errcode = '23514';
  end if;

  new.raw_body := effective_body;
  new.raw_body_hash := computed_hash;
  new.raw_payload := effective_body::jsonb;
  new.payload_hash := computed_hash;
  return new;
end;
$$;

revoke all on function private.capture_webhook_raw_body()
  from public, anon, authenticated, service_role;

update private.webhook_inbox
set
  raw_body_hash = encode(
    sha256(convert_to(raw_body, 'UTF8')),
    'hex'
  ),
  payload_hash = encode(
    sha256(convert_to(raw_body, 'UTF8')),
    'hex'
  )
where raw_body is not null;

alter table private.webhook_inbox
  add constraint webhook_inbox_raw_body_hash_matches_check
    check (
      raw_body is null
      or raw_body_hash = encode(
        sha256(convert_to(raw_body, 'UTF8')),
        'hex'
      )
    ),
  add constraint webhook_inbox_payload_hash_matches_raw_check
    check (payload_hash = raw_body_hash);

create table private.durable_retention_policies (
  organization_id uuid not null,
  operation_id uuid not null,
  webhook_raw_retention interval not null default interval '24 hours'
    check (
      webhook_raw_retention >= interval '1 hour'
      and webhook_raw_retention <= interval '30 days'
    ),
  resolved_dead_letter_retention interval not null default interval '30 days'
    check (
      resolved_dead_letter_retention >= interval '1 day'
      and resolved_dead_letter_retention <= interval '365 days'
    ),
  updated_at timestamptz not null default now(),
  primary key (organization_id, operation_id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

revoke all on table private.durable_retention_policies
  from public, anon, authenticated;
grant all on table private.durable_retention_policies to service_role;

create index webhook_inbox_raw_retention_idx
  on private.webhook_inbox (
    (coalesce(processed_at, updated_at)),
    id
  )
  where status in ('processed', 'unsupported')
    and raw_payload_purged_at is null;

create index dead_letters_resolved_retention_idx
  on private.dead_letters (
    (coalesce(resolved_at, replayed_at, created_at)),
    id
  )
  where status in ('replayed', 'resolved');

create or replace function private.prune_durable_sensitive_material(
  maximum_rows integer default 5000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  purged_inbox integer := 0;
  purged_letters integer := 0;
begin
  if maximum_rows not between 1 and 25000 then
    raise exception 'invalid durable retention bound'
      using errcode = '22023';
  end if;

  with doomed as (
    select inbox.id
    from private.webhook_inbox as inbox
    left join private.durable_retention_policies as policy
      on policy.organization_id = inbox.organization_id
      and policy.operation_id = inbox.operation_id
    where inbox.status in ('processed', 'unsupported')
      and inbox.raw_payload_purged_at is null
      and coalesce(inbox.processed_at, inbox.updated_at)
        < now() - coalesce(
          policy.webhook_raw_retention,
          interval '24 hours'
        )
    order by coalesce(inbox.processed_at, inbox.updated_at), inbox.id
    for update of inbox skip locked
    limit maximum_rows
  )
  update private.webhook_inbox as inbox
  set
    raw_body = null,
    raw_payload = '{}'::jsonb,
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
    'resolved_dead_letters_purged', purged_letters
  );
end;
$$;

revoke all on function private.prune_durable_sensitive_material(integer)
  from public, anon, authenticated, service_role;

-- Reserve a queue batch in one statement. Valid rows stay locked by this
-- transaction and are made immediately visible to the fenced base consumer.
-- Poison or orphan envelopes are archived into a redacted DLQ first, so a
-- cast or STRICT lookup can never abort the whole Cron invocation.
create or replace function private.reserve_valid_queue_batch(
  target_queue text,
  maximum_messages integer,
  visibility_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  queue_record pgmq.message_record;
  envelope_id_value uuid;
  envelope_field text;
  artifact_exists boolean;
  valid_count integer := 0;
  quarantined_count integer := 0;
  failure_code text;
begin
  if target_queue not in (
    'inbound_whatsapp',
    'outbound_whatsapp',
    'reconciliation'
  )
    or maximum_messages not between 1 and 100
    or visibility_seconds not between 5 and 3600
  then
    raise exception 'invalid queue reservation bounds'
      using errcode = '22023';
  end if;

  envelope_field := case
    when target_queue = 'inbound_whatsapp' then 'inbox_id'
    else 'outbox_event_id'
  end;

  for queue_record in
    select claimed.*
    from pgmq.read(
      queue_name => target_queue,
      vt => visibility_seconds,
      qty => maximum_messages,
      conditional => '{}'::jsonb
    ) as claimed
    order by claimed.msg_id
  loop
    envelope_id_value := null;
    artifact_exists := false;
    failure_code := null;

    begin
      envelope_id_value :=
        (queue_record.message ->> envelope_field)::uuid;
    exception when invalid_text_representation then
      envelope_id_value := null;
    end;

    if envelope_id_value is null then
      failure_code := 'invalid_envelope';
    elsif target_queue = 'inbound_whatsapp' then
      perform inbox.id
      from private.webhook_inbox as inbox
      where inbox.id = envelope_id_value
      for key share;
      artifact_exists := found;
    else
      perform event.id
      from private.outbox_events as event
      where event.id = envelope_id_value
      for key share;
      artifact_exists := found;
    end if;

    if failure_code is null and not artifact_exists then
      failure_code := 'artifact_missing';
    end if;

    if failure_code is not null then
      perform private.dead_letter_queue_message(
        target_queue,
        queue_record.msg_id,
        coalesce(envelope_id_value, gen_random_uuid()),
        'invalid-envelope:' || target_queue || ':'
          || queue_record.msg_id::text,
        jsonb_build_object(
          'queue_message_id', queue_record.msg_id,
          'envelope_id', envelope_id_value
        ),
        1,
        'non_retryable',
        failure_code,
        null,
        null,
        gen_random_uuid(),
        gen_random_uuid()
      );
      quarantined_count := quarantined_count + 1;
    else
      perform *
      from pgmq.set_vt(
        queue_name => target_queue,
        msg_id => queue_record.msg_id,
        vt => 0
      );
      valid_count := valid_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'valid', valid_count,
    'quarantined', quarantined_count
  );
end;
$$;

revoke all on function private.reserve_valid_queue_batch(
  text, integer, integer
) from public, anon, authenticated, service_role;

create or replace function private.classify_worker_failure(
  error_sqlstate text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when error_sqlstate in ('40001', '40P01', '55P03')
      then 'contention'
    when error_sqlstate = '57014'
      or error_sqlstate like '08%'
      or error_sqlstate like '53%'
      or error_sqlstate like '57P%'
      then 'retryable'
    when error_sqlstate in ('23503', '23505', '23514', 'PGRST')
      then 'conflict'
    when error_sqlstate in ('22023', '22P02', '23502', '42501', 'P0002')
      then 'non_retryable'
    else 'unknown'
  end;
$$;

create or replace function private.classify_scheduled_failure(
  error_sqlstate text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select private.classify_worker_failure(error_sqlstate);
$$;

revoke all on function private.classify_worker_failure(text)
  from public, anon, authenticated, service_role;
revoke all on function private.classify_scheduled_failure(text)
  from public, anon, authenticated, service_role;

-- The fenced base consumers predate the explicit contention class. They may
-- enter their terminal branch for that class; this normalizer runs in the same
-- transaction, restores the envelope with the same effect key, and rewrites
-- the observation as a defer without consuming the failure budget.
create or replace function private.normalize_worker_contention(
  target_worker_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  attempt_record private.processing_attempts%rowtype;
  letter_record private.dead_letters%rowtype;
  new_queue_message_id bigint;
  normalized_count integer := 0;
  requeued_count integer := 0;
begin
  for attempt_record in
    select attempt.*
    from private.processing_attempts as attempt
    where attempt.worker_id = target_worker_id
      and attempt.state in ('retryable_failed', 'dead_lettered')
      and attempt.error_code in ('40001', '40P01', '55P03')
    order by attempt.id
    for update
  loop
    new_queue_message_id := attempt_record.queue_message_id;

    if attempt_record.state = 'dead_lettered' then
      select letter.*
      into strict letter_record
      from private.dead_letters as letter
      where letter.source_queue = attempt_record.queue_name
        and letter.source_message_id = attempt_record.queue_message_id
      for update;

      select sent.msg_id
      into strict new_queue_message_id
      from pgmq.send(
        queue_name => attempt_record.queue_name,
        msg => letter_record.redacted_envelope,
        delay => private.worker_contention_delay_seconds(
          greatest(attempt_record.attempt, 1)
        )
      ) as sent(msg_id);

      update private.dead_letters
      set status = 'resolved', resolved_at = now()
      where id = letter_record.id;
      requeued_count := requeued_count + 1;
    end if;

    if attempt_record.queue_name = 'inbound_whatsapp' then
      update private.webhook_inbox
      set
        status = 'accepted',
        attempts = greatest(attempt_record.attempt - 1, 0),
        contention_count = contention_count + 1,
        queue_message_id = new_queue_message_id,
        processing_started_at = null,
        last_error_class = 'contention',
        last_error_code = attempt_record.error_code,
        updated_at = now()
      where id = attempt_record.envelope_id;
    elsif attempt_record.queue_name = 'outbound_whatsapp' then
      update private.outbox_events
      set
        status = 'published',
        attempts = greatest(attempt_record.attempt - 1, 0),
        contention_count = contention_count + 1,
        queue_message_id = new_queue_message_id,
        published_at = coalesce(published_at, now()),
        completed_at = null,
        last_error_class = 'contention',
        last_error_code = attempt_record.error_code,
        updated_at = now()
      where id = attempt_record.envelope_id;
    elsif attempt_record.queue_name = 'scheduled_actions' then
      update public.scheduled_jobs
      set
        status = 'published',
        attempts = greatest(attempt_record.attempt - 1, 0),
        contention_count = contention_count + 1,
        lease_token = null,
        lease_until = null,
        queue_message_id = new_queue_message_id,
        published_at = coalesce(published_at, now()),
        completed_at = null,
        last_error_class = 'contention',
        last_error_code = attempt_record.error_code,
        updated_at = now()
      where id = attempt_record.envelope_id;
    end if;

    update private.processing_attempts
    set
      state = 'deferred',
      error_class = 'contention'
    where id = attempt_record.id;
    normalized_count := normalized_count + 1;
  end loop;

  return jsonb_build_object(
    'normalized', normalized_count,
    'requeued_from_dead', requeued_count
  );
end;
$$;

revoke all on function private.normalize_worker_contention(uuid)
  from public, anon, authenticated, service_role;

alter function private.consume_inbound_whatsapp(integer, uuid, integer)
  rename to consume_inbound_whatsapp_t06_fenced_base;
alter function private.consume_outbound_whatsapp(integer, uuid, integer)
  rename to consume_outbound_whatsapp_t06_fenced_base;
alter function private.consume_reconciliation(integer)
  rename to consume_reconciliation_t06_unguarded_base;

revoke all on function private.consume_inbound_whatsapp_t06_fenced_base(
  integer, uuid, integer
) from public, anon, authenticated, service_role;
revoke all on function private.consume_outbound_whatsapp_t06_fenced_base(
  integer, uuid, integer
) from public, anon, authenticated, service_role;
revoke all on function private.consume_reconciliation_t06_unguarded_base(
  integer
) from public, anon, authenticated, service_role;

create function private.consume_inbound_whatsapp(
  maximum_messages integer default 10,
  target_worker_id uuid default gen_random_uuid(),
  visibility_seconds integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  reservation jsonb;
  base_result jsonb;
  contention_result jsonb;
  valid_count integer;
  quarantined_count integer;
  requeued_count integer;
begin
  reservation := private.reserve_valid_queue_batch(
    'inbound_whatsapp',
    maximum_messages,
    visibility_seconds
  );
  valid_count := (reservation ->> 'valid')::integer;
  quarantined_count := (reservation ->> 'quarantined')::integer;

  if valid_count = 0 then
    return jsonb_build_object(
      'processed', 0,
      'deferred', 0,
      'dead_lettered', quarantined_count,
      'worker_id', target_worker_id
    );
  end if;

  base_result := private.consume_inbound_whatsapp_t06_fenced_base(
    valid_count,
    target_worker_id,
    visibility_seconds
  );
  contention_result :=
    private.normalize_worker_contention(target_worker_id);
  requeued_count :=
    coalesce((contention_result ->> 'requeued_from_dead')::integer, 0);
  base_result := jsonb_set(
    base_result,
    '{dead_lettered}',
    to_jsonb(
      coalesce((base_result ->> 'dead_lettered')::integer, 0)
        + quarantined_count
        - requeued_count
    )
  );
  return jsonb_set(
    base_result,
    '{deferred}',
    to_jsonb(
      coalesce((base_result ->> 'deferred')::integer, 0)
        + requeued_count
    )
  );
end;
$$;

revoke all on function private.consume_inbound_whatsapp(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

create function private.consume_outbound_whatsapp(
  maximum_messages integer default 10,
  target_worker_id uuid default gen_random_uuid(),
  visibility_seconds integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  reservation jsonb;
  base_result jsonb;
  contention_result jsonb;
  valid_count integer;
  quarantined_count integer;
  requeued_count integer;
begin
  reservation := private.reserve_valid_queue_batch(
    'outbound_whatsapp',
    maximum_messages,
    visibility_seconds
  );
  valid_count := (reservation ->> 'valid')::integer;
  quarantined_count := (reservation ->> 'quarantined')::integer;

  if valid_count = 0 then
    return jsonb_build_object(
      'processed', 0,
      'deferred', 0,
      'dead_lettered', quarantined_count,
      'suppressed', 0,
      'worker_id', target_worker_id
    );
  end if;

  base_result := private.consume_outbound_whatsapp_t06_fenced_base(
    valid_count,
    target_worker_id,
    visibility_seconds
  );
  contention_result :=
    private.normalize_worker_contention(target_worker_id);
  requeued_count :=
    coalesce((contention_result ->> 'requeued_from_dead')::integer, 0);
  base_result := jsonb_set(
    base_result,
    '{dead_lettered}',
    to_jsonb(
      coalesce((base_result ->> 'dead_lettered')::integer, 0)
        + quarantined_count
        - requeued_count
    )
  );
  return jsonb_set(
    base_result,
    '{deferred}',
    to_jsonb(
      coalesce((base_result ->> 'deferred')::integer, 0)
        + requeued_count
    )
  );
end;
$$;

revoke all on function private.consume_outbound_whatsapp(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

create function private.consume_reconciliation(
  maximum_messages integer default 50
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  reservation jsonb;
  valid_count integer;
  quarantined_count integer;
  consumed_count integer := 0;
begin
  if maximum_messages not between 1 and 100 then
    raise exception 'invalid reconciliation worker bound'
      using errcode = '22023';
  end if;

  reservation := private.reserve_valid_queue_batch(
    'reconciliation',
    maximum_messages,
    30
  );
  valid_count := (reservation ->> 'valid')::integer;
  quarantined_count := (reservation ->> 'quarantined')::integer;
  if valid_count > 0 then
    consumed_count :=
      private.consume_reconciliation_t06_unguarded_base(valid_count);
  end if;
  return consumed_count + quarantined_count;
end;
$$;

revoke all on function private.consume_reconciliation(integer)
  from public, anon, authenticated, service_role;

alter function private.consume_scheduled_actions(integer, uuid, integer)
  rename to consume_scheduled_actions_t06_classified_base;

revoke all on function private.consume_scheduled_actions_t06_classified_base(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

create function private.consume_scheduled_actions(
  maximum_messages integer default 10,
  target_worker_id uuid default gen_random_uuid(),
  visibility_seconds integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_result jsonb;
  contention_result jsonb;
  requeued_count integer;
begin
  base_result := private.consume_scheduled_actions_t06_classified_base(
    maximum_messages,
    target_worker_id,
    visibility_seconds
  );
  contention_result :=
    private.normalize_worker_contention(target_worker_id);
  requeued_count :=
    coalesce((contention_result ->> 'requeued_from_dead')::integer, 0);

  base_result := jsonb_set(
    base_result,
    '{dead_lettered}',
    to_jsonb(
      coalesce((base_result ->> 'dead_lettered')::integer, 0)
        - requeued_count
    )
  );
  return jsonb_set(
    base_result,
    '{deferred}',
    to_jsonb(
      coalesce((base_result ->> 'deferred')::integer, 0)
        + requeued_count
    )
  );
end;
$$;

revoke all on function private.consume_scheduled_actions(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

create or replace function private.consume_dead_letter_signals(
  maximum_messages integer default 100
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  queue_record pgmq.message_record;
  consumed_count integer := 0;
begin
  if maximum_messages not between 1 and 500 then
    raise exception 'invalid dead-letter signal bound'
      using errcode = '22023';
  end if;

  for queue_record in
    select claimed.*
    from pgmq.read(
      queue_name => 'dead_letter',
      vt => 30,
      qty => maximum_messages,
      conditional => '{}'::jsonb
    ) as claimed
    order by claimed.msg_id
  loop
    -- The durable artifact and alert already live in relational tables. This
    -- queue is only a wake signal, so malformed or orphan signals are acked.
    perform pgmq.archive('dead_letter', queue_record.msg_id);
    consumed_count := consumed_count + 1;
  end loop;
  return consumed_count;
end;
$$;

revoke all on function private.consume_dead_letter_signals(integer)
  from public, anon, authenticated, service_role;

-- Workers lock their canonical artifact before creating/updating a dead
-- letter. Manual replay follows the same Artifact -> DeadLetter order.
alter function public.replay_dead_letter(uuid, uuid, uuid)
  rename to replay_dead_letter_t06_review_base;

revoke all on function public.replay_dead_letter_t06_review_base(
  uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create function public.replay_dead_letter(
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
  snapshot_record private.dead_letters%rowtype;
  locked_letter private.dead_letters%rowtype;
  inbox_record private.webhook_inbox%rowtype;
  replay_result jsonb;
begin
  select letter.*
  into strict snapshot_record
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id;

  if snapshot_record.operation_id is null
    or not private.has_membership_permission(
      snapshot_record.operation_id,
      'manage_conversations'
    )
  then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;

  if snapshot_record.source_queue = 'inbound_whatsapp' then
    select inbox.*
    into inbox_record
    from private.webhook_inbox as inbox
    where inbox.id = snapshot_record.envelope_id
    for update;
  elsif snapshot_record.source_queue in (
    'outbound_whatsapp',
    'reconciliation'
  ) then
    perform event.id
    from private.outbox_events as event
    where event.id = snapshot_record.envelope_id
    for update;
  elsif snapshot_record.source_queue = 'scheduled_actions' then
    perform job.id
    from public.scheduled_jobs as job
    where job.id = snapshot_record.envelope_id
    for update;
  end if;

  select letter.*
  into strict locked_letter
  from private.dead_letters as letter
  where letter.id = target_dead_letter_id
  for update;

  if locked_letter.source_queue <> snapshot_record.source_queue
    or locked_letter.envelope_id <> snapshot_record.envelope_id
    or locked_letter.organization_id
      is distinct from snapshot_record.organization_id
    or locked_letter.operation_id
      is distinct from snapshot_record.operation_id
  then
    raise exception 'dead-letter changed during replay preflight'
      using errcode = '40001';
  end if;

  if locked_letter.source_queue = 'inbound_whatsapp'
    and inbox_record.id is not null
    and exists (
      select 1
      from private.webhook_inbox as later
      where later.organization_id = inbox_record.organization_id
        and later.operation_id = inbox_record.operation_id
        and later.stream_key = inbox_record.stream_key
        and later.stream_sequence > inbox_record.stream_sequence
        and later.status in ('processed', 'unsupported')
    )
  then
    update private.dead_letters
    set status = 'resolved', resolved_at = now()
    where id = locked_letter.id;

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
      locked_letter.organization_id,
      locked_letter.operation_id,
      auth.uid(),
      'dead_letter.replay_stale_rejected',
      'dead_letter',
      locked_letter.id,
      jsonb_build_object(
        'status', locked_letter.status,
        'stream_sequence', inbox_record.stream_sequence
      ),
      jsonb_build_object(
        'status', 'resolved',
        'reason', 'later_inbound_already_applied',
        'effect_key_preserved', true
      ),
      request_trace_id,
      request_correlation_id
    );

    return jsonb_build_object(
      'status', 'rejected_stale',
      'reason', 'later_inbound_already_applied',
      'dead_letter_id', locked_letter.id
    );
  end if;

  replay_result := public.replay_dead_letter_t06_review_base(
    target_dead_letter_id,
    request_trace_id,
    request_correlation_id
  );

  if locked_letter.source_queue in (
    'outbound_whatsapp',
    'reconciliation'
  )
    and replay_result ->> 'status' = 'replayed'
  then
    -- Queue publication is not a failed provider attempt.
    update private.outbox_events
    set attempts = 0
    where id = locked_letter.envelope_id
      and status = 'published';
  end if;

  return replay_result;
end;
$$;

revoke all on function public.replay_dead_letter(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.replay_dead_letter(uuid, uuid, uuid)
  to authenticated;

create or replace function public.get_durable_processing_alerts(
  target_operation_id uuid,
  maximum_alerts integer default 100
)
returns table (
  alert_id uuid,
  dead_letter_id uuid,
  scheduled_job_id uuid,
  source_queue text,
  severity text,
  status text,
  failure_class text,
  failure_code text,
  effect_key_hash text,
  trace_id uuid,
  correlation_id uuid,
  created_at timestamptz,
  resolved_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller_is_service boolean := private.is_service_role();
begin
  if maximum_alerts not between 1 and 500 then
    raise exception 'invalid alert result bound' using errcode = '22023';
  end if;
  if not caller_is_service
    and not private.has_membership_permission(
      target_operation_id,
      'manage_conversations'
    )
  then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;

  return query
  select
    alert.id,
    alert.dead_letter_id,
    alert.scheduled_job_id,
    alert.source_queue,
    alert.severity,
    alert.status,
    alert.failure_class,
    alert.failure_code,
    alert.effect_key_hash,
    alert.trace_id,
    alert.correlation_id,
    alert.created_at,
    alert.resolved_at
  from private.durable_processing_alerts as alert
  where alert.operation_id = target_operation_id
    or (caller_is_service and alert.operation_id is null)
  order by
    case when alert.status = 'open' then 0 else 1 end,
    alert.created_at desc,
    alert.id
  limit maximum_alerts;
end;
$$;

revoke all on function public.get_durable_processing_alerts(uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.get_durable_processing_alerts(uuid, integer)
  to authenticated, service_role;

-- One invocation performs O(batch) queue work. It never nests a full outbound
-- batch inside a batch-sized loop while holding row and PGMQ locks.
create or replace function private.run_durable_workers(
  maximum_messages integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  inbound_result jsonb;
  scheduled_result jsonb;
  outbound_result jsonb;
  dispatched_count integer;
  reconciled_count integer;
  dead_signal_count integer;
begin
  if maximum_messages not between 1 and 100 then
    raise exception 'invalid worker bound' using errcode = '22023';
  end if;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );

  inbound_result := private.consume_inbound_whatsapp(
    maximum_messages,
    gen_random_uuid(),
    30
  );
  scheduled_result := private.consume_scheduled_actions(
    maximum_messages,
    gen_random_uuid(),
    30
  );
  dispatched_count := private.dispatch_outbox_events(maximum_messages);
  outbound_result := private.consume_outbound_whatsapp(
    maximum_messages,
    gen_random_uuid(),
    30
  );
  reconciled_count := private.consume_reconciliation(maximum_messages);
  dead_signal_count :=
    private.consume_dead_letter_signals(maximum_messages);

  return jsonb_build_object(
    'inbound', inbound_result,
    'scheduled', scheduled_result,
    'outbound', outbound_result,
    'outbox_dispatched', dispatched_count,
    'reconciled', reconciled_count,
    'dead_letter_signals', dead_signal_count
  );
end;
$$;

revoke all on function private.run_durable_workers(integer)
  from public, anon, authenticated, service_role;

select cron.schedule(
  't06-durable-sensitive-retention-hourly',
  '41 * * * *',
  $cron$select private.prune_durable_sensitive_material(5000);$cron$
);

create or replace function private.prune_cron_job_run_details(
  retention_window interval default interval '7 days',
  maximum_rows integer default 25000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted_rows integer;
begin
  if retention_window < interval '1 day'
    or retention_window > interval '90 days'
    or maximum_rows not between 1 and 100000
  then
    raise exception 'invalid cron retention bounds'
      using errcode = '22023';
  end if;

  with doomed as (
    select run.runid
    from cron.job as job
    join cron.job_run_details as run on run.jobid = job.jobid
    where job.jobname like 't06-%'
      and run.status <> 'running'
      and coalesce(run.end_time, run.start_time)
        < now() - retention_window
    order by coalesce(run.end_time, run.start_time), run.runid
    for update of run skip locked
    limit maximum_rows
  )
  delete from cron.job_run_details as run
  using doomed
  where run.runid = doomed.runid;

  get diagnostics deleted_rows = row_count;
  return deleted_rows;
end;
$$;

revoke all on function private.prune_cron_job_run_details(interval, integer)
  from public, anon, authenticated, service_role;

create or replace function public.get_cron_runtime_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result_value jsonb;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'observed_at', now(),
    'retention_days', 7,
    'retained_runs', (
      select count(*)
      from cron.job as retained_job
      join cron.job_run_details as retained_run
        on retained_run.jobid = retained_job.jobid
      where retained_job.jobname like 't06-%'
    ),
    'oldest_retained_start_at', (
      select min(retained_run.start_time)
      from cron.job as retained_job
      join cron.job_run_details as retained_run
        on retained_run.jobid = retained_job.jobid
      where retained_job.jobname like 't06-%'
    ),
    'failed_last_24h', (
      select count(*)
      from cron.job as failed_job
      join cron.job_run_details as failed_run
        on failed_run.jobid = failed_job.jobid
      where failed_job.jobname like 't06-%'
        and failed_run.status = 'failed'
        and failed_run.start_time >= now() - interval '24 hours'
    ),
    'running_over_10m', (
      select count(*)
      from cron.job as running_job
      join cron.job_run_details as running_run
        on running_run.jobid = running_job.jobid
      where running_job.jobname like 't06-%'
        and running_run.status = 'running'
        and running_run.start_time < now() - interval '10 minutes'
    ),
    'jobs', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'job_name', job.jobname,
            'active', job.active,
            'last_status', latest.status,
            'last_started_at', latest.start_time,
            'last_finished_at', latest.end_time
          )
          order by job.jobname
        ),
        '[]'::jsonb
      )
      from cron.job as job
      left join lateral (
        select detail.status, detail.start_time, detail.end_time
        from cron.job_run_details as detail
        where detail.jobid = job.jobid
        order by detail.start_time desc, detail.runid desc
        limit 1
      ) as latest on true
      where job.jobname like 't06-%'
    )
  )
  into result_value;

  return result_value;
end;
$$;

revoke all on function public.get_cron_runtime_health()
  from public, anon, authenticated, service_role;
grant execute on function public.get_cron_runtime_health()
  to service_role;
