-- Tell a vendor when an Enterprise rejects one of its claims.
--
-- Until now the vendor only saw an Enterprise's decision if it opened Pro > Verification. When an Enterprise rejects a claim, the vendor's
-- admin and dispatcher staff now get an inbox note (and an email unless they mute the "verification" category), so they can put it right.
-- The note names the Enterprise and the kind of claim and links to Verification. It does not repeat the reason: the reason is free text the
-- Enterprise typed, and email goes through a third party, so the note says what happened and the app shows the rest.
-- One note for each rejection: rejecting again after a fresh review notifies again. An acceptance sends nothing. A problem here is only a
-- warning and never stops the Enterprise's decision.

create function private.claim_kind_text(p_kind public.claim_kind)
returns text language sql immutable set search_path = ''
as $$
  select case p_kind
    when 'companies_house' then 'Companies House'
    when 'public_liability_insurance' then 'public liability insurance'
    when 'iso_9001' then 'ISO 9001'
    when 'chas' then 'CHAS'
    when 'safecontractor' then 'SafeContractor'
    when 'right_to_work' then 'right to work'
    when 'dbs' then 'DBS'
    else 'other' end;
$$;

create function private.notify_claim_rejection()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare c public.verification_claims;
begin
  begin
    if new.decision = 'rejected' and (tg_op = 'INSERT' or (old.decision, old.reviewed_at) is distinct from (new.decision, new.reviewed_at)) then
      select * into c from public.verification_claims where id = new.claim_id;
      if found and c.subject_user_id is null then
        perform private.notify_org(c.org_id, array['vendor_admin', 'dispatcher']::public.member_role[], 'verification', 'claim_rejected_by_enterprise',
          format('%s rejected a claim', private.org_name(new.enterprise_org_id)),
          format('%s did not accept your %s claim. Open Verification to see why and send it again.', private.org_name(new.enterprise_org_id), private.claim_kind_text(c.kind)),
          '/pro/verification', 'claim-ent-rej:' || new.id || ':' || extract(epoch from new.reviewed_at)::bigint);
      end if;
    end if;
  exception when others then
    raise warning 'notification (claim rejection) failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger enterprise_claim_reviews_notify after insert or update on public.enterprise_claim_reviews
  for each row execute function private.notify_claim_rejection();

revoke execute on function private.claim_kind_text(public.claim_kind), private.notify_claim_rejection() from public, anon, authenticated;
