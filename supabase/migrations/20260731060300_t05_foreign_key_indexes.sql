-- Postgres does not create indexes on the referencing side of foreign keys.
-- Keep cascade checks and the Inbox joins bounded as these tables grow.

create index simulator_inbound_reviews_connection_fk_idx
  on private.simulator_inbound_reviews (
    organization_id,
    operation_id,
    connection_id
  );

create index simulator_outbound_captures_conversation_fk_idx
  on private.simulator_outbound_captures (
    organization_id,
    operation_id,
    conversation_id
  );

create index simulator_outbound_captures_message_fk_idx
  on private.simulator_outbound_captures (
    organization_id,
    operation_id,
    connection_id,
    message_id
  );

create index conversations_paused_by_membership_fk_idx
  on public.conversations (
    organization_id,
    paused_by_membership_id
  );

create index conversations_pending_return_by_membership_fk_idx
  on public.conversations (
    organization_id,
    pending_return_requested_by_membership_id
  );

create index messages_conversation_connection_fk_idx
  on public.messages (
    organization_id,
    operation_id,
    conversation_id,
    connection_id
  );
