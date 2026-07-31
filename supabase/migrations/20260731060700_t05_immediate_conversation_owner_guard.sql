-- Reject an inactive human owner in the statement that attempts to assign it.
--
-- The deferred constraint remains necessary on Membership deactivation because
-- that transaction releases Conversation ownership after changing Membership
-- status. Conversation writes, however, have no valid reason to temporarily
-- point an open Conversation at an inactive Membro.

create or replace function private.guard_active_human_conversation_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('active', 'sleeping')
    and new.ownership_type = 'human'
    and not exists (
      select 1
      from public.memberships as membership
      join public.membership_operations as membership_operation
        on membership_operation.organization_id = membership.organization_id
        and membership_operation.membership_id = membership.id
      where membership.id = new.assigned_membership_id
        and membership.organization_id = new.organization_id
        and membership.status = 'active'
        and membership_operation.operation_id = new.operation_id
    )
  then
    raise exception 'active Conversation human owner must be an active Membro'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_active_human_conversation_owner()
  from public, anon, authenticated, service_role;

create trigger conversations_guard_active_human_owner
before insert or update on public.conversations
for each row execute function private.guard_active_human_conversation_owner();
