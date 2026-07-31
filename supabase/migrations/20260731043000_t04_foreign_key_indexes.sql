-- Cover the composite foreign keys introduced by T04 hardening.
--
-- Partial operational indexes remain for hot paths; these complete indexes
-- also make parent updates/deletes predictable and satisfy the FK advisor.

create index contact_phone_observations_contact_phone_fk_idx
  on public.contact_phone_observations (
    organization_id,
    contact_id,
    contact_phone_id
  );

create index source_attributions_operation_opportunity_fk_idx
  on public.source_attributions (
    organization_id,
    operation_id,
    opportunity_id
  );

create index source_attributions_contact_opportunity_fk_idx
  on public.source_attributions (
    organization_id,
    contact_id,
    opportunity_id
  );

create index opportunity_stage_history_operation_opportunity_fk_idx
  on public.opportunity_stage_history (
    organization_id,
    operation_id,
    opportunity_id
  );

create index conversations_operation_opportunity_fk_idx
  on public.conversations (
    organization_id,
    operation_id,
    opportunity_id
  );

create index conversations_contact_opportunity_fk_idx
  on public.conversations (
    organization_id,
    contact_id,
    opportunity_id
  );

create index proactive_requests_operation_opportunity_fk_idx
  on public.proactive_approach_requests (
    organization_id,
    operation_id,
    opportunity_id
  );

create index calls_operation_opportunity_fk_idx
  on public.calls (
    organization_id,
    operation_id,
    opportunity_id
  );

create index calls_organization_assignee_fk_idx
  on public.calls (organization_id, assigned_membership_id);

create index calls_organization_opportunity_fk_idx
  on public.calls (organization_id, opportunity_id);

create index call_assignments_operation_call_fk_idx
  on public.call_assignments (
    organization_id,
    operation_id,
    call_id
  );

create index call_assignments_organization_call_fk_idx
  on public.call_assignments (organization_id, call_id);

create index call_assignments_organization_membership_fk_idx
  on public.call_assignments (organization_id, membership_id);

create index call_offers_operation_call_fk_idx
  on public.call_offers (
    organization_id,
    operation_id,
    call_id
  );

create index call_offers_organization_call_fk_idx
  on public.call_offers (organization_id, call_id);

create index call_offers_organization_operation_fk_idx
  on public.call_offers (organization_id, operation_id);

create index call_offers_organization_recipient_fk_idx
  on public.call_offers (organization_id, recipient_membership_id);

create index contact_merges_organization_merged_contact_fk_idx
  on public.contact_merges (organization_id, merged_contact_id);

create index contact_merges_organization_actor_membership_fk_idx
  on public.contact_merges (organization_id, merged_by_membership_id);

create index contact_merges_actor_user_fk_idx
  on public.contact_merges (merged_by_user_id);

create index contact_merge_reversals_operation_fk_idx
  on public.contact_merge_reversals (organization_id, operation_id);

create index contact_merge_reversals_merge_fk_idx
  on public.contact_merge_reversals (organization_id, contact_merge_id);

create index contact_merge_reversals_actor_membership_fk_idx
  on public.contact_merge_reversals (
    organization_id,
    reversed_by_membership_id
  );

create index contact_merge_reversals_actor_user_fk_idx
  on public.contact_merge_reversals (reversed_by_user_id);
