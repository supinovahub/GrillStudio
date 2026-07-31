-- T06: durable processing primitives.
--
-- These objects are deliberately private or fail-closed. Queue envelopes and
-- observability rows contain identifiers and redacted metadata only; message
-- bodies remain in their canonical tables. T07/T13/T14/T21 own the business
-- consumers that will later use the same primitives.

create extension if not exists pgmq;
create extension if not exists pg_cron;

-- PGMQ queue names use underscores because they become SQL identifiers. The
-- public event catalog keeps the equivalent kebab-case names.
select pgmq.create('inbound_whatsapp');
select pgmq.create('outbound_whatsapp');
select pgmq.create('scheduled_actions');
select pgmq.create('reconciliation');
select pgmq.create('dead_letter');

revoke all on schema pgmq from public, anon, authenticated;
revoke all on all tables in schema pgmq from public, anon, authenticated;
revoke all on all sequences in schema pgmq from public, anon, authenticated;
revoke all on all functions in schema pgmq from public, anon, authenticated;
grant usage on schema pgmq to service_role;
grant all on all tables in schema pgmq to service_role;
grant all on all sequences in schema pgmq to service_role;
grant execute on all functions in schema pgmq to service_role;

create table private.webhook_inbox (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  connection_id uuid not null,
  provider text not null
    check (provider in ('simulator', 'uazapi', 'meta_cloud')),
  provider_event_id text not null
    check (char_length(provider_event_id) between 1 and 500),
  payload_hash text not null
    check (payload_hash ~ '^[0-9a-f]{64}$'),
  raw_payload jsonb not null
    check (jsonb_typeof(raw_payload) = 'object'),
  normalized_payload jsonb not null
    check (jsonb_typeof(normalized_payload) = 'object'),
  status text not null default 'accepted'
    check (
      status in (
        'accepted',
        'processing',
        'processed',
        'unsupported',
        'dead'
      )
    ),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 8 check (max_attempts between 1 and 100),
  last_error_class text
    check (
      last_error_class is null
      or char_length(last_error_class) between 1 and 120
    ),
  last_error_code text
    check (
      last_error_code is null
      or char_length(last_error_code) between 1 and 120
    ),
  trace_id uuid not null,
  correlation_id uuid not null,
  causation_id uuid,
  accepted_at timestamptz not null default now(),
  processing_started_at timestamptz,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (connection_id, provider_event_id),
  unique (organization_id, operation_id, connection_id, id),
  foreign key (organization_id, operation_id, connection_id)
    references public.whatsapp_connections(organization_id, operation_id, id)
    on delete cascade,
  check (
    (status in ('processed', 'unsupported') and processed_at is not null)
    or (status not in ('processed', 'unsupported'))
  )
);

comment on column private.webhook_inbox.raw_payload is
  'Sensitive provider payload. Private schema only; never copy into queue envelopes or logs.';
comment on column private.webhook_inbox.normalized_payload is
  'Sensitive normalized payload. Private schema only; workers load it by inbox id.';

create table private.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  scope text not null
    check (char_length(scope) between 1 and 160),
  idempotency_key text not null
    check (char_length(idempotency_key) between 1 and 500),
  request_hash text not null
    check (request_hash ~ '^[0-9a-f]{64}$'),
  state text not null default 'prepared'
    check (state in ('prepared', 'completed', 'failed', 'unknown')),
  response_reference jsonb
    check (
      response_reference is null
      or jsonb_typeof(response_reference) = 'object'
    ),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (organization_id, operation_id, scope, idempotency_key),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (expires_at is null or expires_at > created_at),
  check (
    (state = 'completed' and completed_at is not null)
    or (state <> 'completed')
  )
);

create table private.effect_ledger (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  effect_key text not null
    check (char_length(effect_key) between 1 and 500),
  effect_type text not null
    check (char_length(effect_type) between 1 and 160),
  request_hash text not null
    check (request_hash ~ '^[0-9a-f]{64}$'),
  state text not null default 'prepared'
    check (
      state in (
        'prepared',
        'request_started',
        'effect_recorded',
        'outcome_unknown',
        'suppressed'
      )
    ),
  provider_reference text
    check (
      provider_reference is null
      or char_length(provider_reference) between 1 and 500
    ),
  response_hash text
    check (
      response_hash is null
      or response_hash ~ '^[0-9a-f]{64}$'
    ),
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  recorded_at timestamptz,
  unique (organization_id, operation_id, effect_key),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    state not in ('request_started', 'outcome_unknown')
    or started_at is not null
  ),
  check (state <> 'effect_recorded' or recorded_at is not null)
);

