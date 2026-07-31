-- T06 follow-up: keep function metadata honest, remove a redundant PL/pgSQL
-- declaration, and cover the scheduled-job execution tenant FK.

alter function public.get_durable_processing_health(uuid) volatile;

create index scheduled_job_executions_tenant_job_fk_idx
  on private.scheduled_job_executions (
    organization_id,
    operation_id,
    scheduled_job_id
  );

-- This is intentionally the same bounded, cursor-based implementation
-- introduced in 20260731062200. Integer FOR loops declare their iterator
-- automatically, so the previous explicit table_index declaration was both
-- unused and shadowed.
create or replace function private.prune_t06_queue_archives(
  retention_window interval default interval '7 days',
  maximum_rows integer default 25000
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  archive_tables constant text[] := array[
    'a_inbound_whatsapp',
    'a_outbound_whatsapp',
    'a_scheduled_actions',
    'a_reconciliation',
    'a_dead_letter'
  ];
  archive_table text;
  start_offset integer;
  queue_quota integer;
  base_quota integer;
  remainder integer;
  remaining_rows integer;
  deleted_for_queue integer;
  existing_for_queue integer;
  deleted_total integer := 0;
  result_value jsonb := jsonb_build_object(
    'a_inbound_whatsapp', 0,
    'a_outbound_whatsapp', 0,
    'a_scheduled_actions', 0,
    'a_reconciliation', 0,
    'a_dead_letter', 0
  );
begin
  if retention_window < interval '1 day'
    or retention_window > interval '90 days'
    or maximum_rows not between 1 and 100000
  then
    raise exception 'invalid queue archive retention bounds'
      using errcode = '22023';
  end if;

  insert into private.durable_maintenance_cursors (
    maintenance_key,
    next_offset
  )
  values ('t06_queue_archives', 0)
  on conflict (maintenance_key) do nothing;

  select cursor.next_offset
  into strict start_offset
  from private.durable_maintenance_cursors as cursor
  where cursor.maintenance_key = 't06_queue_archives'
  for update;

  update private.durable_maintenance_cursors
  set
    next_offset = (start_offset + 1) % cardinality(archive_tables),
    updated_at = now()
  where maintenance_key = 't06_queue_archives';

  base_quota := maximum_rows / cardinality(archive_tables);
  remainder := maximum_rows % cardinality(archive_tables);

  for table_index in 0..cardinality(archive_tables) - 1 loop
    archive_table := archive_tables[
      ((start_offset + table_index) % cardinality(archive_tables)) + 1
    ];
    queue_quota := base_quota
      + case when table_index < remainder then 1 else 0 end;

    if queue_quota = 0 then
      continue;
    end if;

    execute format(
      $sql$
        with doomed as (
          select archive.msg_id
          from pgmq.%I as archive
          where archive.archived_at < now() - $1
          order by archive.archived_at, archive.msg_id
          for update skip locked
          limit $2
        )
        delete from pgmq.%I as archive
        using doomed
        where archive.msg_id = doomed.msg_id
      $sql$,
      archive_table,
      archive_table
    )
    using retention_window, queue_quota;
    get diagnostics deleted_for_queue = row_count;

    deleted_total := deleted_total + deleted_for_queue;
    result_value := jsonb_set(
      result_value,
      array[archive_table],
      to_jsonb(deleted_for_queue),
      true
    );
  end loop;

  remaining_rows := maximum_rows - deleted_total;
  if remaining_rows > 0 then
    for table_index in 0..cardinality(archive_tables) - 1 loop
      exit when remaining_rows = 0;
      archive_table := archive_tables[
        ((start_offset + table_index) % cardinality(archive_tables)) + 1
      ];

      execute format(
        $sql$
          with doomed as (
            select archive.msg_id
            from pgmq.%I as archive
            where archive.archived_at < now() - $1
            order by archive.archived_at, archive.msg_id
            for update skip locked
            limit $2
          )
          delete from pgmq.%I as archive
          using doomed
          where archive.msg_id = doomed.msg_id
        $sql$,
        archive_table,
        archive_table
      )
      using retention_window, remaining_rows;
      get diagnostics deleted_for_queue = row_count;

      existing_for_queue :=
        coalesce((result_value ->> archive_table)::integer, 0);
      deleted_total := deleted_total + deleted_for_queue;
      remaining_rows := remaining_rows - deleted_for_queue;
      result_value := jsonb_set(
        result_value,
        array[archive_table],
        to_jsonb(existing_for_queue + deleted_for_queue),
        true
      );
    end loop;
  end if;

  return result_value || jsonb_build_object('total', deleted_total);
end;
$$;

revoke all on function private.prune_t06_queue_archives(
  interval, integer
) from public, anon, authenticated, service_role;
