alter table public.operation_settings
  add column active_context_publication_id uuid;

create table public.institutional_profile_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  version_number bigint not null check (version_number > 0),
  status text not null default 'draft'
    check (status in ('draft', 'validating', 'published', 'archived')),
  fields jsonb not null default '{}'::jsonb
    check (jsonb_typeof(fields) = 'object'),
  baseline_version_id uuid references public.institutional_profile_versions(id),
  validation_errors jsonb not null default '[]'::jsonb
    check (jsonb_typeof(validation_errors) = 'array'),
  diff_snapshot jsonb,
  content_hash text,
  created_by_user_id uuid not null references auth.users(id),
  validated_by_user_id uuid references auth.users(id),
  validated_at timestamptz,
  published_by_user_id uuid references auth.users(id),
  published_at timestamptz,
  archived_by_user_id uuid references auth.users(id),
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (operation_id, version_number),
  unique (organization_id, id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  check (
    (status = 'draft' and validated_at is null and published_at is null)
    or (status = 'validating' and validated_at is not null and published_at is null)
    or (status = 'published' and validated_at is not null and published_at is not null)
    or (status = 'archived')
  )
);

create unique index institutional_profile_one_open_draft_per_operation
  on public.institutional_profile_versions (operation_id)
  where status in ('draft', 'validating');

create index institutional_profile_versions_operation_created_idx
  on public.institutional_profile_versions (operation_id, created_at desc);

create table public.personas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  internal_name text not null check (char_length(internal_name) between 1 and 120),
  status text not null default 'active'
    check (status in ('active', 'archived')),
  created_by_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (organization_id, id),
  unique (operation_id, internal_name),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade
);

create table public.persona_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  persona_id uuid not null,
  version_number bigint not null check (version_number > 0),
  status text not null default 'draft'
    check (status in ('draft', 'validating', 'published', 'archived')),
  identity jsonb not null default '{}'::jsonb
    check (jsonb_typeof(identity) = 'object'),
  biography jsonb not null default '{}'::jsonb
    check (jsonb_typeof(biography) = 'object'),
  style_rules jsonb not null default '{}'::jsonb
    check (jsonb_typeof(style_rules) = 'object'),
  instructions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(instructions) = 'object'),
  baseline_version_id uuid references public.persona_versions(id),
  validation_errors jsonb not null default '[]'::jsonb
    check (jsonb_typeof(validation_errors) = 'array'),
  diff_snapshot jsonb,
  content_hash text,
  created_by_user_id uuid not null references auth.users(id),
  validated_by_user_id uuid references auth.users(id),
  validated_at timestamptz,
  published_by_user_id uuid references auth.users(id),
  published_at timestamptz,
  archived_by_user_id uuid references auth.users(id),
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  unique (persona_id, version_number),
  unique (organization_id, id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, persona_id)
    references public.personas(organization_id, id) on delete cascade,
  check (
    (status = 'draft' and validated_at is null and published_at is null)
    or (status = 'validating' and validated_at is not null and published_at is null)
    or (status = 'published' and validated_at is not null and published_at is not null)
    or (status = 'archived')
  )
);

create unique index persona_versions_one_open_draft_per_persona
  on public.persona_versions (persona_id)
  where status in ('draft', 'validating');

create index persona_versions_operation_created_idx
  on public.persona_versions (operation_id, created_at desc);

create table public.context_publications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  operation_id uuid not null,
  publication_number bigint not null check (publication_number > 0),
  behavioral_version_id uuid not null,
  factual_version_id uuid not null,
  behavioral_snapshot jsonb not null check (jsonb_typeof(behavioral_snapshot) = 'object'),
  factual_snapshot jsonb not null check (jsonb_typeof(factual_snapshot) = 'object'),
  behavioral_hash text not null check (char_length(behavioral_hash) = 64),
  factual_hash text not null check (char_length(factual_hash) = 64),
  combined_hash text not null check (char_length(combined_hash) = 64),
  published_by_user_id uuid not null references auth.users(id),
  published_at timestamptz not null default now(),
  unique (operation_id, publication_number),
  unique (organization_id, id),
  unique (organization_id, operation_id, id),
  foreign key (organization_id, operation_id)
    references public.operations(organization_id, id) on delete cascade,
  foreign key (organization_id, behavioral_version_id)
    references public.persona_versions(organization_id, id),
  foreign key (organization_id, factual_version_id)
    references public.institutional_profile_versions(organization_id, id)
);

alter table public.operation_settings
  add constraint operation_settings_active_context_publication_fkey
  foreign key (
    organization_id,
    operation_id,
    active_context_publication_id
  )
  references public.context_publications(organization_id, operation_id, id);

alter table public.institutional_profile_versions enable row level security;
alter table public.personas enable row level security;
alter table public.persona_versions enable row level security;
alter table public.context_publications enable row level security;

revoke all on table public.institutional_profile_versions from anon, authenticated;
revoke all on table public.personas from anon, authenticated;
revoke all on table public.persona_versions from anon, authenticated;
revoke all on table public.context_publications from anon, authenticated;
grant select on table public.institutional_profile_versions to authenticated;
grant select on table public.personas to authenticated;
grant select on table public.persona_versions to authenticated;
grant select on table public.context_publications to authenticated;

create or replace function private.can_read_context(target_operation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    private.has_membership_permission(target_operation_id, 'publish_knowledge')
    or private.has_membership_permission(target_operation_id, 'train_pedro')
    or private.has_membership_permission(target_operation_id, 'publish_learning');
$$;

revoke all on function private.can_read_context(uuid) from public;
grant execute on function private.can_read_context(uuid) to authenticated;

create policy institutional_profile_versions_select_context_members
  on public.institutional_profile_versions
  for select
  to authenticated
  using (private.can_read_context(operation_id));

create policy personas_select_context_members
  on public.personas
  for select
  to authenticated
  using (private.can_read_context(operation_id));

create policy persona_versions_select_context_members
  on public.persona_versions
  for select
  to authenticated
  using (private.can_read_context(operation_id));

create policy context_publications_select_context_members
  on public.context_publications
  for select
  to authenticated
  using (private.can_read_context(operation_id));

create or replace function private.is_owner_for_operation(target_operation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships as membership
    join public.membership_roles as membership_role
      on membership_role.membership_id = membership.id
      and membership_role.organization_id = membership.organization_id
    join public.membership_operations as membership_operation
      on membership_operation.membership_id = membership.id
      and membership_operation.organization_id = membership.organization_id
    where membership.user_id = auth.uid()
      and membership.status = 'active'
      and membership_role.role = 'owner'
      and membership_operation.operation_id = target_operation_id
  );
$$;

create or replace function private.operation_actor(target_operation_id uuid)
returns public.memberships
language sql
stable
security definer
set search_path = ''
as $$
  select membership
  from public.memberships as membership
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
  where membership.user_id = auth.uid()
    and membership.status = 'active'
    and membership_operation.operation_id = target_operation_id
  limit 1;
$$;

revoke all on function private.is_owner_for_operation(uuid) from public;
revoke all on function private.operation_actor(uuid) from public;
grant execute on function private.is_owner_for_operation(uuid) to authenticated;
grant execute on function private.operation_actor(uuid) to authenticated;

create or replace function private.context_baseline_identity()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'full_name', '',
    'professional_role', 'Corretor',
    'city', '',
    'presents_as_broker', true,
    'creci', '',
    'creci_uf', ''
  );
