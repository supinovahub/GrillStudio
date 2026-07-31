-- Preview verification corrections. PostgREST exposes the canonical JWT
-- object through request.jwt.claims on current hosted releases; keep the
-- legacy scalar setting as a compatibility fallback.

create or replace function private.assert_t07_service_role()
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  request_role text;
begin
  request_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
  );

  if request_role is distinct from 'service_role'
    and session_user not in ('postgres', 'supabase_admin')
  then
    raise exception 'T07 worker service role required'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function private.assert_t07_service_role()
  from public, anon, authenticated, service_role;

-- Append-only rows still reject direct mutation. FK cascades initiated by a
-- parent aggregate deletion must be able to complete tenant/test cleanup.
create or replace function private.reject_append_only_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  raise exception '% is append-only', tg_table_name using errcode = '42501';
end;
$$;

revoke all on function private.reject_append_only_mutation() from public;
