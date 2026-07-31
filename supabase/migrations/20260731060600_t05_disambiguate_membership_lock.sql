-- Disambiguate the local Membership identifier from table columns.

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
  resolved_membership_id uuid;
begin
  select conversation.operation_id
  into target_operation_id
  from public.conversations as conversation
  where conversation.id = target_conversation_id;

  if target_operation_id is null then
    raise exception 'Conversation permission denied' using errcode = '42501';
  end if;

  select membership.id
  into resolved_membership_id
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.organization_id = membership.organization_id
    and membership_operation.membership_id = membership.id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id;

  if resolved_membership_id is null then
    raise exception 'active Membership required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'membership-ownership:' || resolved_membership_id::text,
      0
    )
  );

  if not exists (
    select 1
    from public.memberships as membership
    join public.membership_operations as membership_operation
      on membership_operation.organization_id = membership.organization_id
      and membership_operation.membership_id = membership.id
    where membership.id = resolved_membership_id
      and membership.user_id = auth.uid()
      and membership.status = 'active'
      and membership_operation.operation_id = target_operation_id
  )
    or not private.can_manage_conversation_operation(target_operation_id)
  then
    raise exception 'Conversation permission denied' using errcode = '42501';
  end if;

  return query
  select
    target_conversation_id,
    target_operation_id,
    resolved_membership_id;
end;
$$;

revoke all on function private.assert_conversation_command_access(uuid)
  from public, anon, authenticated, service_role;