$$;

create or replace function private.context_baseline_biography()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'professional_experience', '',
    'interests', '',
    'team', '',
    'approved_routine', ''
  );
$$;

create or replace function private.context_baseline_style()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'language', 'pt-BR',
    'tone', 'natural, informal e humano',
    'one_question_at_a_time', true,
    'controlled_abbreviations', jsonb_build_array('vc', 'ta', 'pra'),
    'humor_after_rapport', true,
    'never_invent_personal_experience', true
  );
$$;

create or replace function private.context_baseline_instructions()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'identity_disclosure', 'Nunca se apresentar como IA; pergunta direta exige escalonamento silencioso sem resposta.',
    'knowledge_boundary', 'Responder somente fatos publicados e nunca inventar CRECI, experiência, preço, disponibilidade ou rentabilidade.',
    'scope', 'Atender, qualificar, responder conhecimento aprovado, conduzir follow-up e chegar ao agendamento.',
    'escalation', 'Escalar silenciosamente riscos, privacidade, fraude, idioma não suportado e situações fora do conhecimento.',
    'qualification', 'Uma pergunta natural por vez; respeitar respostas existentes, recusas, conflitos e validade.',
    'scheduling', 'Confirmar data, horário e formato; não sugerir reagendamento sem solicitação do lead.'
  );
$$;

create or replace function private.empty_institutional_fields()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_object_agg(
    field_name,
    jsonb_build_object(
      'value', '',
      'source', '',
      'confirmed_at', null,
      'valid_until', null,
      'public_source_url', '',
      'disclosure', 'on_request',
      'confirmed_by_owner', false
    )
  )
  from unnest(
    array[
      'trade_name',
      'legal_name',
      'creci_pj',
      'creci_uf',
      'cnpj',
      'address',
      'phone',
      'website',
      'instagram',
      'email',
      'business_hours',
      'privacy_contact'
    ]::text[]
  ) as field_name;
$$;

revoke all on function private.context_baseline_identity() from public;
revoke all on function private.context_baseline_biography() from public;
revoke all on function private.context_baseline_style() from public;
revoke all on function private.context_baseline_instructions() from public;
revoke all on function private.empty_institutional_fields() from public;

