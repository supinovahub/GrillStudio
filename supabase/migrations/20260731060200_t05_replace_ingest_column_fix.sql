-- Fixes the Conversation insert column in the ingress routine.
--
-- Migrations 060000 and 060100 are immutable once applied. This forward-only
-- replacement makes existing Previews and fresh databases converge.

create or replace function private.ingest_simulated_inbound(
  target_connection_id uuid,
  normalized_event jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  connection_record public.whatsapp_connections%rowtype;
  existing_message public.messages%rowtype;
  conversation_record public.conversations%rowtype;
  manual_conversation public.conversations%rowtype;
  contact_record public.contacts%rowtype;
  phone_record public.contact_phones%rowtype;
  opportunity_record public.opportunities%rowtype;
  identity_record public.provider_identities%rowtype;
  provider_message_id_value text;
  provider_chat_id_value text;
  message_kind text;
  message_body text;
  identity_display_name text;
  phone_original text;
  normalized_phone text;
  occurred_at timestamptz;
  aliases jsonb;
  alias_item jsonb;
  alias_type_value text;
  alias_value_value text;
  identity_ids uuid[];
  identity_contact_ids uuid[];
  identity_contact_id uuid;
  phone_contact_id uuid;
  active_opportunity_ids uuid[];
  terminal_opportunity_ids uuid[];
  reopen_result text;
  requires_review boolean := false;
  review_reason_value text;
  created_contact boolean := false;
  created_opportunity boolean := false;
  created_conversation boolean := false;
  pinned_manual_conversation boolean := false;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  if jsonb_typeof(normalized_event) <> 'object'
    or normalized_event ->> 'provider' <> 'simulator'
  then
    raise exception 'invalid normalized simulator event'
      using errcode = '22023';
  end if;

  provider_message_id_value := nullif(
    left(btrim(coalesce(normalized_event ->> 'provider_message_id', '')), 500),
    ''
  );
  provider_chat_id_value := nullif(
    left(btrim(coalesce(normalized_event ->> 'provider_chat_id', '')), 500),
    ''
  );
  message_kind := nullif(
    btrim(coalesce(normalized_event ->> 'kind', '')),
    ''
  );
  message_body := nullif(
    left(coalesce(normalized_event ->> 'text', ''), 12000),
    ''
  );
  identity_display_name := nullif(
    left(
      btrim(coalesce(normalized_event #>> '{identity,display_name}', '')),
      160
    ),
    ''
  );
  phone_original := nullif(
    left(
      btrim(coalesce(normalized_event #>> '{identity,phone_original}', '')),
      80
    ),
    ''
  );
  aliases := coalesce(
    normalized_event #> '{identity,aliases}',
    '[]'::jsonb
  );

  if provider_message_id_value is null
    or provider_chat_id_value is null
    or message_kind not in (
      'text', 'image', 'document', 'audio', 'video', 'unknown'
    )
    or jsonb_typeof(aliases) <> 'array'
    or jsonb_array_length(aliases) = 0
  then
    raise exception 'normalized simulator event is incomplete'
      using errcode = '22023';
  end if;

  begin
    occurred_at := (normalized_event ->> 'occurred_at')::timestamptz;
  exception when others then
    raise exception 'normalized simulator timestamp is invalid'
      using errcode = '22023';
  end;

  for alias_item in
    select value
    from jsonb_array_elements(aliases)
  loop
    alias_type_value := alias_item ->> 'type';
    alias_value_value := nullif(
      left(btrim(coalesce(alias_item ->> 'value', '')), 500),
      ''
    );
    if alias_type_value not in (
      'simulator_user',
      'uazapi_sender',
      'uazapi_lid',
      'uazapi_pn',
      'meta_bsuid',
      'meta_parent_bsuid',
      'meta_wa_id',
      'meta_username'
    )
      or alias_value_value is null
    then
      raise exception 'normalized provider identity alias is invalid'
        using errcode = '22023';
    end if;
  end loop;

  select connection.*
  into connection_record
  from public.whatsapp_connections as connection
  where connection.id = target_connection_id
  for update;

  if connection_record.id is null
    or connection_record.adapter_type <> 'simulator'
    or not connection_record.is_test
    or connection_record.status <> 'active'
    or not connection_record.inbound_enabled
  then
    raise exception 'simulator connection is not available'
      using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'simulator-inbound:' || target_connection_id::text
        || ':' || provider_message_id_value,
      0
    )
  );

  select message.*
  into existing_message
  from public.messages as message
  where message.connection_id = target_connection_id
    and message.provider_message_id = provider_message_id_value;

  if existing_message.id is not null then
    return jsonb_build_object(
      'status', 'duplicate',
      'message_id', existing_message.id,
      'conversation_id', existing_message.conversation_id
    );
  end if;

  if exists (
    select 1
    from private.simulator_inbound_reviews as review
    where review.connection_id = target_connection_id
      and review.provider_message_id = provider_message_id_value
  ) then
    return jsonb_build_object('status', 'requires_review');
  end if;

  select conversation.*
  into conversation_record
  from public.conversations as conversation
  where conversation.connection_id = target_connection_id
    and conversation.provider_chat_id = provider_chat_id_value
    and conversation.status in ('active', 'sleeping')
  for update;

  if conversation_record.id is not null then
    select contact.*
    into strict contact_record
    from public.contacts as contact
    where contact.id = conversation_record.contact_id;
    select opportunity.*
    into strict opportunity_record
    from public.opportunities as opportunity
    where opportunity.id = conversation_record.opportunity_id;

    select
      coalesce(
        array_agg(distinct matched_alias.provider_identity_id)
          filter (where matched_alias.provider_identity_id is not null),
        array[]::uuid[]
      ),
      coalesce(
        array_agg(
          distinct case
            when matched_contact.status = 'merged'
              then matched_contact.merged_into_contact_id
            else matched_contact.id
          end
        ) filter (where matched_contact.id is not null),
        array[]::uuid[]
      )
    into identity_ids, identity_contact_ids
    from jsonb_array_elements(aliases) as incoming_alias(item)
    left join public.provider_identity_aliases as matched_alias
      on matched_alias.connection_id = target_connection_id
      and matched_alias.alias_type = incoming_alias.item ->> 'type'
      and matched_alias.alias_value = incoming_alias.item ->> 'value'
      and matched_alias.valid_until is null
    left join public.provider_identities as matched_identity
      on matched_identity.id = matched_alias.provider_identity_id
    left join public.contacts as matched_contact
      on matched_contact.id = matched_identity.contact_id;

    if coalesce(array_length(identity_ids, 1), 0) > 1
      or coalesce(array_length(identity_contact_ids, 1), 0) > 1
      or (
        coalesce(array_length(identity_contact_ids, 1), 0) = 1
        and identity_contact_ids[1] <> contact_record.id
      )
    then
      requires_review := true;
      review_reason_value := 'ambiguous_identity';
    end if;

    if phone_original is not null then
      normalized_phone := private.normalize_phone_e164(phone_original, '+55');
      select
        case
          when contact.status = 'merged' then contact.merged_into_contact_id
          else contact.id
        end
      into phone_contact_id
      from public.contact_phones as phone
      join public.contacts as contact on contact.id = phone.contact_id
      where phone.organization_id = connection_record.organization_id
        and phone.e164 = normalized_phone;

      if phone_contact_id is not null
        and phone_contact_id <> contact_record.id
      then
        requires_review := true;
        review_reason_value := 'identity_phone_conflict';
      end if;
    end if;

    if requires_review then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id_value,
        review_reason_value,
        normalized_event,
        request_trace_id,
        request_correlation_id
      );

      update public.conversations
      set
        is_paused = true,
        pause_reason = 'human_review_required',
        paused_at = now(),
        requires_human_review = true,
        review_reason = review_reason_value,
        updated_at = now(),
        version = version + 1
      where id = conversation_record.id
      returning * into strict conversation_record;
    elsif coalesce(array_length(identity_ids, 1), 0) <= 1 then
      if coalesce(array_length(identity_ids, 1), 0) = 1 then
        select identity.*
        into strict identity_record
        from public.provider_identities as identity
        where identity.id = identity_ids[1]
        for update;

        update public.provider_identities as target
        set
          display_name = coalesce(
            target.display_name,
            identity_display_name
          ),
          last_seen_at = greatest(target.last_seen_at, occurred_at),
          updated_at = now(),
          version = target.version + 1
        where target.id = identity_record.id
        returning target.* into strict identity_record;
      else
        select identity.*
        into identity_record
        from public.provider_identities as identity
        where identity.connection_id = target_connection_id
          and identity.contact_id = contact_record.id
        order by identity.last_seen_at desc, identity.id
        limit 1
        for update;

        if identity_record.id is null then
          insert into public.provider_identities (
            organization_id,
            operation_id,
            connection_id,
            contact_id,
            display_name,
            first_seen_at,
            last_seen_at
          )
          values (
            connection_record.organization_id,
            connection_record.operation_id,
            connection_record.id,
            contact_record.id,
            identity_display_name,
            occurred_at,
            occurred_at
          )
          returning * into strict identity_record;
        end if;
      end if;

      for alias_item in
        select value
        from jsonb_array_elements(aliases)
      loop
        insert into public.provider_identity_aliases (
          organization_id,
          operation_id,
          connection_id,
          provider_identity_id,
          alias_type,
          alias_value,
          valid_from
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          connection_record.id,
          identity_record.id,
          alias_item ->> 'type',
          alias_item ->> 'value',
          occurred_at
        )
        on conflict do nothing;
      end loop;
    end if;
  else
    select
      coalesce(
        array_agg(distinct matched_alias.provider_identity_id)
          filter (where matched_alias.provider_identity_id is not null),
        array[]::uuid[]
      ),
      coalesce(
        array_agg(
          distinct case
            when matched_contact.status = 'merged'
              then matched_contact.merged_into_contact_id
            else matched_contact.id
          end
        ) filter (where matched_contact.id is not null),
        array[]::uuid[]
      )
    into identity_ids, identity_contact_ids
    from jsonb_array_elements(aliases) as incoming_alias(item)
    left join public.provider_identity_aliases as matched_alias
      on matched_alias.connection_id = target_connection_id
      and matched_alias.alias_type = incoming_alias.item ->> 'type'
      and matched_alias.alias_value = incoming_alias.item ->> 'value'
      and matched_alias.valid_until is null
    left join public.provider_identities as matched_identity
      on matched_identity.id = matched_alias.provider_identity_id
    left join public.contacts as matched_contact
      on matched_contact.id = matched_identity.contact_id;

    if coalesce(array_length(identity_ids, 1), 0) > 1
      or coalesce(array_length(identity_contact_ids, 1), 0) > 1
    then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id_value,
        'ambiguous_identity',
        normalized_event,
        request_trace_id,
        request_correlation_id
      );
      return jsonb_build_object(
        'status', 'requires_review',
        'reason', 'ambiguous_identity'
      );
    end if;

    identity_contact_id := identity_contact_ids[1];

    if phone_original is not null then
      normalized_phone := private.normalize_phone_e164(phone_original, '+55');
      select
        case
          when contact.status = 'merged' then contact.merged_into_contact_id
          else contact.id
        end
      into phone_contact_id
      from public.contact_phones as phone
      join public.contacts as contact on contact.id = phone.contact_id
      where phone.organization_id = connection_record.organization_id
        and phone.e164 = normalized_phone;
    end if;

    if identity_contact_id is not null
      and phone_contact_id is not null
      and identity_contact_id <> phone_contact_id
    then
      requires_review := true;
      review_reason_value := 'identity_phone_conflict';
    end if;

    if identity_contact_id is not null then
      select contact.*
      into strict contact_record
      from public.contacts as contact
      where contact.id = identity_contact_id
      for update;
    elsif phone_contact_id is not null then
      select contact.*
      into strict contact_record
      from public.contacts as contact
      where contact.id = phone_contact_id
      for update;
    else
      insert into public.contacts (
        organization_id,
        display_name
      )
      values (
        connection_record.organization_id,
        identity_display_name
      )
      returning * into strict contact_record;
      created_contact := true;

      if normalized_phone is not null then
        insert into public.contact_phones (
          organization_id,
          contact_id,
          e164,
          original_value,
          is_primary
        )
        values (
          connection_record.organization_id,
          contact_record.id,
          normalized_phone,
          phone_original,
          true
        )
        returning * into phone_record;
      end if;
    end if;

    if phone_original is not null
      and normalized_phone is not null
      and not requires_review
    then
      if phone_record.id is null then
        select phone.*
        into phone_record
        from public.contact_phones as phone
        where phone.organization_id = connection_record.organization_id
          and phone.e164 = normalized_phone;
      end if;
      if phone_record.id is not null
        and phone_record.contact_id = contact_record.id
      then
        insert into public.contact_phone_observations (
          organization_id,
          contact_id,
          contact_phone_id,
          original_value,
          source_type
        )
        values (
          connection_record.organization_id,
          contact_record.id,
          phone_record.id,
          phone_original,
          'simulator_inbound'
        );
      end if;
    end if;

    if coalesce(array_length(identity_ids, 1), 0) = 1 then
      select identity.*
      into strict identity_record
      from public.provider_identities as identity
      where identity.id = identity_ids[1]
      for update;

      update public.provider_identities as target
      set
        display_name = coalesce(
          target.display_name,
          identity_display_name
        ),
        last_seen_at = greatest(target.last_seen_at, occurred_at),
        updated_at = now(),
        version = target.version + 1
      where target.id = identity_record.id
      returning target.* into strict identity_record;
    else
      insert into public.provider_identities (
        organization_id,
        operation_id,
        connection_id,
        contact_id,
        display_name,
        first_seen_at,
        last_seen_at
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        contact_record.id,
        identity_display_name,
        occurred_at,
        occurred_at
      )
      returning * into strict identity_record;
    end if;

    for alias_item in
      select value
      from jsonb_array_elements(aliases)
    loop
      insert into public.provider_identity_aliases (
        organization_id,
        operation_id,
        connection_id,
        provider_identity_id,
        alias_type,
        alias_value,
        valid_from
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        identity_record.id,
        alias_item ->> 'type',
        alias_item ->> 'value',
        occurred_at
      )
      on conflict do nothing;
    end loop;

    if normalized_phone is not null and not requires_review then
      insert into public.provider_identity_aliases (
        organization_id,
        operation_id,
        connection_id,
        provider_identity_id,
        alias_type,
        alias_value,
        valid_from
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        identity_record.id,
        'phone_e164',
        normalized_phone,
        occurred_at
      )
      on conflict do nothing;
    end if;

    select coalesce(array_agg(opportunity.id order by opportunity.id), array[]::uuid[])
    into active_opportunity_ids
    from public.opportunities as opportunity
    where opportunity.organization_id = connection_record.organization_id
      and opportunity.operation_id = connection_record.operation_id
      and opportunity.contact_id = contact_record.id
      and opportunity.stage not in ('lost', 'purchased');

    if coalesce(array_length(active_opportunity_ids, 1), 0) > 1 then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id_value,
        'ambiguous_opportunity',
        normalized_event,
        request_trace_id,
        request_correlation_id
      );
      return jsonb_build_object(
        'status', 'requires_review',
        'reason', 'ambiguous_opportunity'
      );
    elsif coalesce(array_length(active_opportunity_ids, 1), 0) = 1 then
      select * into strict opportunity_record
      from public.opportunities
      where id = active_opportunity_ids[1]
      for update;
    else
      select coalesce(
        array_agg(opportunity.id order by opportunity.id),
        array[]::uuid[]
      )
      into terminal_opportunity_ids
      from public.opportunities as opportunity
      where opportunity.organization_id = connection_record.organization_id
        and opportunity.operation_id = connection_record.operation_id
        and opportunity.contact_id = contact_record.id
        and opportunity.stage in ('lost', 'purchased');

      if coalesce(array_length(terminal_opportunity_ids, 1), 0) > 1 then
        insert into private.simulator_inbound_reviews (
          organization_id, operation_id, connection_id,
          provider_message_id, reason, normalized_event,
          trace_id, correlation_id
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          connection_record.id,
          provider_message_id_value,
          'ambiguous_opportunity',
          normalized_event,
          request_trace_id,
          request_correlation_id
        );
        return jsonb_build_object(
          'status', 'requires_review',
          'reason', 'ambiguous_opportunity'
        );
      elsif coalesce(array_length(terminal_opportunity_ids, 1), 0) = 1 then
        reopen_result := private.reopen_opportunity_on_inbound(
          terminal_opportunity_ids[1],
          request_trace_id,
          request_correlation_id
        );
        if reopen_result = 'human_review_required' then
          select * into strict opportunity_record
          from public.opportunities
          where id = terminal_opportunity_ids[1]
          for update;
          requires_review := true;
          review_reason_value := 'post_call_return';
        elsif reopen_result = 'reopened' then
          select * into strict opportunity_record
          from public.opportunities
          where id = terminal_opportunity_ids[1]
          for update;
        end if;
      end if;

      if opportunity_record.id is null then
        perform set_config('grillstudio.trace_id', request_trace_id::text, true);
        perform set_config(
          'grillstudio.correlation_id',
          request_correlation_id::text,
          true
        );
        perform set_config(
          'grillstudio.stage_reason',
          case
            when reopen_result = 'sale_closed'
              then 'new_inbound_after_purchased'
            else 'simulator_inbound'
          end,
          true
        );

        insert into public.opportunities (
          organization_id,
          operation_id,
          contact_id,
          stage,
          source_type
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          contact_record.id,
          'new',
          'simulator_inbound'
        )
        returning * into strict opportunity_record;
        created_opportunity := true;

        insert into public.source_attributions (
          organization_id,
          operation_id,
          contact_id,
          opportunity_id,
          source_type,
          source_label,
          details,
          attributed_at
        )
        values (
          connection_record.organization_id,
          connection_record.operation_id,
          contact_record.id,
          opportunity_record.id,
          'simulator_inbound',
          connection_record.display_name,
          jsonb_build_object(
            'connection_id', connection_record.id,
            'adapter_type', 'simulator'
          ),
          occurred_at
        );
      end if;
    end if;

    select conversation.*
    into manual_conversation
    from public.conversations as conversation
    where conversation.opportunity_id = opportunity_record.id
      and conversation.connection_id is null
      and conversation.status in ('active', 'sleeping')
    for update;

    if manual_conversation.id is not null then
      perform set_config(
        'grillstudio.pin_conversation_id',
        manual_conversation.id::text,
        true
      );
      update public.conversations
      set
        connection_id = connection_record.id,
        provider_chat_id = provider_chat_id_value,
        requires_human_review =
          requires_human_review or requires_review,
        review_reason = case
          when requires_review then review_reason_value
          else review_reason
        end,
        is_paused = case
          when requires_review then true
          else is_paused
        end,
        pause_reason = case
          when requires_review then 'human_review_required'
          else pause_reason
        end,
        paused_at = case
          when requires_review then now()
          else paused_at
        end,
        last_inbound_at = occurred_at,
        updated_at = now(),
        version = version + 1
      where id = manual_conversation.id
        and connection_id is null
        and version = manual_conversation.version
      returning * into conversation_record;

      if conversation_record.id is null then
        raise exception 'manual Conversation changed before origin pin'
          using errcode = '40001';
      end if;
      pinned_manual_conversation := true;
    else
      insert into public.conversations (
        organization_id,
        operation_id,
        contact_id,
        opportunity_id,
        connection_id,
        provider_chat_id,
        status,
        ownership_type,
        automation_mode,
        is_paused,
        pause_reason,
        paused_at,
        requires_human_review,
        review_reason,
        last_inbound_at
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        contact_record.id,
        opportunity_record.id,
        connection_record.id,
        provider_chat_id_value,
        'active',
        'pedro',
        'shadow',
        requires_review,
        case when requires_review then 'human_review_required' else null end,
        case when requires_review then now() else null end,
        requires_review,
        review_reason_value,
        occurred_at
      )
      returning * into strict conversation_record;
      created_conversation := true;
    end if;

    if requires_review then
      insert into private.simulator_inbound_reviews (
        organization_id, operation_id, connection_id,
        provider_message_id, reason, normalized_event,
        trace_id, correlation_id
      )
      values (
        connection_record.organization_id,
        connection_record.operation_id,
        connection_record.id,
        provider_message_id_value,
        review_reason_value,
        normalized_event,
        request_trace_id,
        request_correlation_id
      )
      on conflict (connection_id, provider_message_id) do nothing;
    end if;
  end if;

  if conversation_record.id is not null
    and conversation_record.connection_id <> connection_record.id
  then
    raise exception 'Conversation is pinned to another connection'
      using errcode = '23514';
  end if;

  insert into public.messages (
    organization_id,
    operation_id,
    conversation_id,
    connection_id,
    direction,
    kind,
    body,
    status,
    provider_message_id,
    provider_occurred_at,
    created_by_type
  )
  values (
    connection_record.organization_id,
    connection_record.operation_id,
    conversation_record.id,
    connection_record.id,
    'inbound',
    message_kind,
    message_body,
    'received',
    provider_message_id_value,
    occurred_at,
    'provider'
  )
  returning * into strict existing_message;

  update public.conversations
  set
    last_inbound_at = greatest(
      coalesce(last_inbound_at, occurred_at),
      occurred_at
    ),
    updated_at = now(),
    version = version + 1
  where id = conversation_record.id
  returning * into strict conversation_record;

  insert into audit.audit_events (
    organization_id, operation_id, actor_user_id, action,
    target_type, target_id, before_state, after_state,
    trace_id, correlation_id
  )
  values (
    connection_record.organization_id,
    connection_record.operation_id,
    null,
    'message.inbound_received',
    'message',
    existing_message.id,
    null,
    jsonb_build_object(
      'conversation_id', conversation_record.id,
      'connection_id', connection_record.id,
      'provider_message_id_hash',
        md5(provider_message_id_value),
      'created_contact', created_contact,
      'created_opportunity', created_opportunity,
      'created_conversation', created_conversation,
      'pinned_manual_conversation', pinned_manual_conversation,
      'requires_human_review', conversation_record.requires_human_review,
      'ownership_type', conversation_record.ownership_type,
      'version', conversation_record.version
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'status', 'received',
    'contact_id', contact_record.id,
    'opportunity_id', opportunity_record.id,
    'conversation_id', conversation_record.id,
    'message_id', existing_message.id,
    'ownership_type', conversation_record.ownership_type,
    'requires_human_review', conversation_record.requires_human_review,
    'version', conversation_record.version
  );
end;
$$;
