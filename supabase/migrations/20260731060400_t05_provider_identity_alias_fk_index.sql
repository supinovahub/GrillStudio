-- Cover the composite provider identity foreign key used for alias cleanup.

create index provider_identity_aliases_identity_fk_idx
  on public.provider_identity_aliases (
    organization_id,
    operation_id,
    connection_id,
    provider_identity_id
  );
