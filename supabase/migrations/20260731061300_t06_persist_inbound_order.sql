-- T06: persist the accepted stream order on the canonical inbound message.

alter table public.messages
  add column inbound_stream_sequence bigint
    check (
      inbound_stream_sequence is null
      or inbound_stream_sequence > 0
    ),
  add constraint messages_outbound_has_no_inbound_sequence_check
    check (
      direction = 'inbound'
      or inbound_stream_sequence is null
    );

create or replace function private.assign_inbound_message_stream_sequence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.direction = 'inbound'
    and new.provider_message_id is not null
    and new.inbound_stream_sequence is null
  then
    select inbox.stream_sequence
    into new.inbound_stream_sequence
    from private.webhook_inbox as inbox
    where inbox.connection_id = new.connection_id
      and inbox.provider_event_id = new.provider_message_id;
  end if;
  return new;
end;
$$;

revoke all on function private.assign_inbound_message_stream_sequence()
  from public, anon, authenticated, service_role;

create trigger messages_assign_inbound_stream_sequence
before insert on public.messages
for each row execute function private.assign_inbound_message_stream_sequence();

update public.messages as message
set inbound_stream_sequence = inbox.stream_sequence
from private.webhook_inbox as inbox
where message.direction = 'inbound'
  and message.inbound_stream_sequence is null
  and inbox.connection_id = message.connection_id
  and inbox.provider_event_id = message.provider_message_id;

create unique index messages_conversation_inbound_stream_sequence_idx
  on public.messages (conversation_id, inbound_stream_sequence)
  where
    direction = 'inbound'
    and inbound_stream_sequence is not null;

comment on column public.messages.inbound_stream_sequence is
  'Canonical order assigned at durable webhook acceptance; null only for pre-T06 or direct synthetic fixtures.';