create table private.aggregate_sequences (
  organization_id uuid not null,
  operation_id uuid not null,
  aggregate_type text not null
    check (char_length(aggregate_type) between 1 and 80),
  aggregate_id uuid not null,
  next_sequence bigint not null default 1 check (next_sequence > 0),
  updated_at timestamptz not null default now(),
  primary key (organization_id, operation_id, aggregate_type, aggregate_id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

create table private.outbox_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  event_type text not null
    check (char_length(event_type) between 1 and 200),
  aggregate_type text not null
    check (char_length(aggregate_type) between 1 and 80),
  aggregate_id uuid not null,
  aggregate_version bigint not null check (aggregate_version > 0),
  aggregate_sequence bigint not null check (aggregate_sequence > 0),
  actor_type text not null
    check (actor_type in ('provider', 'user', 'ai', 'system')),
  actor_reference text
    check (
      actor_reference is null
      or char_length(actor_reference) between 1 and 500
    ),
  target_queue text not null
    check (
      target_queue in (
        'inbound_whatsapp',
        'outbound_whatsapp',
        'scheduled_actions',
        'reconciliation'
      )
    ),
  idempotency_key text not null
    check (char_length(idempotency_key) between 1 and 500),
  payload_hash text not null
    check (payload_hash ~ '^[0-9a-f]{64}$'),
  payload jsonb not null
    check (jsonb_typeof(payload) = 'object'),
  status text not null default 'pending'
    check (
      status in (
        'pending',
        'published',
        'processing',
        'completed',
        'dead'
      )
    ),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 8 check (max_attempts between 1 and 100),
  queue_message_id bigint,
  trace_id uuid not null,
  correlation_id uuid not null,
  causation_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  completed_at timestamptz,
  last_error_class text
    check (
      last_error_class is null
      or char_length(last_error_class) between 1 and 120
    ),
  last_error_code text
    check (
      last_error_code is null
      or char_length(last_error_code) between 1 and 120
    ),
  unique (organization_id, operation_id, id),
  unique (organization_id, operation_id, idempotency_key),
  unique (
    organization_id,
    operation_id,
    aggregate_type,
    aggregate_id,
    aggregate_sequence
  ),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    (status in ('published', 'processing', 'completed') and published_at is not null)
    or (status in ('pending', 'dead'))
  ),
  check (
    (status = 'completed' and completed_at is not null)
    or (status <> 'completed')
  )
);

comment on column private.outbox_events.payload is
  'Minimal redacted envelope references only. Sensitive content stays canonical and is loaded by id.';

create table private.conversation_processing_leases (
  conversation_id uuid primary key,
  organization_id uuid not null,
  operation_id uuid not null,
  worker_id uuid not null,
  lease_token uuid not null unique,
  expected_version bigint not null check (expected_version > 0),
  aggregate_sequence bigint not null check (aggregate_sequence > 0),
  leased_at timestamptz not null default now(),
  lease_until timestamptz not null,
  heartbeat_at timestamptz not null default now(),
  foreign key (organization_id, operation_id, conversation_id)
    references public.conversations(organization_id, operation_id, id)
    on delete cascade,
  check (lease_until > leased_at),
  check (heartbeat_at >= leased_at)
);

create table private.processing_attempts (
  id bigint generated always as identity primary key,
  organization_id uuid,
  operation_id uuid,
  queue_name text not null
    check (
      queue_name in (
        'inbound_whatsapp',
        'outbound_whatsapp',
        'scheduled_actions',
        'reconciliation',
        'dead_letter'
      )
    ),
  queue_message_id bigint,
  envelope_id uuid,
  aggregate_type text,
  aggregate_id uuid,
  aggregate_sequence bigint,
  worker_id uuid,
  lease_token uuid,
  attempt integer not null check (attempt > 0),
  state text not null
    check (
      state in (
        'claimed',
        'deferred',
        'succeeded',
        'retryable_failed',
        'dead_lettered',
        'replayed',
        'acknowledged'
      )
    ),
  error_class text
    check (
      error_class is null
      or char_length(error_class) between 1 and 120
    ),
  error_code text
    check (
      error_code is null
      or char_length(error_code) between 1 and 120
    ),
  trace_id uuid not null,
  correlation_id uuid not null,
  observed_at timestamptz not null default now(),
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    (organization_id is null and operation_id is null)
    or (organization_id is not null and operation_id is not null)
  )
);

create table private.dead_letters (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid,
  operation_id uuid,
  source_queue text not null
    check (
      source_queue in (
        'inbound_whatsapp',
        'outbound_whatsapp',
        'scheduled_actions',
        'reconciliation'
      )
    ),
  source_message_id bigint not null,
  envelope_id uuid not null,
  effect_key text not null
    check (char_length(effect_key) between 1 and 500),
  redacted_envelope jsonb not null
    check (jsonb_typeof(redacted_envelope) = 'object'),
  attempts integer not null check (attempts > 0),
  failure_class text not null
    check (char_length(failure_class) between 1 and 120),
  failure_code text not null
    check (char_length(failure_code) between 1 and 120),
  status text not null default 'pending'
    check (status in ('pending', 'replayed', 'resolved')),
  trace_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  replayed_at timestamptz,
  replayed_by_user_id uuid references auth.users(id),
  replay_queue_message_id bigint,
  resolved_at timestamptz,
  unique (source_queue, source_message_id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    (organization_id is null and operation_id is null)
    or (organization_id is not null and operation_id is not null)
  ),
  check (
    (status = 'replayed' and replayed_at is not null)
    or (status <> 'replayed')
  ),
  check (
    (status = 'resolved' and resolved_at is not null)
    or (status <> 'resolved')
  )
);

