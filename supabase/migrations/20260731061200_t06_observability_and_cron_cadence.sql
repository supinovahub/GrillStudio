-- T06: redacted health surface and verified pg_cron sub-minute cadence.

create or replace function public.get_durable_processing_health(
  target_operation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_organization_id uuid;
  queue_metrics jsonb := null;
  health_value jsonb;
begin
  select operation.organization_id
  into strict target_organization_id
  from public.operations as operation
  where operation.id = target_operation_id;

  if not private.is_service_role()
    and not private.has_membership_permission(
      target_operation_id,
      'manage_conversations'
    )
  then
    raise exception 'missing permission: manage_conversations'
      using errcode = '42501';
  end if;

  -- Queue depth is global infrastructure metadata, so only service_role sees
  -- it. Human operators receive operation-scoped durable artifact counts.
  if private.is_service_role() then
    select jsonb_agg(
      jsonb_build_object(
        'queue', metric.queue_name,
        'depth', metric.queue_length,
        'visible', metric.queue_visible_length,
        'oldest_age_seconds', metric.oldest_msg_age_sec
      )
      order by metric.queue_name
    )
    into queue_metrics
    from (
      select (pgmq.metrics(queue_name)).*
      from unnest(
        array[
          'inbound_whatsapp',
          'outbound_whatsapp',
          'scheduled_actions',
          'reconciliation',
          'dead_letter'
        ]::text[]
      ) as queue(queue_name)
    ) as metric;
  end if;

  select jsonb_build_object(
    'operation_id', target_operation_id,
    'organization_id', target_organization_id,
    'observed_at', now(),
    'inbox', jsonb_build_object(
      'accepted', count(*) filter (where inbox.status = 'accepted'),
      'processing', count(*) filter (where inbox.status = 'processing'),
      'dead', count(*) filter (where inbox.status = 'dead'),
      'oldest_pending_seconds', coalesce(
        extract(
          epoch from now() - min(inbox.accepted_at)
            filter (where inbox.status in ('accepted', 'processing'))
        )::bigint,
        0
      )
    ),
    'outbox', (
      select jsonb_build_object(
        'pending', count(*) filter (where event.status = 'pending'),
        'published', count(*) filter (where event.status = 'published'),
        'dead', count(*) filter (where event.status = 'dead'),
        'oldest_pending_seconds', coalesce(
          extract(
            epoch from now() - min(event.created_at)
              filter (where event.status in ('pending', 'published'))
          )::bigint,
          0
        )
      )
      from private.outbox_events as event
      where event.operation_id = target_operation_id
    ),
    'active_leases', (
      select count(*)
      from private.conversation_processing_leases as lease
      where lease.operation_id = target_operation_id
        and lease.lease_until > now()
    ),
    'retryable_failures_last_hour', (
      select count(*)
      from private.processing_attempts as attempt
      where attempt.operation_id = target_operation_id
        and attempt.state = 'retryable_failed'
        and attempt.observed_at >= now() - interval '1 hour'
    ),
    'pending_dead_letters', (
      select count(*)
      from private.dead_letters as letter
      where letter.operation_id = target_operation_id
        and letter.status = 'pending'
    ),
    'overdue_jobs', (
      select count(*)
      from public.scheduled_jobs as job
      where job.operation_id = target_operation_id
        and job.status = 'pending'
        and job.run_at < now()
    ),
    'queue_metrics', queue_metrics
  )
  into health_value
  from private.webhook_inbox as inbox
  where inbox.operation_id = target_operation_id;

  return health_value;
end;
$$;

revoke all on function public.get_durable_processing_health(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_durable_processing_health(uuid)
  to authenticated, service_role;

select cron.unschedule('t06-scheduled-jobs-1s');
select cron.unschedule('t06-worker-recovery-5s');
select cron.unschedule('t06-reconciliation-1m');

select cron.schedule(
  't06-scheduled-jobs-1s',
  '1 second',
  'select private.dispatch_due_scheduled_jobs(100);'
);
select cron.schedule(
  't06-worker-recovery-5s',
  '5 seconds',
  'select private.run_durable_workers(25);'
);
select cron.schedule(
  't06-reconciliation-1m',
  '* * * * *',
  'select private.recover_durable_processing();'
);