create or replace function private.profile_validation_errors(profile_fields jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  errors jsonb := '[]'::jsonb;
  field_key text;
  field_value jsonb;
  required_key text;
begin
  if jsonb_typeof(profile_fields) <> 'object' then
    return jsonb_build_array('Perfil institucional inválido.');
  end if;

  foreach required_key in array array['trade_name', 'creci_pj', 'creci_uf']
  loop
    if nullif(btrim(profile_fields -> required_key ->> 'value'), '') is null then
      errors := errors || jsonb_build_array(
        case required_key
          when 'trade_name' then 'Informe o nome comercial.'
          when 'creci_pj' then 'Informe o CRECI PJ.'
          else 'Informe a UF do CRECI PJ.'
        end
      );
    end if;
  end loop;

  for field_key, field_value in
    select key, value from jsonb_each(profile_fields)
  loop
    if field_key <> all (
      array[
        'trade_name', 'legal_name', 'creci_pj', 'creci_uf', 'cnpj',
        'address', 'phone', 'website', 'instagram', 'email',
        'business_hours', 'privacy_contact'
      ]::text[]
    ) then
      errors := errors || jsonb_build_array(
        format('Campo institucional não reconhecido: %s.', field_key)
      );
      continue;
    end if;

    if nullif(btrim(field_value ->> 'value'), '') is not null then
      if nullif(btrim(field_value ->> 'source'), '') is null then
        errors := errors || jsonb_build_array(
          format('Informe a fonte de %s.', field_key)
        );
      end if;
      if nullif(btrim(field_value ->> 'confirmed_at'), '') is null then
        errors := errors || jsonb_build_array(
          format('Informe a data de conferência de %s.', field_key)
        );
      end if;
      if coalesce((field_value ->> 'confirmed_by_owner')::boolean, false) is false then
        errors := errors || jsonb_build_array(
          format('O Dono precisa confirmar %s.', field_key)
        );
      end if;
      if coalesce(field_value ->> 'disclosure', '') not in (
        'on_request', 'when_needed', 'never'
      ) then
        errors := errors || jsonb_build_array(
          format('Defina a permissão de divulgação de %s.', field_key)
        );
      end if;
      if nullif(field_value ->> 'valid_until', '') is not null
        and (field_value ->> 'valid_until')::date < current_date then
        errors := errors || jsonb_build_array(
          format('A validade de %s está vencida.', field_key)
        );
      end if;
    end if;
  end loop;

  return errors;
exception
  when invalid_text_representation or datetime_field_overflow then
    return errors || jsonb_build_array(
      'Revise datas, confirmações e permissões do perfil institucional.'
    );
end;
$$;

create or replace function private.persona_validation_errors(
  persona_identity jsonb,
  persona_biography jsonb,
  persona_style jsonb,
  persona_instructions jsonb
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  errors jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(persona_identity) <> 'object'
    or jsonb_typeof(persona_biography) <> 'object'
    or jsonb_typeof(persona_style) <> 'object'
    or jsonb_typeof(persona_instructions) <> 'object' then
    return jsonb_build_array('Conteúdo da Persona inválido.');
  end if;

  if nullif(btrim(persona_identity ->> 'full_name'), '') is null then
    errors := errors || jsonb_build_array(
      'Informe o nome completo da Persona.'
    );
  end if;

  if coalesce((persona_identity ->> 'presents_as_broker')::boolean, false) then
    if nullif(btrim(persona_identity ->> 'creci'), '') is null then
      errors := errors || jsonb_build_array(
        'Informe o CRECI da Persona que se apresenta como Corretor.'
      );
    end if;
    if nullif(btrim(persona_identity ->> 'creci_uf'), '') is null then
      errors := errors || jsonb_build_array(
        'Informe a UF do CRECI da Persona.'
      );
    end if;
  end if;

  if coalesce(persona_style ->> 'language', '') <> 'pt-BR' then
    errors := errors || jsonb_build_array(
      'O MVP aceita somente português brasileiro.'
    );
  end if;

  return errors;
exception
  when invalid_text_representation then
    return errors || jsonb_build_array(
      'Revise os dados profissionais da Persona.'
    );
end;
$$;

revoke all on function private.profile_validation_errors(jsonb) from public;
revoke all on function private.persona_validation_errors(
  jsonb, jsonb, jsonb, jsonb
) from public;

create or replace function private.protect_context_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and old.status in ('published', 'archived') then
    raise exception 'published context versions are immutable'
      using errcode = '55000';
  end if;

  if tg_op = 'UPDATE' and old.status in ('published', 'archived') then
    if old.status = 'archived'
      or new.status <> 'archived'
      or (
        to_jsonb(new)
          - array[
              'status', 'archived_by_user_id', 'archived_at',
              'updated_at', 'version'
            ]::text[]
        <>
        to_jsonb(old)
          - array[
              'status', 'archived_by_user_id', 'archived_at',
              'updated_at', 'version'
            ]::text[]
      ) then
      raise exception 'published context versions are immutable'
        using errcode = '55000';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create or replace function private.protect_context_publication()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'context publications are immutable'
    using errcode = '55000';
end;
$$;

create trigger institutional_profile_versions_immutable
before update or delete on public.institutional_profile_versions
for each row execute function private.protect_context_version();

create trigger persona_versions_immutable
before update or delete on public.persona_versions
for each row execute function private.protect_context_version();

create trigger context_publications_immutable
before update or delete on public.context_publications
for each row execute function private.protect_context_publication();

revoke all on function private.protect_context_version() from public;
revoke all on function private.protect_context_publication() from public;

create or replace function private.append_context_audit(
  audit_organization_id uuid,
  audit_operation_id uuid,
  audit_actor_user_id uuid,
  audit_action text,
  audit_target_type text,
  audit_target_id uuid,
  audit_before jsonb,
  audit_after jsonb,
  audit_trace_id uuid,
  audit_correlation_id uuid
)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into audit.audit_events (
    organization_id,
    operation_id,
    actor_user_id,
    action,
    target_type,
    target_id,
    before_state,
    after_state,
    trace_id,
    correlation_id
  )
  values (
    audit_organization_id,
    audit_operation_id,
    audit_actor_user_id,
    audit_action,
    audit_target_type,
    audit_target_id,
    audit_before,
    audit_after,
    audit_trace_id,
    audit_correlation_id
  );
$$;

revoke all on function private.append_context_audit(
  uuid, uuid, uuid, text, text, uuid, jsonb, jsonb, uuid, uuid
) from public;

create or replace function private.initialize_context_drafts(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  target_persona_id uuid;
  factual_version_id uuid;
  behavioral_version_id uuid;
begin
  if auth.uid() is null or not private.can_read_context(target_operation_id) then
    raise exception 'context preparation permission denied' using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);
  perform operation.id
  from public.operations as operation
  where operation.id = target_operation_id
    and operation.organization_id = actor.organization_id
  for update;

  if not found then
    raise exception 'operation not found' using errcode = 'P0002';
  end if;

  select persona.id
  into target_persona_id
  from public.personas as persona
  where persona.operation_id = target_operation_id
    and persona.status = 'active'
  order by persona.created_at
  limit 1;

  if target_persona_id is null then
    insert into public.personas (
      organization_id,
      operation_id,
      internal_name,
      created_by_user_id
    )
    values (
      actor.organization_id,
      target_operation_id,
      'Pedro',
      auth.uid()
    )
    returning id into target_persona_id;
  end if;

  select profile.id
  into factual_version_id
  from public.institutional_profile_versions as profile
  where profile.operation_id = target_operation_id
    and profile.status in ('draft', 'validating')
  order by profile.created_at desc
  limit 1;

  if factual_version_id is null
    and not exists (
      select 1
      from public.context_publications as publication
      where publication.operation_id = target_operation_id
    ) then
    insert into public.institutional_profile_versions (
      organization_id,
      operation_id,
      version_number,
      fields,
      created_by_user_id
    )
    values (
      actor.organization_id,
      target_operation_id,
      1,
      private.empty_institutional_fields(),
      auth.uid()
    )
    returning id into factual_version_id;
  end if;

  select persona_version.id
  into behavioral_version_id
  from public.persona_versions as persona_version
  where persona_version.persona_id = target_persona_id
    and persona_version.status in ('draft', 'validating')
  order by persona_version.created_at desc
  limit 1;

  if behavioral_version_id is null
    and not exists (
      select 1
      from public.context_publications as publication
      where publication.operation_id = target_operation_id
    ) then
    insert into public.persona_versions (
      organization_id,
      operation_id,
      persona_id,
      version_number,
      identity,
      biography,
      style_rules,
      instructions,
      created_by_user_id
    )
    values (
      actor.organization_id,
      target_operation_id,
      target_persona_id,
      1,
      private.context_baseline_identity(),
      private.context_baseline_biography(),
      private.context_baseline_style(),
      private.context_baseline_instructions(),
      auth.uid()
    )
    returning id into behavioral_version_id;
  end if;

  perform private.append_context_audit(
    actor.organization_id,
    target_operation_id,
    auth.uid(),
    'context.initial_drafts_prepared',
    'operation',
    target_operation_id,
    null,
    jsonb_build_object(
      'factual_version_id', factual_version_id,
      'behavioral_version_id', behavioral_version_id
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'ok', true,
    'factual_version_id', factual_version_id,
    'behavioral_version_id', behavioral_version_id
  );
end;
$$;

revoke all on function private.initialize_context_drafts(
  uuid, uuid, uuid
) from public;
grant execute on function private.initialize_context_drafts(uuid, uuid, uuid)
  to authenticated;

create or replace function private.save_institutional_profile_draft(
  target_operation_id uuid,
  target_version_id uuid,
  expected_version bigint,
  profile_fields jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  current_version public.institutional_profile_versions%rowtype;
  normalized_fields jsonb := '{}'::jsonb;
  current_field jsonb;
  submitted_field jsonb;
  field_key text;
  actor_is_owner boolean;
begin
  if auth.uid() is null or not private.has_membership_permission(
    target_operation_id,
    'publish_knowledge'
  ) then
    raise exception 'institutional profile permission denied'
      using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);
  actor_is_owner := private.is_owner_for_operation(target_operation_id);

  select profile.*
  into strict current_version
  from public.institutional_profile_versions as profile
  where profile.id = target_version_id
    and profile.operation_id = target_operation_id
    and profile.organization_id = actor.organization_id
  for update;

  if current_version.status in ('published', 'archived') then
    perform private.append_context_audit(
      actor.organization_id,
      target_operation_id,
      auth.uid(),
      'context.published_version_modification_denied',
      'institutional_profile_version',
      current_version.id,
      jsonb_build_object('status', current_version.status),
      jsonb_build_object('reason', 'published_immutable'),
      request_trace_id,
      request_correlation_id
    );
    return jsonb_build_object('ok', false, 'reason', 'published_immutable');
  end if;

  if current_version.version <> expected_version then
    return jsonb_build_object(
      'ok', false,
      'reason', 'version_conflict',
      'current_version', current_version.version
    );
  end if;

  if jsonb_typeof(profile_fields) <> 'object' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_payload');
  end if;

  foreach field_key in array array[
    'trade_name', 'legal_name', 'creci_pj', 'creci_uf', 'cnpj',
    'address', 'phone', 'website', 'instagram', 'email',
    'business_hours', 'privacy_contact'
  ]::text[]
  loop
    current_field := coalesce(
      current_version.fields -> field_key,
      private.empty_institutional_fields() -> field_key
    );
    submitted_field := coalesce(profile_fields -> field_key, current_field);

    normalized_fields := normalized_fields || jsonb_build_object(
      field_key,
      jsonb_build_object(
        'value', left(coalesce(submitted_field ->> 'value', ''), 500),
        'source', left(coalesce(submitted_field ->> 'source', ''), 500),
        'confirmed_at', nullif(submitted_field ->> 'confirmed_at', ''),
        'valid_until', nullif(submitted_field ->> 'valid_until', ''),
        'public_source_url', left(
          coalesce(submitted_field ->> 'public_source_url', ''),
          1000
        ),
        'disclosure',
          case
            when submitted_field ->> 'disclosure' in (
              'on_request', 'when_needed', 'never'
            ) then submitted_field ->> 'disclosure'
            else 'on_request'
          end,
        'confirmed_by_owner',
          case
            when actor_is_owner
              then coalesce(
                (submitted_field ->> 'confirmed_by_owner')::boolean,
                false
              )
            when (
              submitted_field
                - array['confirmed_by_owner']::text[]
            ) = (
              current_field
                - array['confirmed_by_owner']::text[]
            )
              then coalesce(
                (current_field ->> 'confirmed_by_owner')::boolean,
                false
              )
            else false
          end
      )
    );
  end loop;

  update public.institutional_profile_versions
  set
    fields = normalized_fields,
    status = 'draft',
    validation_errors = '[]'::jsonb,
    diff_snapshot = null,
    content_hash = null,
    validated_by_user_id = null,
    validated_at = null,
    updated_at = now(),
    version = version + 1
  where id = current_version.id;

  perform private.append_context_audit(
    actor.organization_id,
    target_operation_id,
    auth.uid(),
    'context.institutional_draft_saved',
    'institutional_profile_version',
    current_version.id,
    jsonb_build_object(
      'version', current_version.version,
      'status', current_version.status
    ),
    jsonb_build_object(
      'version', current_version.version + 1,
      'status', 'draft'
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'ok', true,
    'version', current_version.version + 1
  );
exception
  when invalid_text_representation or datetime_field_overflow then
    return jsonb_build_object('ok', false, 'reason', 'invalid_payload');
end;
$$;

create or replace function private.save_persona_draft(
  target_operation_id uuid,
  target_version_id uuid,
  expected_version bigint,
  persona_identity jsonb,
  persona_biography jsonb,
  persona_style_rules jsonb,
  persona_instructions jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  current_version public.persona_versions%rowtype;
  actor_is_owner boolean;
begin
  if auth.uid() is null or not private.has_membership_permission(
    target_operation_id,
    'train_pedro'
  ) then
    raise exception 'persona preparation permission denied'
      using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);
  actor_is_owner := private.is_owner_for_operation(target_operation_id);

  select persona_version.*
  into strict current_version
  from public.persona_versions as persona_version
  where persona_version.id = target_version_id
    and persona_version.operation_id = target_operation_id
    and persona_version.organization_id = actor.organization_id
  for update;

  if current_version.status in ('published', 'archived') then
    perform private.append_context_audit(
      actor.organization_id,
      target_operation_id,
      auth.uid(),
      'context.published_version_modification_denied',
      'persona_version',
      current_version.id,
      jsonb_build_object('status', current_version.status),
      jsonb_build_object('reason', 'published_immutable'),
      request_trace_id,
      request_correlation_id
    );
    return jsonb_build_object('ok', false, 'reason', 'published_immutable');
  end if;

  if current_version.version <> expected_version then
    return jsonb_build_object(
      'ok', false,
      'reason', 'version_conflict',
      'current_version', current_version.version
    );
  end if;

  if jsonb_typeof(persona_identity) <> 'object'
    or jsonb_typeof(persona_biography) <> 'object'
    or jsonb_typeof(persona_style_rules) <> 'object'
    or jsonb_typeof(persona_instructions) <> 'object' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_payload');
  end if;

  if not actor_is_owner and persona_identity <> current_version.identity then
    perform private.append_context_audit(
      actor.organization_id,
      target_operation_id,
      auth.uid(),
      'context.persona_identity_change_denied',
      'persona_version',
      current_version.id,
      current_version.identity,
      jsonb_build_object('reason', 'owner_only'),
      request_trace_id,
      request_correlation_id
    );
    return jsonb_build_object('ok', false, 'reason', 'identity_owner_only');
  end if;

  update public.persona_versions
  set
    identity = persona_identity,
    biography = persona_biography,
    style_rules = persona_style_rules,
    instructions = persona_instructions,
    status = 'draft',
    validation_errors = '[]'::jsonb,
    diff_snapshot = null,
    content_hash = null,
    validated_by_user_id = null,
    validated_at = null,
    updated_at = now(),
    version = version + 1
  where id = current_version.id;

  perform private.append_context_audit(
    actor.organization_id,
    target_operation_id,
    auth.uid(),
    'context.persona_draft_saved',
    'persona_version',
    current_version.id,
    jsonb_build_object(
      'version', current_version.version,
      'status', current_version.status
    ),
    jsonb_build_object(
      'version', current_version.version + 1,
      'status', 'draft',
      'identity_changed', persona_identity <> current_version.identity
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'ok', true,
    'version', current_version.version + 1
  );
end;
$$;

create or replace function private.validate_context_drafts(
  target_operation_id uuid,
  factual_version_id uuid,
  factual_expected_version bigint,
  behavioral_version_id uuid,
  behavioral_expected_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  factual public.institutional_profile_versions%rowtype;
  behavioral public.persona_versions%rowtype;
  factual_baseline jsonb := '{}'::jsonb;
  behavioral_baseline jsonb := '{}'::jsonb;
  factual_errors jsonb;
  behavioral_errors jsonb;
  factual_hash text;
  behavioral_hash text;
begin
  if auth.uid() is null or not private.can_read_context(target_operation_id) then
    raise exception 'context validation permission denied'
      using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);

  select profile.*
  into strict factual
  from public.institutional_profile_versions as profile
  where profile.id = factual_version_id
    and profile.operation_id = target_operation_id
    and profile.organization_id = actor.organization_id
    and profile.status in ('draft', 'validating')
  for update;

  select persona_version.*
  into strict behavioral
  from public.persona_versions as persona_version
  where persona_version.id = behavioral_version_id
    and persona_version.operation_id = target_operation_id
    and persona_version.organization_id = actor.organization_id
    and persona_version.status in ('draft', 'validating')
  for update;

  if factual.version <> factual_expected_version
    or behavioral.version <> behavioral_expected_version then
    return jsonb_build_object('ok', false, 'reason', 'version_conflict');
  end if;

  if factual.baseline_version_id is not null then
    select profile.fields
    into factual_baseline
    from public.institutional_profile_versions as profile
    where profile.id = factual.baseline_version_id;
  end if;

  if behavioral.baseline_version_id is not null then
    select jsonb_build_object(
      'identity', persona_version.identity,
      'biography', persona_version.biography,
      'style_rules', persona_version.style_rules,
      'instructions', persona_version.instructions
    )
    into behavioral_baseline
    from public.persona_versions as persona_version
    where persona_version.id = behavioral.baseline_version_id;
  end if;

  factual_errors := private.profile_validation_errors(factual.fields);
  behavioral_errors := private.persona_validation_errors(
    behavioral.identity,
    behavioral.biography,
    behavioral.style_rules,
    behavioral.instructions
  );
  factual_hash := encode(
    sha256(convert_to(factual.fields::text, 'UTF8')),
    'hex'
  );
  behavioral_hash := encode(
    sha256(
      convert_to(
        jsonb_build_object(
          'identity', behavioral.identity,
          'biography', behavioral.biography,
          'style_rules', behavioral.style_rules,
          'instructions', behavioral.instructions
        )::text,
        'UTF8'
      )
    ),
    'hex'
  );

  update public.institutional_profile_versions
  set
    status = 'validating',
    validation_errors = factual_errors,
    diff_snapshot = jsonb_build_object(
      'before', factual_baseline,
      'after', factual.fields
    ),
    content_hash = factual_hash,
    validated_by_user_id = auth.uid(),
    validated_at = now(),
    updated_at = now(),
    version = version + 1
  where id = factual.id;

  update public.persona_versions
  set
    status = 'validating',
    validation_errors = behavioral_errors,
    diff_snapshot = jsonb_build_object(
      'before', behavioral_baseline,
      'after', jsonb_build_object(
        'identity', behavioral.identity,
        'biography', behavioral.biography,
        'style_rules', behavioral.style_rules,
        'instructions', behavioral.instructions
      )
    ),
    content_hash = behavioral_hash,
    validated_by_user_id = auth.uid(),
    validated_at = now(),
    updated_at = now(),
    version = version + 1
  where id = behavioral.id;

  perform private.append_context_audit(
    actor.organization_id,
    target_operation_id,
    auth.uid(),
    'context.drafts_validated',
    'operation',
    target_operation_id,
    jsonb_build_object(
      'factual_version', factual.version,
      'behavioral_version', behavioral.version
    ),
    jsonb_build_object(
      'factual_version', factual.version + 1,
      'behavioral_version', behavioral.version + 1,
      'factual_errors', factual_errors,
      'behavioral_errors', behavioral_errors
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'ok', jsonb_array_length(factual_errors) = 0
      and jsonb_array_length(behavioral_errors) = 0,
    'reason',
      case
        when jsonb_array_length(factual_errors) = 0
          and jsonb_array_length(behavioral_errors) = 0
          then null
        else 'validation_failed'
      end,
    'factual_errors', factual_errors,
    'behavioral_errors', behavioral_errors,
    'factual_version', factual.version + 1,
    'behavioral_version', behavioral.version + 1
  );
end;
$$;

revoke all on function private.save_institutional_profile_draft(
  uuid, uuid, bigint, jsonb, uuid, uuid
) from public;
revoke all on function private.save_persona_draft(
  uuid, uuid, bigint, jsonb, jsonb, jsonb, jsonb, uuid, uuid
) from public;
revoke all on function private.validate_context_drafts(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) from public;
grant execute on function private.save_institutional_profile_draft(
  uuid, uuid, bigint, jsonb, uuid, uuid
) to authenticated;
grant execute on function private.save_persona_draft(
  uuid, uuid, bigint, jsonb, jsonb, jsonb, jsonb, uuid, uuid
) to authenticated;
grant execute on function private.validate_context_drafts(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) to authenticated;

create or replace function private.production_readiness(
  target_operation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  publication public.context_publications%rowtype;
  fields jsonb;
  identity jsonb;
  errors jsonb := '[]'::jsonb;
  warnings jsonb := '[]'::jsonb;
  optional_key text;
begin
  select context_publication.*
  into publication
  from public.operation_settings as settings
  join public.context_publications as context_publication
    on context_publication.id = settings.active_context_publication_id
    and context_publication.organization_id = settings.organization_id
  where settings.operation_id = target_operation_id;

  if publication.id is null then
    return jsonb_build_object(
      'ready', false,
      'errors', jsonb_build_array('Publique o Contexto inicial.'),
      'warnings', '[]'::jsonb
    );
  end if;

  fields := publication.factual_snapshot;
  identity := publication.behavioral_snapshot -> 'identity';

  if nullif(btrim(fields -> 'trade_name' ->> 'value'), '') is null then
    errors := errors || jsonb_build_array('Informe o nome comercial.');
  end if;
  if nullif(btrim(fields -> 'creci_pj' ->> 'value'), '') is null then
    errors := errors || jsonb_build_array('Informe o CRECI PJ.');
  end if;
  if nullif(btrim(fields -> 'creci_uf' ->> 'value'), '') is null then
    errors := errors || jsonb_build_array('Informe a UF do CRECI PJ.');
  end if;
  if nullif(btrim(identity ->> 'full_name'), '') is null then
    errors := errors || jsonb_build_array(
      'Informe o nome completo da Persona ativa.'
    );
  end if;
  if coalesce((identity ->> 'presents_as_broker')::boolean, false)
    and nullif(btrim(identity ->> 'creci'), '') is null then
    errors := errors || jsonb_build_array(
      'Informe o CRECI da Persona ativa.'
    );
  end if;
  if coalesce((identity ->> 'presents_as_broker')::boolean, false)
    and nullif(btrim(identity ->> 'creci_uf'), '') is null then
    errors := errors || jsonb_build_array(
      'Informe a UF do CRECI da Persona ativa.'
    );
  end if;

  foreach optional_key in array array[
    'legal_name', 'cnpj', 'address', 'phone', 'website', 'instagram',
    'email', 'business_hours', 'privacy_contact'
  ]::text[]
  loop
    if nullif(btrim(fields -> optional_key ->> 'value'), '') is null then
      warnings := warnings || jsonb_build_array(
        format('Campo opcional incompleto: %s.', optional_key)
      );
    end if;
  end loop;

  return jsonb_build_object(
    'ready', jsonb_array_length(errors) = 0,
    'errors', errors,
    'warnings', warnings,
    'publication_id', publication.id
  );
exception
  when invalid_text_representation then
    return jsonb_build_object(
      'ready', false,
      'errors', jsonb_build_array('Revise a identidade publicada.'),
      'warnings', warnings
    );
end;
$$;

revoke all on function private.production_readiness(uuid) from public;
grant execute on function private.production_readiness(uuid) to authenticated;

create or replace function private.publish_context(
  target_operation_id uuid,
  factual_version_id uuid,
  factual_expected_version bigint,
  behavioral_version_id uuid,
  behavioral_expected_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  settings public.operation_settings%rowtype;
  factual public.institutional_profile_versions%rowtype;
  behavioral public.persona_versions%rowtype;
  previous_publication public.context_publications%rowtype;
  publication_id uuid;
  next_publication_number bigint;
  behavioral_snapshot jsonb;
  combined_hash text;
  actor_is_owner boolean;
  baseline_factual public.institutional_profile_versions%rowtype;
  baseline_behavioral public.persona_versions%rowtype;
begin
  if auth.uid() is null or not private.can_read_context(target_operation_id) then
    raise exception 'context publication permission denied'
      using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);
  actor_is_owner := private.is_owner_for_operation(target_operation_id);

  select operation_settings.*
  into strict settings
  from public.operation_settings as operation_settings
  where operation_settings.operation_id = target_operation_id
    and operation_settings.organization_id = actor.organization_id
  for update;

  select profile.*
  into strict factual
  from public.institutional_profile_versions as profile
  where profile.id = factual_version_id
    and profile.operation_id = target_operation_id
    and profile.organization_id = actor.organization_id
  for update;

  select persona_version.*
  into strict behavioral
  from public.persona_versions as persona_version
  where persona_version.id = behavioral_version_id
    and persona_version.operation_id = target_operation_id
    and persona_version.organization_id = actor.organization_id
  for update;

  if factual.status <> 'validating'
    or behavioral.status <> 'validating'
    or factual.version <> factual_expected_version
    or behavioral.version <> behavioral_expected_version then
    return jsonb_build_object('ok', false, 'reason', 'version_conflict');
  end if;

  if jsonb_array_length(factual.validation_errors) > 0
    or jsonb_array_length(behavioral.validation_errors) > 0
    or factual.content_hash is null
    or behavioral.content_hash is null then
    return jsonb_build_object('ok', false, 'reason', 'validation_required');
  end if;

  if not actor_is_owner then
    if factual.baseline_version_id is null
      or behavioral.baseline_version_id is null then
      return jsonb_build_object(
        'ok', false,
        'reason', 'initial_identity_owner_only'
      );
    end if;

    select profile.*
    into strict baseline_factual
    from public.institutional_profile_versions as profile
    where profile.id = factual.baseline_version_id;

    select persona_version.*
    into strict baseline_behavioral
    from public.persona_versions as persona_version
    where persona_version.id = behavioral.baseline_version_id;

    if behavioral.identity <> baseline_behavioral.identity then
      return jsonb_build_object(
        'ok', false,
        'reason', 'identity_owner_only'
      );
    end if;

    if factual.fields <> baseline_factual.fields
      and not private.has_membership_permission(
        target_operation_id,
        'publish_knowledge'
      ) then
      return jsonb_build_object(
        'ok', false,
        'reason', 'publish_knowledge_required'
      );
    end if;

    if (
      behavioral.biography <> baseline_behavioral.biography
      or behavioral.style_rules <> baseline_behavioral.style_rules
      or behavioral.instructions <> baseline_behavioral.instructions
    ) and not private.has_membership_permission(
      target_operation_id,
      'publish_learning'
    ) then
      return jsonb_build_object(
        'ok', false,
        'reason', 'publish_learning_required'
      );
    end if;
  end if;

  if settings.active_context_publication_id is not null then
    select context_publication.*
    into strict previous_publication
    from public.context_publications as context_publication
    where context_publication.id = settings.active_context_publication_id
      and context_publication.organization_id = actor.organization_id;

    update public.institutional_profile_versions
    set
      status = 'archived',
      archived_by_user_id = auth.uid(),
      archived_at = now(),
      updated_at = now(),
      version = version + 1
    where id = previous_publication.factual_version_id
      and status = 'published';

    update public.persona_versions
    set
      status = 'archived',
      archived_by_user_id = auth.uid(),
      archived_at = now(),
      updated_at = now(),
      version = version + 1
    where id = previous_publication.behavioral_version_id
      and status = 'published';
  end if;

  behavioral_snapshot := jsonb_build_object(
    'identity', behavioral.identity,
    'biography', behavioral.biography,
    'style_rules', behavioral.style_rules,
    'instructions', behavioral.instructions
  );
  combined_hash := encode(
    sha256(
      convert_to(
        factual.content_hash || ':' || behavioral.content_hash,
        'UTF8'
      )
    ),
    'hex'
  );

  update public.institutional_profile_versions
  set
    status = 'published',
    published_by_user_id = auth.uid(),
    published_at = now(),
    updated_at = now(),
    version = version + 1
  where id = factual.id;

  update public.persona_versions
  set
    status = 'published',
    published_by_user_id = auth.uid(),
    published_at = now(),
    updated_at = now(),
    version = version + 1
  where id = behavioral.id;

  select coalesce(max(context_publication.publication_number), 0) + 1
  into next_publication_number
  from public.context_publications as context_publication
  where context_publication.operation_id = target_operation_id;

  insert into public.context_publications (
    organization_id,
    operation_id,
    publication_number,
    behavioral_version_id,
    factual_version_id,
    behavioral_snapshot,
    factual_snapshot,
    behavioral_hash,
    factual_hash,
    combined_hash,
    published_by_user_id
  )
  values (
    actor.organization_id,
    target_operation_id,
    next_publication_number,
    behavioral.id,
    factual.id,
    behavioral_snapshot,
    factual.fields,
    behavioral.content_hash,
    factual.content_hash,
    combined_hash,
    auth.uid()
  )
  returning id into publication_id;

  update public.operation_settings
  set
    active_context_publication_id = publication_id,
    updated_at = now(),
    version = version + 1
  where operation_id = target_operation_id;

  perform private.append_context_audit(
    actor.organization_id,
    target_operation_id,
    auth.uid(),
    'context.published',
    'context_publication',
    publication_id,
    case
      when previous_publication.id is null then null
      else jsonb_build_object(
        'publication_id', previous_publication.id,
        'behavioral_version_id', previous_publication.behavioral_version_id,
        'factual_version_id', previous_publication.factual_version_id
      )
    end,
    jsonb_build_object(
      'publication_number', next_publication_number,
      'behavioral_version_id', behavioral.id,
      'factual_version_id', factual.id,
      'behavioral_hash', behavioral.content_hash,
      'factual_hash', factual.content_hash,
      'combined_hash', combined_hash
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'ok', true,
    'publication_id', publication_id,
    'publication_number', next_publication_number
  );
end;
$$;

create or replace function private.create_context_drafts(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  current_publication public.context_publications%rowtype;
  published_behavioral public.persona_versions%rowtype;
  published_factual public.institutional_profile_versions%rowtype;
  factual_id uuid;
  behavioral_id uuid;
begin
  if auth.uid() is null or not private.can_read_context(target_operation_id) then
    raise exception 'context draft permission denied' using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);

  if exists (
    select 1
    from public.institutional_profile_versions as profile
    where profile.operation_id = target_operation_id
      and profile.status in ('draft', 'validating')
  ) or exists (
    select 1
    from public.persona_versions as persona_version
    where persona_version.operation_id = target_operation_id
      and persona_version.status in ('draft', 'validating')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'draft_already_exists');
  end if;

  select context_publication.*
  into strict current_publication
  from public.operation_settings as settings
  join public.context_publications as context_publication
    on context_publication.id = settings.active_context_publication_id
    and context_publication.organization_id = settings.organization_id
  where settings.operation_id = target_operation_id
    and settings.organization_id = actor.organization_id;

  select persona_version.*
  into strict published_behavioral
  from public.persona_versions as persona_version
  where persona_version.id = current_publication.behavioral_version_id;

  select profile.*
  into strict published_factual
  from public.institutional_profile_versions as profile
  where profile.id = current_publication.factual_version_id;

  insert into public.institutional_profile_versions (
    organization_id,
    operation_id,
    version_number,
    fields,
    baseline_version_id,
    created_by_user_id
  )
  select
    actor.organization_id,
    target_operation_id,
    coalesce(max(profile.version_number), 0) + 1,
    published_factual.fields,
    published_factual.id,
    auth.uid()
  from public.institutional_profile_versions as profile
  where profile.operation_id = target_operation_id
  returning id into factual_id;

  insert into public.persona_versions (
    organization_id,
    operation_id,
    persona_id,
    version_number,
    identity,
    biography,
    style_rules,
    instructions,
    baseline_version_id,
    created_by_user_id
  )
  select
    actor.organization_id,
    target_operation_id,
    published_behavioral.persona_id,
    coalesce(max(persona_version.version_number), 0) + 1,
    published_behavioral.identity,
    published_behavioral.biography,
    published_behavioral.style_rules,
    published_behavioral.instructions,
    published_behavioral.id,
    auth.uid()
  from public.persona_versions as persona_version
  where persona_version.persona_id = published_behavioral.persona_id
  returning id into behavioral_id;

  perform private.append_context_audit(
    actor.organization_id,
    target_operation_id,
    auth.uid(),
    'context.drafts_created',
    'context_publication',
    current_publication.id,
    null,
    jsonb_build_object(
      'factual_version_id', factual_id,
      'behavioral_version_id', behavioral_id
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'ok', true,
    'factual_version_id', factual_id,
    'behavioral_version_id', behavioral_id
  );
end;
$$;

create or replace function private.archive_context_drafts(
  target_operation_id uuid,
  factual_version_id uuid,
  behavioral_version_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
begin
  if auth.uid() is null or not private.can_read_context(target_operation_id) then
    raise exception 'context archive permission denied' using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);

  update public.institutional_profile_versions
  set
    status = 'archived',
    archived_by_user_id = auth.uid(),
    archived_at = now(),
    updated_at = now(),
    version = version + 1
  where id = factual_version_id
    and organization_id = actor.organization_id
    and operation_id = target_operation_id
    and status in ('draft', 'validating');

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'factual_not_open');
  end if;

  update public.persona_versions
  set
    status = 'archived',
    archived_by_user_id = auth.uid(),
    archived_at = now(),
    updated_at = now(),
    version = version + 1
  where id = behavioral_version_id
    and organization_id = actor.organization_id
    and operation_id = target_operation_id
    and status in ('draft', 'validating');

  if not found then
    raise exception 'behavioral context is not open' using errcode = '55000';
  end if;

  perform private.append_context_audit(
    actor.organization_id,
    target_operation_id,
    auth.uid(),
    'context.drafts_archived',
    'operation',
    target_operation_id,
    null,
    jsonb_build_object(
      'factual_version_id', factual_version_id,
      'behavioral_version_id', behavioral_version_id
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function private.production_readiness(uuid) from public;
revoke all on function private.publish_context(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) from public;
revoke all on function private.create_context_drafts(uuid, uuid, uuid)
  from public;
revoke all on function private.archive_context_drafts(
  uuid, uuid, uuid, uuid, uuid
) from public;
grant execute on function private.publish_context(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) to authenticated;
grant execute on function private.create_context_drafts(uuid, uuid, uuid)
  to authenticated;
grant execute on function private.archive_context_drafts(
  uuid, uuid, uuid, uuid, uuid
) to authenticated;

create or replace function private.get_context_workspace(
  target_operation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor public.memberships%rowtype;
  result jsonb;
begin
  if auth.uid() is null or not private.can_read_context(target_operation_id) then
    raise exception 'context read permission denied' using errcode = '42501';
  end if;

  actor := private.operation_actor(target_operation_id);

  select jsonb_build_object(
    'actor', jsonb_build_object(
      'is_owner', private.is_owner_for_operation(target_operation_id),
      'can_edit_institutional',
        private.has_membership_permission(
          target_operation_id,
          'publish_knowledge'
        ),
      'can_edit_persona',
        private.has_membership_permission(target_operation_id, 'train_pedro'),
      'can_publish_learning',
        private.has_membership_permission(
          target_operation_id,
          'publish_learning'
        )
    ),
    'production_enabled', settings.production_enabled,
    'readiness', private.production_readiness(target_operation_id),
    'active_publication', (
      select jsonb_build_object(
        'id', publication.id,
        'publication_number', publication.publication_number,
        'behavioral_version_id', publication.behavioral_version_id,
        'factual_version_id', publication.factual_version_id,
        'behavioral_hash', publication.behavioral_hash,
        'factual_hash', publication.factual_hash,
        'combined_hash', publication.combined_hash,
        'published_by_user_id', publication.published_by_user_id,
        'published_at', publication.published_at
      )
      from public.context_publications as publication
      where publication.id = settings.active_context_publication_id
    ),
    'factual_draft', (
      select jsonb_build_object(
        'id', profile.id,
        'version_number', profile.version_number,
        'status', profile.status,
        'fields', profile.fields,
        'validation_errors', profile.validation_errors,
        'diff_snapshot', profile.diff_snapshot,
        'content_hash', profile.content_hash,
        'created_by_user_id', profile.created_by_user_id,
        'validated_by_user_id', profile.validated_by_user_id,
        'validated_at', profile.validated_at,
        'version', profile.version
      )
      from public.institutional_profile_versions as profile
      where profile.operation_id = target_operation_id
        and profile.organization_id = actor.organization_id
        and profile.status in ('draft', 'validating')
      order by profile.created_at desc
      limit 1
    ),
    'behavioral_draft', (
      select jsonb_build_object(
        'id', persona_version.id,
        'persona_id', persona_version.persona_id,
        'version_number', persona_version.version_number,
        'status', persona_version.status,
        'identity', persona_version.identity,
        'biography', persona_version.biography,
        'style_rules', persona_version.style_rules,
        'instructions', persona_version.instructions,
        'validation_errors', persona_version.validation_errors,
        'diff_snapshot', persona_version.diff_snapshot,
        'content_hash', persona_version.content_hash,
        'created_by_user_id', persona_version.created_by_user_id,
        'validated_by_user_id', persona_version.validated_by_user_id,
        'validated_at', persona_version.validated_at,
        'version', persona_version.version
      )
      from public.persona_versions as persona_version
      where persona_version.operation_id = target_operation_id
        and persona_version.organization_id = actor.organization_id
        and persona_version.status in ('draft', 'validating')
      order by persona_version.created_at desc
      limit 1
    ),
    'history', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', publication.id,
            'publication_number', publication.publication_number,
            'behavioral_version_id', publication.behavioral_version_id,
            'factual_version_id', publication.factual_version_id,
            'combined_hash', publication.combined_hash,
            'published_by_user_id', publication.published_by_user_id,
            'published_at', publication.published_at
          )
          order by publication.publication_number desc
        )
        from public.context_publications as publication
        where publication.operation_id = target_operation_id
          and publication.organization_id = actor.organization_id
      ),
      '[]'::jsonb
    )
  )
  into result
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id
    and settings.organization_id = actor.organization_id;

  return result;
end;
$$;

revoke all on function private.get_context_workspace(uuid) from public;
grant execute on function private.get_context_workspace(uuid) to authenticated;

create or replace function private.set_context_production_after_reauthentication(
  actor_user_id uuid,
  target_operation_id uuid,
  enable_production boolean,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  owner_membership public.memberships%rowtype;
  readiness jsonb;
  before_enabled boolean;
begin
  if not private.is_service_role() then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select membership.*
  into strict owner_membership
  from public.memberships as membership
  join public.membership_roles as membership_role
    on membership_role.membership_id = membership.id
    and membership_role.organization_id = membership.organization_id
    and membership_role.role = 'owner'
  join public.membership_operations as membership_operation
    on membership_operation.membership_id = membership.id
    and membership_operation.organization_id = membership.organization_id
    and membership_operation.operation_id = target_operation_id
  where membership.user_id = actor_user_id
    and membership.status = 'active';

  select settings.production_enabled
  into strict before_enabled
  from public.operation_settings as settings
  where settings.operation_id = target_operation_id
    and settings.organization_id = owner_membership.organization_id
  for update;

  readiness := private.production_readiness(target_operation_id);

  if enable_production and not coalesce((readiness ->> 'ready')::boolean, false) then
    perform private.append_context_audit(
      owner_membership.organization_id,
      target_operation_id,
      actor_user_id,
      'context.production_enable_denied',
      'operation',
      target_operation_id,
      jsonb_build_object('production_enabled', before_enabled),
      readiness,
      request_trace_id,
      request_correlation_id
    );
    return jsonb_build_object(
      'ok', false,
      'reason', 'production_gate',
      'readiness', readiness
    );
  end if;

  update public.operation_settings
  set
    production_enabled = enable_production,
    updated_at = now(),
    version = version + 1
  where operation_id = target_operation_id
    and organization_id = owner_membership.organization_id;

  perform private.append_context_audit(
    owner_membership.organization_id,
    target_operation_id,
    actor_user_id,
    case
      when enable_production
        then 'context.production_enabled'
      else 'context.production_disabled'
    end,
    'operation',
    target_operation_id,
    jsonb_build_object('production_enabled', before_enabled),
    jsonb_build_object(
      'production_enabled', enable_production,
      'readiness', readiness
    ),
    request_trace_id,
    request_correlation_id
  );

  return jsonb_build_object(
    'ok', true,
    'production_enabled', enable_production,
    'readiness', readiness
  );
end;
$$;

revoke all on function private.set_context_production_after_reauthentication(
  uuid, uuid, boolean, uuid, uuid
) from public;
grant execute on function private.set_context_production_after_reauthentication(
  uuid, uuid, boolean, uuid, uuid
) to service_role;

create function public.get_context_workspace(target_operation_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_context_workspace(target_operation_id);
$$;

create function public.initialize_context_drafts(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.initialize_context_drafts(
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );
$$;

create function public.save_institutional_profile_draft(
  target_operation_id uuid,
  target_version_id uuid,
  expected_version bigint,
  profile_fields jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.save_institutional_profile_draft(
    target_operation_id,
    target_version_id,
    expected_version,
    profile_fields,
    request_trace_id,
    request_correlation_id
  );
$$;

create function public.save_persona_draft(
  target_operation_id uuid,
  target_version_id uuid,
  expected_version bigint,
  persona_identity jsonb,
  persona_biography jsonb,
  persona_style_rules jsonb,
  persona_instructions jsonb,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.save_persona_draft(
    target_operation_id,
    target_version_id,
    expected_version,
    persona_identity,
    persona_biography,
    persona_style_rules,
    persona_instructions,
    request_trace_id,
    request_correlation_id
  );
$$;

create function public.validate_context_drafts(
  target_operation_id uuid,
  factual_version_id uuid,
  factual_expected_version bigint,
  behavioral_version_id uuid,
  behavioral_expected_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.validate_context_drafts(
    target_operation_id,
    factual_version_id,
    factual_expected_version,
    behavioral_version_id,
    behavioral_expected_version,
    request_trace_id,
    request_correlation_id
  );
$$;

create function public.publish_context(
  target_operation_id uuid,
  factual_version_id uuid,
  factual_expected_version bigint,
  behavioral_version_id uuid,
  behavioral_expected_version bigint,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.publish_context(
    target_operation_id,
    factual_version_id,
    factual_expected_version,
    behavioral_version_id,
    behavioral_expected_version,
    request_trace_id,
    request_correlation_id
  );
$$;

create function public.create_context_drafts(
  target_operation_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.create_context_drafts(
    target_operation_id,
    request_trace_id,
    request_correlation_id
  );
$$;

create function public.archive_context_drafts(
  target_operation_id uuid,
  factual_version_id uuid,
  behavioral_version_id uuid,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.archive_context_drafts(
    target_operation_id,
    factual_version_id,
    behavioral_version_id,
    request_trace_id,
    request_correlation_id
  );
$$;

create function public.set_context_production_after_reauthentication(
  actor_user_id uuid,
  target_operation_id uuid,
  enable_production boolean,
  request_trace_id uuid,
  request_correlation_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.set_context_production_after_reauthentication(
    actor_user_id,
    target_operation_id,
    enable_production,
    request_trace_id,
    request_correlation_id
  );
$$;

revoke all on function public.get_context_workspace(uuid) from public;
revoke all on function public.initialize_context_drafts(uuid, uuid, uuid)
  from public;
revoke all on function public.save_institutional_profile_draft(
  uuid, uuid, bigint, jsonb, uuid, uuid
) from public;
revoke all on function public.save_persona_draft(
  uuid, uuid, bigint, jsonb, jsonb, jsonb, jsonb, uuid, uuid
) from public;
revoke all on function public.validate_context_drafts(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) from public;
revoke all on function public.publish_context(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) from public;
revoke all on function public.create_context_drafts(uuid, uuid, uuid)
  from public;
revoke all on function public.archive_context_drafts(
  uuid, uuid, uuid, uuid, uuid
) from public;
revoke all on function public.set_context_production_after_reauthentication(
  uuid, uuid, boolean, uuid, uuid
) from public;

grant execute on function public.get_context_workspace(uuid) to authenticated;
grant execute on function public.initialize_context_drafts(uuid, uuid, uuid)
  to authenticated;
grant execute on function public.save_institutional_profile_draft(
  uuid, uuid, bigint, jsonb, uuid, uuid
) to authenticated;
grant execute on function public.save_persona_draft(
  uuid, uuid, bigint, jsonb, jsonb, jsonb, jsonb, uuid, uuid
) to authenticated;
grant execute on function public.validate_context_drafts(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) to authenticated;
grant execute on function public.publish_context(
  uuid, uuid, bigint, uuid, bigint, uuid, uuid
) to authenticated;
grant execute on function public.create_context_drafts(uuid, uuid, uuid)
  to authenticated;
grant execute on function public.archive_context_drafts(
  uuid, uuid, uuid, uuid, uuid
) to authenticated;
grant execute on function public.set_context_production_after_reauthentication(
  uuid, uuid, boolean, uuid, uuid
) to service_role;

comment on table public.institutional_profile_versions is
  'Versões factuais do perfil institucional. Cada campo conserva fonte, conferência, validade e divulgação.';
comment on table public.persona_versions is
  'Versões comportamentais imutáveis após publicação: identidade, biografia, estilo e instruções.';
comment on table public.context_publications is
  'Publicação transacional que vincula exatamente uma versão comportamental e uma factual.';
comment on column public.institutional_profile_versions.fields is
  'Mapa por campo com value, source, confirmed_at, valid_until, public_source_url, disclosure e confirmed_by_owner.';