comment on column private.dead_letters.redacted_envelope is
  'Identifiers and effect key only. Provider payloads and message bodies are forbidden.';

create table public.scheduled_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_id uuid not null,
  job_type text not null
    check (char_length(job_type) between 1 and 160),
  aggregate_type text not null
    check (char_length(aggregate_type) between 1 and 80),
  aggregate_id uuid not null,
  aggregate_version bigint check (
    aggregate_version is null
    or aggregate_version > 0
  ),
  target_queue text not null
    check (
      target_queue in (
        'inbound_whatsapp',
        'outbound_whatsapp',
        'scheduled_actions',
        'reconciliation'
      )
    ),
  run_at timestamptz not null,
  status text not null default 'pending'
    check (
      status in (
        'pending',
        'leased',
        'published',
        'completed',
        'cancelled',
        'dead'
      )
    ),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 8 check (max_attempts between 1 and 100),
  lease_token uuid,
  lease_until timestamptz,
  dedupe_key text not null
    check (char_length(dedupe_key) between 1 and 500),
  payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload) = 'object'),
  queue_message_id bigint,
  trace_id uuid not null,
  correlation_id uuid not null,
  causation_id uuid,
  last_error_class text
    check (
      last_error_class is null
      or char_length(last_error_class) between 1 and 120
    ),
  last_error_code text
    check (
      last_error_code is null
      or char_length(last_error_code) between 1 and 120
    ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  completed_at timestamptz,
  unique (organization_id, operation_id, id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    (status = 'leased' and lease_token is not null and lease_until is not null)
    or (
      status <> 'leased'
      and lease_token is null
      and lease_until is null
    )
  ),
  check (
    (status = 'completed' and completed_at is not null)
    or (status <> 'completed')
  )
);

comment on column public.scheduled_jobs.payload is
  'Minimal non-sensitive references only. Jobs load message content from canonical tables.';

create unique index scheduled_jobs_active_dedupe_idx
  on public.scheduled_jobs (organization_id, operation_id, dedupe_key)
  where status in ('pending', 'leased', 'published');

create index scheduled_jobs_due_idx
  on public.scheduled_jobs (run_at, id)
  where status = 'pending';

create index scheduled_jobs_expired_lease_idx
  on public.scheduled_jobs (lease_until, id)
  where status = 'leased';

create index webhook_inbox_status_age_idx
  on private.webhook_inbox (status, accepted_at, id);
create index webhook_inbox_operation_trace_idx
  on private.webhook_inbox (operation_id, trace_id);
create index idempotency_keys_expiry_idx
  on private.idempotency_keys (expires_at)
  where expires_at is not null;
create index effect_ledger_state_age_idx
  on private.effect_ledger (state, created_at, id);
create index outbox_events_pending_idx
  on private.outbox_events (created_at, id)
  where status = 'pending';
create index outbox_events_aggregate_order_idx
  on private.outbox_events (
    aggregate_type,
    aggregate_id,
    aggregate_sequence
  );
create index conversation_processing_leases_expiry_idx
  on private.conversation_processing_leases (lease_until, conversation_id);
create index processing_attempts_queue_observed_idx
  on private.processing_attempts (queue_name, observed_at desc);
create index processing_attempts_aggregate_idx
  on private.processing_attempts (
    aggregate_type,
    aggregate_id,
    aggregate_sequence,
    observed_at
  );
create index dead_letters_status_age_idx
  on private.dead_letters (status, created_at, id);

alter table public.scheduled_jobs enable row level security;

revoke all on table public.scheduled_jobs from public, anon, authenticated;
grant all on table public.scheduled_jobs to service_role;

revoke all on table private.webhook_inbox from public, anon, authenticated;
revoke all on table private.idempotency_keys from public, anon, authenticated;
revoke all on table private.effect_ledger from public, anon, authenticated;
revoke all on table private.aggregate_sequences from public, anon, authenticated;
revoke all on table private.outbox_events from public, anon, authenticated;
revoke all on table private.conversation_processing_leases
  from public, anon, authenticated;
revoke all on table private.processing_attempts
  from public, anon, authenticated;
revoke all on table private.dead_letters from public, anon, authenticated;

grant all on table private.webhook_inbox to service_role;
grant all on table private.idempotency_keys to service_role;
grant all on table private.effect_ledger to service_role;
grant all on table private.aggregate_sequences to service_role;
grant all on table private.outbox_events to service_role;
grant all on table private.conversation_processing_leases to service_role;
grant all on table private.processing_attempts to service_role;
grant all on table private.dead_letters to service_role;
grant usage, select on sequence private.processing_attempts_id_seq
  to service_role;
