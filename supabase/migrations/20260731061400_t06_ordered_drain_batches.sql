-- T06: drain multiple ordered effects per wake without letting N+1 overtake N.

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

  -- The dispatcher intentionally publishes only the earliest incomplete
  -- sequence per aggregate. Complete that effect, then repeat so a single
  -- wake can drain a batch while preserving the ordering fence.
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
