-- A vendor is told when an Enterprise rejects one of its claims: who, once for each rejection, and without the reason.

create function pg_temp.email_of(u uuid) returns text language sql security definer as $$ select email::text from auth.users where id = u $$;
create function pg_temp.n(p_user uuid, p_event text) returns bigint language sql security definer as $$
  select count(*) from public.notifications where user_id = p_user and event = p_event $$;

do $$
declare
  admin_u uuid := tests.mk_user('admin'); owner1 uuid := tests.mk_user('ent1-owner'); approver uuid := tests.mk_user('ent1-approver');
  vend_u uuid := tests.mk_user('vendor-admin'); disp uuid := tests.mk_user('dispatcher'); crew uuid := tests.mk_user('crew'); vend2_u uuid := tests.mk_user('other-vendor-admin');
  duly_org uuid; ent1 uuid; vend uuid; vend2 uuid; iso uuid; dbs uuid; r record; n bigint;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  insert into public.memberships values (duly_org, admin_u, 'platform_admin');
  perform tests.as_user(admin_u);
  ent1 := public.admin_create_enterprise('Soft FM One', pg_temp.email_of(owner1));
  vend := public.admin_create_vendor('Vendor Co', pg_temp.email_of(vend_u));
  vend2 := public.admin_create_vendor('Second Vendor Co', pg_temp.email_of(vend2_u));
  perform public.enterprise_add_vendor(ent1, vend); perform public.enterprise_add_vendor(ent1, vend2);
  perform tests.as_su();
  insert into public.memberships values (ent1, approver, 'approver'), (vend, disp, 'dispatcher'), (vend, crew, 'operative');
  perform tests.as_user(vend_u);
  insert into public.verification_claims (org_id, kind, reference, status) values (vend, 'iso_9001', 'ISO-1', 'pending') returning id into iso;
  insert into public.verification_claims (org_id, kind, reference, status) values (vend, 'dbs', 'Enhanced', 'pending') returning id into dbs;
  perform tests.as_su();

  -- An acceptance sends nothing.
  perform tests.as_user(owner1);
  perform public.enterprise_review_claim(ent1, iso, 'accepted');
  perform tests.eq(pg_temp.n(vend_u, 'claim_rejected_by_enterprise'), 0::bigint, 'an acceptance sends the vendor no rejection note');

  -- A rejection tells the vendor's staff.
  perform public.enterprise_review_claim(ent1, iso, 'rejected', 'Cover is only 1m, we need 5m. Policy number SECRET-123');
  perform tests.eq(pg_temp.n(vend_u, 'claim_rejected_by_enterprise'), 1::bigint, 'the vendor admin is told');
  perform tests.eq(pg_temp.n(disp, 'claim_rejected_by_enterprise'), 1::bigint, 'and the dispatcher');
  perform tests.eq(pg_temp.n(crew, 'claim_rejected_by_enterprise'), 0::bigint, 'not a cleaner');
  perform tests.eq(pg_temp.n(owner1, 'claim_rejected_by_enterprise') + pg_temp.n(approver, 'claim_rejected_by_enterprise'), 0::bigint, 'nor anyone at the Enterprise');
  perform tests.eq(pg_temp.n(vend2_u, 'claim_rejected_by_enterprise'), 0::bigint, 'nor another vendor');
  perform tests.as_su();
  select * into r from public.notifications where user_id = vend_u and event = 'claim_rejected_by_enterprise';
  perform tests.eq(r.title, 'Soft FM One rejected a claim', 'the title names the Enterprise');
  perform tests.eq(r.body, 'Soft FM One did not accept your ISO 9001 claim. Open Verification to see why and send it again.', 'the body names the kind of claim');
  perform tests.ok(r.body not like '%Cover%' and r.body not like '%SECRET%' and r.title not like '%SECRET%', 'and does not repeat the reason');
  perform tests.eq(r.category, 'verification', 'it is in the verification category, so the existing email mute applies');
  perform tests.eq(r.link, '/pro/verification', 'it links to Verification'); perform tests.eq(r.org_id, vend, 'in the vendor''s name');
  perform tests.eq(r.email_status, 'pending', 'an email is queued by default');

  -- Saving the same rejection again, or a different note on it, is not a new rejection unless it was reviewed again.
  perform tests.as_su();
  update public.enterprise_claim_reviews set note = 'edited by hand' where claim_id = iso;
  perform tests.eq(pg_temp.n(vend_u, 'claim_rejected_by_enterprise'), 1::bigint, 'a change to the note alone sends nothing new');

  -- Rejecting again after a fresh review notifies again.
  update public.enterprise_claim_reviews set reviewed_at = reviewed_at + interval '2 minutes' where claim_id = iso;
  perform tests.eq(pg_temp.n(vend_u, 'claim_rejected_by_enterprise'), 2::bigint, 'a new review that rejects again is a new note');
  perform tests.as_user(approver);
  perform public.enterprise_review_claim(ent1, iso, 'accepted');
  perform tests.eq(pg_temp.n(vend_u, 'claim_rejected_by_enterprise'), 2::bigint, 'accepting afterwards sends no rejection note');
  -- (every review in this test shares one transaction time, so a later rejection is moved on by hand to stand for a later day)
  perform tests.as_su();
  update public.enterprise_claim_reviews set decision = 'rejected', note = 'No longer valid', reviewed_at = now() + interval '1 day' where claim_id = iso;
  perform tests.eq(pg_temp.n(vend_u, 'claim_rejected_by_enterprise'), 3::bigint, 'and rejecting again after that does');

  -- Mutes and the decision itself.
  perform tests.as_su();
  insert into public.notification_settings (user_id, email_muted) values (disp, array['verification']);
  update public.enterprise_claim_reviews set reviewed_at = reviewed_at + interval '5 minutes' where claim_id = iso;
  select email_status into r from public.notifications where user_id = disp and event = 'claim_rejected_by_enterprise' order by dedupe_key desc limit 1;
  perform tests.eq(r.email_status, 'skipped', 'someone who muted verification emails still sees it in the app but is not emailed');
  select count(*) into n from public.enterprise_claim_reviews where claim_id = iso and decision = 'rejected'; perform tests.eq(n, 1::bigint, 'and the Enterprise''s decision itself stands');
end $$;
