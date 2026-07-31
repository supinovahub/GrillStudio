-- T06: execute durable scheduled actions without attaching a business effect.
--
-- The generic marker below is intentionally the only effect owned by T06.
-- Later tickets may consume a job_type, but must keep the same effect_key and
-- ordering fence rather than reimplementing delivery semantics.

create table private.scheduled_job_sequences (
  organization_id uuid not null,
  operation_id uuid not null,
  aggregate_type text not null,
  aggregate_id uuid not null,
  next_sequence bigint not null default 1 check (next_sequence > 0),
  updated_at timestamptz not null default now(),
  primary key (
    organization_id,
    operation_id,
    aggregate_type,
    aggregate_id
  ),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

alter table public.scheduled_jobs
  add column effect_key text,
  add column aggregate_sequence bigint,
  add column contention_count integer not null default 0
    check (contention_count >= 0);

-- A scheduled job is a command envelope consumed by the dedicated scheduler
-- worker. Publishing that envelope directly to inbound/outbound/reconciliation
-- would violate those queues' contracts and could poison an unrelated worker.
alter table public.scheduled_jobs
  drop constraint scheduled_jobs_target_queue_check,
  add constraint scheduled_jobs_target_queue_check
    check (target_queue = 'scheduled_actions');

update public.scheduled_jobs
set effect_key = 'scheduled:' || encode(
  sha256(convert_to(dedupe_key, 'UTF8')),
  'hex'
);

with ranked_jobs as (
  select
    id,
    row_number() over (
      partition by
        organization_id,
        operation_id,
        aggregate_type,
        aggregate_id
      order by created_at, id
    )::bigint as aggregate_sequence
  from public.scheduled_jobs
)
update public.scheduled_jobs as job
set aggregate_sequence = ranked.aggregate_sequence
from ranked_jobs as ranked
where ranked.id = job.id;

insert into private.scheduled_job_sequences (
  organization_id,
  operation_id,
  aggregate_type,
  aggregate_id,
  next_sequence
)
select
  organization_id,
  operation_id,
  aggregate_type,
  aggregate_id,
  max(aggregate_sequence) + 1
from public.scheduled_jobs
group by
  organization_id,
  operation_id,
  aggregate_type,
  aggregate_id;

alter table public.scheduled_jobs
  alter column effect_key set not null,
  alter column aggregate_sequence set not null,
  add constraint scheduled_jobs_effect_key_check
    check (
      effect_key = 'scheduled:' || encode(
        sha256(convert_to(dedupe_key, 'UTF8')),
        'hex'
      )
    ),
  add constraint scheduled_jobs_aggregate_sequence_check
    check (aggregate_sequence > 0),
  add constraint scheduled_jobs_aggregate_sequence_key
    unique (
      organization_id,
      operation_id,
      aggregate_type,
      aggregate_id,
      aggregate_sequence
    );

create index scheduled_jobs_effect_key_idx
  on public.scheduled_jobs (organization_id, operation_id, effect_key);

comment on column public.scheduled_jobs.attempts is
  'Durable execution failures only. Dispatch, PGMQ read_ct and contention do not consume this budget.';
comment on column public.scheduled_jobs.contention_count is
  'Predecessor or lease waits. Informational only and never a dead-letter budget.';

create or replace function private.prepare_scheduled_job_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  canonical_effect_key text;
begin
  canonical_effect_key := 'scheduled:' || encode(
    sha256(convert_to(new.dedupe_key, 'UTF8')),
    'hex'
  );

  if new.effect_key is not null
    and new.effect_key <> canonical_effect_key
  then
    raise exception 'scheduled effect key does not match dedupe key'
      using errcode = '23514';
  end if;
  new.effect_key := canonical_effect_key;

  if new.aggregate_sequence is null then
    insert into private.scheduled_job_sequences (
      organization_id,
      operation_id,
      aggregate_type,
      aggregate_id,
      next_sequence
    )
    values (
      new.organization_id,
      new.operation_id,
      new.aggregate_type,
      new.aggregate_id,
      2
    )
    on conflict (
      organization_id,
      operation_id,
      aggregate_type,
      aggregate_id
    )
    do update
    set
      next_sequence = private.scheduled_job_sequences.next_sequence + 1,
      updated_at = now()
    returning next_sequence - 1 into new.aggregate_sequence;
  else
    insert into private.scheduled_job_sequences (
      organization_id,
      operation_id,
      aggregate_type,
      aggregate_id,
      next_sequence
    )
    values (
      new.organization_id,
      new.operation_id,
      new.aggregate_type,
      new.aggregate_id,
      new.aggregate_sequence + 1
    )
    on conflict (
      organization_id,
      operation_id,
      aggregate_type,
      aggregate_id
    )
    do update
    set
      next_sequence = greatest(
        private.scheduled_job_sequences.next_sequence,
        excluded.next_sequence
      ),
      updated_at = now();
  end if;

  return new;
end;
$$;

revoke all on function private.prepare_scheduled_job_identity()
  from public, anon, authenticated, service_role;

create trigger scheduled_jobs_prepare_identity
before insert on public.scheduled_jobs
for each row execute function private.prepare_scheduled_job_identity();

create table private.scheduled_job_executions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  scheduled_job_id uuid not null,
  effect_key text not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  aggregate_type text not null,
  aggregate_id uuid not null,
  aggregate_version bigint,
  aggregate_sequence bigint not null check (aggregate_sequence > 0),
  trace_id uuid not null,
  correlation_id uuid not null,
  executed_at timestamptz not null default now(),
  unique (organization_id, operation_id, effect_key),
  unique (scheduled_job_id),
  foreign key (organization_id, operation_id, scheduled_job_id)
    references public.scheduled_jobs(organization_id, operation_id, id)
    on delete cascade,
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

create table private.scheduled_aggregate_watermarks (
  organization_id uuid not null,
  operation_id uuid not null,
  aggregate_type text not null,
  aggregate_id uuid not null,
  last_completed_sequence bigint not null default 0
    check (last_completed_sequence >= 0),
  last_aggregate_version bigint,
  last_scheduled_job_id uuid,
  last_effect_key text,
  updated_at timestamptz not null default now(),
  primary key (
    organization_id,
    operation_id,
    aggregate_type,
    aggregate_id
  ),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

create index scheduled_job_executions_aggregate_idx
  on private.scheduled_job_executions (
    organization_id,
    operation_id,
    aggregate_type,
    aggregate_id,
    aggregate_sequence
  );

revoke all on table private.scheduled_job_sequences
  from public, anon, authenticated;
revoke all on table private.scheduled_job_executions
  from public, anon, authenticated;
revoke all on table private.scheduled_aggregate_watermarks
  from public, anon, authenticated;
grant all on table private.scheduled_job_sequences to service_role;
grant all on table private.scheduled_job_executions to service_role;
grant all on table private.scheduled_aggregate_watermarks to service_role;

create or replace function private.dispatch_due_scheduled_jobs(
  maximum_jobs integer default 100
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_record public.scheduled_jobs%rowtype;
  queue_id bigint;
  dispatched integer := 0;
begin
  if maximum_jobs not between 1 and 500 then
    raise exception 'invalid scheduled dispatcher bound'
      using errcode = '22023';
  end if;

  for job_record in
    select job.*
    from public.scheduled_jobs as job
    where job.status = 'pending'
      and job.run_at <= now()
    order by job.run_at, job.id
    for update skip locked
    limit maximum_jobs
  loop
    update public.scheduled_jobs
    set
      status = 'leased',
      lease_token = gen_random_uuid(),
      lease_until = now() + interval '30 seconds',
      updated_at = now()
    where id = job_record.id
    returning * into strict job_record;

    select sent.msg_id into strict queue_id
    from pgmq.send(
      queue_name => job_record.target_queue,
      msg => jsonb_build_object(
        'scheduled_job_id', job_record.id,
        'organization_id', job_record.organization_id,
        'operation_id', job_record.operation_id,
        'aggregate_type', job_record.aggregate_type,
        'aggregate_id', job_record.aggregate_id,
        'aggregate_version', job_record.aggregate_version,
        'aggregate_sequence', job_record.aggregate_sequence,
        'effect_key', job_record.effect_key,
        'trace_id', job_record.trace_id,
        'correlation_id', job_record.correlation_id
      )
    ) as sent(msg_id);

    update public.scheduled_jobs
    set
      status = 'published',
      lease_token = null,
      lease_until = null,
      queue_message_id = queue_id,
      published_at = now(),
      updated_at = now()
    where id = job_record.id;
    dispatched := dispatched + 1;
  end loop;

  return dispatched;
end;
$$;

revoke all on function private.dispatch_due_scheduled_jobs(integer)
  from public, anon, authenticated, service_role;

-- These local classifiers exist before the shared worker helpers introduced
-- by the next review migration. This prevents the already-enabled recovery
-- Cron from observing an unresolved function between migrations.
create or replace function private.classify_scheduled_failure(
  error_sqlstate text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when error_sqlstate in ('40001', '40P01', '55P03', '57014')
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

create or replace function private.scheduled_retry_delay_seconds(
  failure_attempt integer,
  maximum_delay integer default 900
)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  base_delay integer;
  jitter_ceiling integer;
begin
  base_delay := least(
    greatest(maximum_delay, 2),
    greatest(
      2,
      power(2, least(greatest(failure_attempt, 1), 8))::integer
    )
  );
  jitter_ceiling := greatest(1, ceil(base_delay * 0.25)::integer);
  return least(
    greatest(maximum_delay, 2),
    base_delay + floor(random() * (jitter_ceiling + 1))::integer
  );
end;
$$;

create or replace function private.scheduled_contention_delay_seconds(
  contention_attempt integer
)
returns integer
language sql
volatile
security invoker
set search_path = ''
as $$
  select least(
    15,
    2 + least(greatest(contention_attempt, 1), 8)
      + floor(random() * 4)::integer
  );
$$;

revoke all on function private.classify_scheduled_failure(text)
  from public, anon, authenticated, service_role;
revoke all on function private.scheduled_retry_delay_seconds(integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function private.scheduled_contention_delay_seconds(integer)
  from public, anon, authenticated, service_role;

create or replace function private.consume_scheduled_actions(
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
  queue_record pgmq.message_record;
  job_record public.scheduled_jobs%rowtype;
  effect_record private.effect_ledger%rowtype;
  watermark_record private.scheduled_aggregate_watermarks%rowtype;
  job_id_value uuid;
  request_hash_value text;
  safe_envelope jsonb;
  processed_count integer := 0;
  deferred_count integer := 0;
  dead_count integer := 0;
  reconciled_count integer := 0;
  stale_count integer := 0;
  error_state text;
  failure_class text;
  next_failure_attempt integer;
  contention_attempt integer;
begin
  if maximum_messages not between 1 and 100
    or visibility_seconds not between 5 and 3600
  then
    raise exception 'invalid scheduled worker bounds'
      using errcode = '22023';
  end if;

  for message_index in 1..maximum_messages loop
    queue_record := null;
    job_record := null;
    job_id_value := null;
    request_hash_value := null;
    failure_class := null;
    next_failure_attempt := null;
    contention_attempt := null;

    select claimed.* into queue_record
    from pgmq.read(
      queue_name => 'scheduled_actions',
      vt => visibility_seconds,
      qty => 1,
      conditional => '{}'::jsonb
    ) as claimed
    limit 1;
    exit when queue_record.msg_id is null;

    begin
      begin
        job_id_value := (queue_record.message ->> 'scheduled_job_id')::uuid;
      exception when invalid_text_representation then
        job_id_value := null;
      end;

      if job_id_value is null then
        perform private.dead_letter_queue_message(
          'scheduled_actions',
          queue_record.msg_id,
          gen_random_uuid(),
          'invalid-scheduled-envelope:' || queue_record.msg_id::text,
          jsonb_build_object('queue_message_id', queue_record.msg_id),
          1,
          'non_retryable',
          'invalid_envelope',
          null,
          null,
          gen_random_uuid(),
          gen_random_uuid()
        );
        dead_count := dead_count + 1;
        continue;
      end if;

      select job.*
      into job_record
      from public.scheduled_jobs as job
      where job.id = job_id_value
      for update;

      if job_record.id is null then
        perform private.dead_letter_queue_message(
          'scheduled_actions',
          queue_record.msg_id,
          job_id_value,
          'missing-scheduled-job:' || job_id_value::text,
          jsonb_build_object('scheduled_job_id', job_id_value),
          1,
          'non_retryable',
          'artifact_missing',
          null,
          null,
          gen_random_uuid(),
          gen_random_uuid()
        );
        dead_count := dead_count + 1;
        continue;
      end if;

      safe_envelope := jsonb_build_object(
        'scheduled_job_id', job_record.id,
        'organization_id', job_record.organization_id,
        'operation_id', job_record.operation_id,
        'aggregate_type', job_record.aggregate_type,
        'aggregate_id', job_record.aggregate_id,
        'aggregate_version', job_record.aggregate_version,
        'aggregate_sequence', job_record.aggregate_sequence,
        'effect_key', job_record.effect_key,
        'trace_id', job_record.trace_id,
        'correlation_id', job_record.correlation_id
      );

      insert into private.processing_attempts (
        organization_id,
        operation_id,
        queue_name,
        queue_message_id,
        envelope_id,
        aggregate_type,
        aggregate_id,
        aggregate_sequence,
        worker_id,
        attempt,
        state,
        trace_id,
        correlation_id
      )
      values (
        job_record.organization_id,
        job_record.operation_id,
        'scheduled_actions',
        queue_record.msg_id,
        job_record.id,
        job_record.aggregate_type,
        job_record.aggregate_id,
        job_record.aggregate_sequence,
        target_worker_id,
        greatest(job_record.attempts + 1, 1),
        'claimed',
        job_record.trace_id,
        job_record.correlation_id
      );

      if job_record.target_queue <> 'scheduled_actions'
        or queue_record.message ->> 'effect_key' is distinct from job_record.effect_key
        or queue_record.message ->> 'aggregate_sequence'
          is distinct from job_record.aggregate_sequence::text
      then
        next_failure_attempt := job_record.attempts + 1;
        perform private.dead_letter_queue_message(
          'scheduled_actions',
          queue_record.msg_id,
          job_record.id,
          job_record.effect_key,
          safe_envelope,
          next_failure_attempt,
          'non_retryable',
          'envelope_conflict',
          job_record.organization_id,
          job_record.operation_id,
          job_record.trace_id,
          job_record.correlation_id
        );
        update public.scheduled_jobs
        set
          status = 'dead',
          lease_token = null,
          lease_until = null,
          attempts = next_failure_attempt,
          last_error_class = 'non_retryable',
          last_error_code = 'envelope_conflict',
          updated_at = now()
        where id = job_record.id;
        dead_count := dead_count + 1;
        continue;
      end if;

      if job_record.status = 'completed' then
        perform pgmq.archive('scheduled_actions', queue_record.msg_id);
        reconciled_count := reconciled_count + 1;
        continue;
      end if;

      if job_record.status in ('cancelled', 'dead') then
        perform pgmq.archive('scheduled_actions', queue_record.msg_id);
        reconciled_count := reconciled_count + 1;
        continue;
      end if;

      if job_record.status <> 'published'
        or job_record.queue_message_id <> queue_record.msg_id
      then
        if job_record.status = 'leased' then
          update public.scheduled_jobs
          set
            contention_count = contention_count + 1,
            updated_at = now()
          where id = job_record.id
          returning contention_count into strict contention_attempt;
          perform private.defer_queue_message(
            'scheduled_actions',
            queue_record.msg_id,
            private.scheduled_contention_delay_seconds(contention_attempt)
          );
          deferred_count := deferred_count + 1;
        else
          perform pgmq.archive('scheduled_actions', queue_record.msg_id);
          reconciled_count := reconciled_count + 1;
        end if;
        continue;
      end if;

      if exists (
        select 1
        from public.scheduled_jobs as earlier
        where earlier.organization_id = job_record.organization_id
          and earlier.operation_id = job_record.operation_id
          and earlier.aggregate_type = job_record.aggregate_type
          and earlier.aggregate_id = job_record.aggregate_id
          and earlier.aggregate_sequence < job_record.aggregate_sequence
          and earlier.status in ('pending', 'leased', 'published')
      ) then
        update public.scheduled_jobs
        set
          contention_count = contention_count + 1,
          updated_at = now()
        where id = job_record.id
        returning contention_count into strict contention_attempt;
        perform private.defer_queue_message(
          'scheduled_actions',
          queue_record.msg_id,
          private.scheduled_contention_delay_seconds(contention_attempt)
        );
        insert into private.processing_attempts (
          organization_id,
          operation_id,
          queue_name,
          queue_message_id,
          envelope_id,
          aggregate_type,
          aggregate_id,
          aggregate_sequence,
          worker_id,
          attempt,
          state,
          error_class,
          error_code,
          trace_id,
          correlation_id
        )
        values (
          job_record.organization_id,
          job_record.operation_id,
          'scheduled_actions',
          queue_record.msg_id,
          job_record.id,
          job_record.aggregate_type,
          job_record.aggregate_id,
          job_record.aggregate_sequence,
          target_worker_id,
          contention_attempt,
          'deferred',
          'contention',
          'earlier_effect_pending',
          job_record.trace_id,
          job_record.correlation_id
        );
        deferred_count := deferred_count + 1;
        continue;
      end if;

      insert into private.scheduled_aggregate_watermarks (
        organization_id,
        operation_id,
        aggregate_type,
        aggregate_id
      )
      values (
        job_record.organization_id,
        job_record.operation_id,
        job_record.aggregate_type,
        job_record.aggregate_id
      )
      on conflict do nothing;

      select watermark.*
      into strict watermark_record
      from private.scheduled_aggregate_watermarks as watermark
      where watermark.organization_id = job_record.organization_id
        and watermark.operation_id = job_record.operation_id
        and watermark.aggregate_type = job_record.aggregate_type
        and watermark.aggregate_id = job_record.aggregate_id
      for update;

      request_hash_value := encode(
        sha256(
          convert_to(
            jsonb_build_object(
              'dedupe_key', job_record.dedupe_key,
              'job_type', job_record.job_type,
              'aggregate_type', job_record.aggregate_type,
              'aggregate_id', job_record.aggregate_id,
              'aggregate_version', job_record.aggregate_version,
              'payload', job_record.payload
            )::text,
            'UTF8'
          )
        ),
        'hex'
      );

      insert into private.effect_ledger (
        organization_id,
        operation_id,
        effect_key,
        effect_type,
        request_hash,
        state,
        trace_id,
        correlation_id
      )
      values (
        job_record.organization_id,
        job_record.operation_id,
        job_record.effect_key,
        'scheduled_job.executed.v1',
        request_hash_value,
        'prepared',
        job_record.trace_id,
        job_record.correlation_id
      )
      on conflict (organization_id, operation_id, effect_key)
      do nothing;

      select effect.*
      into strict effect_record
      from private.effect_ledger as effect
      where effect.organization_id = job_record.organization_id
        and effect.operation_id = job_record.operation_id
        and effect.effect_key = job_record.effect_key
      for update;

      if effect_record.request_hash <> request_hash_value
        or effect_record.effect_type <> 'scheduled_job.executed.v1'
      then
        raise exception 'scheduled effect replay conflict'
          using errcode = '23505';
      end if;

      if effect_record.state = 'effect_recorded' then
        update public.scheduled_jobs
        set
          status = 'completed',
          completed_at = coalesce(completed_at, now()),
          last_error_class = null,
          last_error_code = null,
          updated_at = now()
        where id = job_record.id;
        perform pgmq.archive('scheduled_actions', queue_record.msg_id);
        reconciled_count := reconciled_count + 1;
        continue;
      end if;

      if effect_record.state = 'outcome_unknown' then
        raise exception 'scheduled effect outcome requires reconciliation'
          using errcode = 'P0001';
      end if;

      if effect_record.state = 'suppressed'
        or watermark_record.last_completed_sequence
          > job_record.aggregate_sequence
        or (
          job_record.aggregate_version is not null
          and watermark_record.last_aggregate_version is not null
          and watermark_record.last_aggregate_version
            > job_record.aggregate_version
        )
      then
        update private.effect_ledger
        set
          state = 'suppressed',
          updated_at = now()
        where id = effect_record.id
          and state <> 'effect_recorded';
        update public.scheduled_jobs
        set
          status = 'cancelled',
          lease_token = null,
          lease_until = null,
          last_error_class = 'conflict',
          last_error_code = 'stale_aggregate_order',
          updated_at = now()
        where id = job_record.id;
        perform pgmq.archive('scheduled_actions', queue_record.msg_id);
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
          job_record.organization_id,
          job_record.operation_id,
          null,
          'scheduled_job.stale_suppressed',
          'scheduled_job',
          job_record.id,
          jsonb_build_object(
            'aggregate_sequence', job_record.aggregate_sequence,
            'aggregate_version', job_record.aggregate_version
          ),
          jsonb_build_object(
            'status', 'cancelled',
            'last_completed_sequence',
              watermark_record.last_completed_sequence,
            'effect_key_hash', encode(
              sha256(convert_to(job_record.effect_key, 'UTF8')),
              'hex'
            )
          ),
          job_record.trace_id,
          job_record.correlation_id
        );
        stale_count := stale_count + 1;
        continue;
      end if;

      update private.effect_ledger
      set
        state = 'request_started',
        started_at = coalesce(started_at, now()),
        updated_at = now()
      where id = effect_record.id;

      insert into private.scheduled_job_executions (
        organization_id,
        operation_id,
        scheduled_job_id,
        effect_key,
        request_hash,
        aggregate_type,
        aggregate_id,
        aggregate_version,
        aggregate_sequence,
        trace_id,
        correlation_id
      )
      values (
        job_record.organization_id,
        job_record.operation_id,
        job_record.id,
        job_record.effect_key,
        request_hash_value,
        job_record.aggregate_type,
        job_record.aggregate_id,
        job_record.aggregate_version,
        job_record.aggregate_sequence,
        job_record.trace_id,
        job_record.correlation_id
      )
      on conflict (organization_id, operation_id, effect_key)
      do nothing;

      if not exists (
        select 1
        from private.scheduled_job_executions as execution
        where execution.organization_id = job_record.organization_id
          and execution.operation_id = job_record.operation_id
          and execution.effect_key = job_record.effect_key
          and execution.request_hash = request_hash_value
      ) then
        raise exception 'scheduled execution marker conflict'
          using errcode = '23505';
      end if;

      update private.scheduled_aggregate_watermarks
      set
        last_completed_sequence = greatest(
          last_completed_sequence,
          job_record.aggregate_sequence
        ),
        last_aggregate_version = case
          when job_record.aggregate_version is null
            then last_aggregate_version
          when last_aggregate_version is null
            then job_record.aggregate_version
          else greatest(last_aggregate_version, job_record.aggregate_version)
        end,
        last_scheduled_job_id = job_record.id,
        last_effect_key = job_record.effect_key,
        updated_at = now()
      where organization_id = job_record.organization_id
        and operation_id = job_record.operation_id
        and aggregate_type = job_record.aggregate_type
        and aggregate_id = job_record.aggregate_id;

      update private.effect_ledger
      set
        state = 'effect_recorded',
        response_hash = encode(
          sha256(convert_to(job_record.id::text, 'UTF8')),
          'hex'
        ),
        recorded_at = now(),
        updated_at = now()
      where id = effect_record.id;

      update public.scheduled_jobs
      set
        status = 'completed',
        completed_at = now(),
        last_error_class = null,
        last_error_code = null,
        updated_at = now()
      where id = job_record.id;

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
        job_record.organization_id,
        job_record.operation_id,
        null,
        'scheduled_job.execution_recorded',
        'scheduled_job',
        job_record.id,
        jsonb_build_object('status', 'published'),
        jsonb_build_object(
          'status', 'completed',
          'aggregate_sequence', job_record.aggregate_sequence,
          'aggregate_version', job_record.aggregate_version,
          'effect_key_hash', encode(
            sha256(convert_to(job_record.effect_key, 'UTF8')),
            'hex'
          ),
          'business_effect_applied', false
        ),
        job_record.trace_id,
        job_record.correlation_id
      );

      perform pgmq.archive('scheduled_actions', queue_record.msg_id);
      insert into private.processing_attempts (
        organization_id,
        operation_id,
        queue_name,
        queue_message_id,
        envelope_id,
        aggregate_type,
        aggregate_id,
        aggregate_sequence,
        worker_id,
        attempt,
        state,
        trace_id,
        correlation_id
      )
      values (
        job_record.organization_id,
        job_record.operation_id,
        'scheduled_actions',
        queue_record.msg_id,
        job_record.id,
        job_record.aggregate_type,
        job_record.aggregate_id,
        job_record.aggregate_sequence,
        target_worker_id,
        greatest(job_record.attempts + 1, 1),
        'succeeded',
        job_record.trace_id,
        job_record.correlation_id
      );
      processed_count := processed_count + 1;
    exception when others then
      get stacked diagnostics error_state = returned_sqlstate;
      failure_class := private.classify_scheduled_failure(error_state);

      if job_record.id is null and job_id_value is not null then
        select job.*
        into job_record
        from public.scheduled_jobs as job
        where job.id = job_id_value
        for update;
      end if;

      if job_record.id is null then
        perform private.defer_queue_message(
          'scheduled_actions',
          queue_record.msg_id,
          private.scheduled_retry_delay_seconds(1, 900)
        );
        deferred_count := deferred_count + 1;
        continue;
      end if;

      next_failure_attempt := job_record.attempts + 1;
      safe_envelope := coalesce(
        safe_envelope,
        jsonb_build_object(
          'scheduled_job_id', job_record.id,
          'organization_id', job_record.organization_id,
          'operation_id', job_record.operation_id,
          'aggregate_type', job_record.aggregate_type,
          'aggregate_id', job_record.aggregate_id,
          'aggregate_version', job_record.aggregate_version,
          'aggregate_sequence', job_record.aggregate_sequence,
          'effect_key', job_record.effect_key,
          'trace_id', job_record.trace_id,
          'correlation_id', job_record.correlation_id
        )
      );

      if failure_class = 'retryable'
        and next_failure_attempt < job_record.max_attempts
      then
        update public.scheduled_jobs
        set
          attempts = next_failure_attempt,
          last_error_class = failure_class,
          last_error_code = left(error_state, 120),
          updated_at = now()
        where id = job_record.id
          and status = 'published';
        perform private.defer_queue_message(
          'scheduled_actions',
          queue_record.msg_id,
          private.scheduled_retry_delay_seconds(
            next_failure_attempt,
            900
          )
        );
        insert into private.processing_attempts (
          organization_id,
          operation_id,
          queue_name,
          queue_message_id,
          envelope_id,
          aggregate_type,
          aggregate_id,
          aggregate_sequence,
          worker_id,
          attempt,
          state,
          error_class,
          error_code,
          trace_id,
          correlation_id
        )
        values (
          job_record.organization_id,
          job_record.operation_id,
          'scheduled_actions',
          queue_record.msg_id,
          job_record.id,
          job_record.aggregate_type,
          job_record.aggregate_id,
          job_record.aggregate_sequence,
          target_worker_id,
          next_failure_attempt,
          'retryable_failed',
          failure_class,
          left(error_state, 120),
          job_record.trace_id,
          job_record.correlation_id
        );
        deferred_count := deferred_count + 1;
      else
        if failure_class = 'unknown' then
          if request_hash_value is null then
            request_hash_value := encode(
              sha256(
                convert_to(
                  jsonb_build_object(
                    'dedupe_key', job_record.dedupe_key,
                    'job_type', job_record.job_type,
                    'aggregate_type', job_record.aggregate_type,
                    'aggregate_id', job_record.aggregate_id,
                    'aggregate_version', job_record.aggregate_version,
                    'payload', job_record.payload
                  )::text,
                  'UTF8'
                )
              ),
              'hex'
            );
          end if;

          insert into private.effect_ledger (
            organization_id,
            operation_id,
            effect_key,
            effect_type,
            request_hash,
            state,
            trace_id,
            correlation_id,
            started_at
          )
          values (
            job_record.organization_id,
            job_record.operation_id,
            job_record.effect_key,
            'scheduled_job.executed.v1',
            request_hash_value,
            'outcome_unknown',
            job_record.trace_id,
            job_record.correlation_id,
            now()
          )
          on conflict (organization_id, operation_id, effect_key)
          do update set
            state = case
              when private.effect_ledger.state = 'effect_recorded'
                then 'effect_recorded'
              else 'outcome_unknown'
            end,
            started_at = coalesce(
              private.effect_ledger.started_at,
              now()
            ),
            updated_at = now();
        end if;

        perform private.dead_letter_queue_message(
          'scheduled_actions',
          queue_record.msg_id,
          job_record.id,
          job_record.effect_key,
          safe_envelope,
          next_failure_attempt,
          failure_class,
          left(error_state, 120),
          job_record.organization_id,
          job_record.operation_id,
          job_record.trace_id,
          job_record.correlation_id
        );
        update public.scheduled_jobs
        set
          status = 'dead',
          lease_token = null,
          lease_until = null,
          attempts = next_failure_attempt,
          last_error_class = failure_class,
          last_error_code = left(error_state, 120),
          updated_at = now()
        where id = job_record.id;
        insert into private.processing_attempts (
          organization_id,
          operation_id,
          queue_name,
          queue_message_id,
          envelope_id,
          aggregate_type,
          aggregate_id,
          aggregate_sequence,
          worker_id,
          attempt,
          state,
          error_class,
          error_code,
          trace_id,
          correlation_id
        )
        values (
          job_record.organization_id,
          job_record.operation_id,
          'scheduled_actions',
          queue_record.msg_id,
          job_record.id,
          job_record.aggregate_type,
          job_record.aggregate_id,
          job_record.aggregate_sequence,
          target_worker_id,
          next_failure_attempt,
          'dead_lettered',
          failure_class,
          left(error_state, 120),
          job_record.trace_id,
          job_record.correlation_id
        );
        dead_count := dead_count + 1;
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'processed', processed_count,
    'reconciled', reconciled_count,
    'stale_suppressed', stale_count,
    'deferred', deferred_count,
    'dead_lettered', dead_count,
    'worker_id', target_worker_id
  );
end;
$$;

revoke all on function private.consume_scheduled_actions(
  integer, uuid, integer
) from public, anon, authenticated, service_role;

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
  outbound_iteration jsonb;
  dispatched_iteration integer;
  reconciled_iteration integer;
  dispatched_total integer := 0;
  reconciled_total integer := 0;
  outbound_processed integer := 0;
  outbound_deferred integer := 0;
  outbound_dead integer := 0;
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

  for drain_iteration in 1..maximum_messages loop
    dispatched_iteration := private.dispatch_outbox_events(
      maximum_messages * 2
    );
    outbound_iteration := private.consume_outbound_whatsapp(
      maximum_messages,
      gen_random_uuid(),
      30
    );
    reconciled_iteration := private.consume_reconciliation(
      maximum_messages * 2
    );

    dispatched_total := dispatched_total + dispatched_iteration;
    reconciled_total := reconciled_total + reconciled_iteration;
    outbound_processed := outbound_processed
      + coalesce((outbound_iteration ->> 'processed')::integer, 0);
    outbound_deferred := outbound_deferred
      + coalesce((outbound_iteration ->> 'deferred')::integer, 0);
    outbound_dead := outbound_dead
      + coalesce((outbound_iteration ->> 'dead_lettered')::integer, 0);

    exit when dispatched_iteration = 0
      and reconciled_iteration = 0
      and coalesce((outbound_iteration ->> 'processed')::integer, 0) = 0
      and coalesce((outbound_iteration ->> 'deferred')::integer, 0) = 0
      and coalesce((outbound_iteration ->> 'dead_lettered')::integer, 0) = 0;
  end loop;

  return jsonb_build_object(
    'inbound', inbound_result,
    'scheduled', scheduled_result,
    'outbound', jsonb_build_object(
      'processed', outbound_processed,
      'deferred', outbound_deferred,
      'dead_lettered', outbound_dead
    ),
    'outbox_dispatched', dispatched_total,
    'reconciled', reconciled_total
  );
end;
$$;

revoke all on function private.run_durable_workers(integer)
  from public, anon, authenticated, service_role;
