-- The Enterprise verifies its own vendors' claims: requirements, review decisions, the compliance matrix, isolation.

create function pg_temp.email_of(u uuid) returns text language sql security definer as $$ select email::text from auth.users where id = u $$;

do $$
declare
  admin_u uuid := tests.mk_user('admin'); owner1 uuid := tests.mk_user('ent1-owner'); owner2 uuid := tests.mk_user('ent2-owner');
  vend_u uuid := tests.mk_user('vendor-admin'); stranger uuid := tests.mk_user('stranger'); approver uuid := tests.mk_user('ent1-approver'); staff uuid := tests.mk_user('ent1-staff');
  duly_org uuid; ent1 uuid; ent2 uuid; vend uuid; vend2 uuid; ch uuid; pli uuid; ch_old uuid; r record; n bigint;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  insert into public.memberships values (duly_org, admin_u, 'platform_admin');
  perform tests.as_user(admin_u);
  ent1 := public.admin_create_enterprise('Soft FM One', pg_temp.email_of(owner1));
  ent2 := public.admin_create_enterprise('Soft FM Two', pg_temp.email_of(owner2));
  vend := public.admin_create_vendor('Vendor Co', pg_temp.email_of(vend_u));
  vend2 := public.admin_create_vendor('Second Vendor Co', pg_temp.email_of(vend_u));
  perform public.enterprise_add_vendor(ent1, vend); perform public.enterprise_add_vendor(ent1, vend2);
  perform public.enterprise_add_vendor(ent2, vend);
  perform tests.as_su();
  insert into public.memberships values (ent1, approver, 'approver'), (ent1, staff, 'viewer');

  -- Requirements: owner and approvers set them; company kinds only.
  perform tests.as_user(staff);
  perform tests.throws(format('select public.enterprise_set_requirements(%L, array[''companies_house'']::public.claim_kind[])', ent1), '%owner or approvers%', 'ordinary staff cannot set requirements');
  perform tests.as_user(owner2);
  perform tests.throws(format('select public.enterprise_set_requirements(%L, array[''companies_house'']::public.claim_kind[])', ent1), '%owner or approvers%', 'another Enterprise cannot');
  perform tests.as_user(owner1);
  perform tests.throws(format('select public.enterprise_set_requirements(%L, array[''dbs'']::public.claim_kind[])', ent1), '%per person%', 'DBS is personal, not a company requirement');
  perform public.enterprise_set_requirements(ent1, array['companies_house', 'public_liability_insurance', 'companies_house']::public.claim_kind[]);
  select count(*) into n from public.enterprise_requirements where enterprise_org_id = ent1; perform tests.eq(n, 2::bigint, 'two kinds required (duplicates ignored)');
  perform tests.as_user(staff);
  select count(*) into n from public.enterprise_requirements where enterprise_org_id = ent1; perform tests.eq(n, 2::bigint, 'staff can read what is required');
  perform tests.as_user(owner2);
  select count(*) into n from public.enterprise_requirements; perform tests.eq(n, 0::bigint, 'another Enterprise sees none of it');
  perform tests.as_user(vend_u);
  select count(*) into n from public.enterprise_requirements; perform tests.eq(n, 0::bigint, 'nor does a vendor');

  -- Nothing sent yet.
  perform tests.as_user(owner1);
  select count(*) into n from public.enterprise_vendor_compliance(ent1) where state = 'not_sent'; perform tests.eq(n, 4::bigint, 'two vendors x two kinds, nothing sent');
  perform tests.as_user(owner2);
  perform tests.throws(format('select * from public.enterprise_vendor_compliance(%L)', ent1), '%Not allowed%', 'another Enterprise cannot read the matrix');
  perform tests.as_user(stranger);
  perform tests.throws(format('select * from public.enterprise_vendor_compliance(%L)', ent1), '%Not allowed%', 'nor a stranger');

  -- The vendor sends claims.
  perform tests.as_user(vend_u);
  insert into public.verification_claims (org_id, kind, reference, valid_until, status) values (vend, 'companies_house', '01234567', null, 'pending') returning id into ch;
  insert into public.verification_claims (org_id, kind, reference, valid_until, status) values (vend, 'public_liability_insurance', 'PL-1', current_date + 200, 'pending') returning id into pli;
  perform tests.as_user(owner1);
  select state into r from public.enterprise_vendor_compliance(ent1) where vendor_org_id = vend and kind = 'companies_house'; perform tests.eq(r.state, 'awaiting', 'sent but not reviewed is awaiting');

  -- Review rules.
  perform tests.as_user(staff);
  perform tests.throws(format('select public.enterprise_review_claim(%L, %L, ''accepted'')', ent1, ch), '%owner or approvers%', 'staff cannot review');
  perform tests.as_user(owner2);
  perform tests.throws(format('select public.enterprise_review_claim(%L, %L, ''accepted'')', ent1, pli), '%owner or approvers%', 'an owner of another Enterprise cannot review for this one');
  perform tests.as_user(owner1);
  perform tests.throws(format('select public.enterprise_review_claim(%L, %L, ''maybe'')', ent1, ch), '%accepted or rejected%', 'only accepted or rejected');
  perform tests.throws(format('select public.enterprise_review_claim(%L, %L, ''rejected'')', ent1, ch), '%Say why%', 'a rejection needs a reason');
  perform tests.as_user(vend_u);
  insert into public.verification_claims (org_id, kind, reference, status) values (vend2, 'iso_9001', 'x', 'pending');
  perform tests.as_su();
  delete from public.enterprise_vendors where enterprise_org_id = ent1 and vendor_org_id = vend2;
  perform tests.as_user(owner1);
  perform tests.throws(format('select public.enterprise_review_claim(%L, %L, ''accepted'')', ent1, (select id from public.verification_claims where org_id = vend2 limit 1)), '%not on this Enterprise%roster%', 'a vendor off the roster cannot be reviewed');
  perform tests.as_user(admin_u); perform public.enterprise_add_vendor(ent1, vend2); perform tests.as_su();

  perform tests.as_user(approver);
  perform public.enterprise_review_claim(ent1, ch, 'accepted', 'Seen on Companies House');
  perform tests.as_user(owner1);
  perform public.enterprise_review_claim(ent1, pli, 'rejected', 'Cover is under 5m');
  select state, note into r from public.enterprise_vendor_compliance(ent1) where vendor_org_id = vend and kind = 'companies_house'; perform tests.eq(r.state, 'accepted', 'an approver can accept');
  select state, note into r from public.enterprise_vendor_compliance(ent1) where vendor_org_id = vend and kind = 'public_liability_insurance';
  perform tests.eq(r.state, 'rejected', 'and the owner can reject'); perform tests.eq(r.note, 'Cover is under 5m', 'with the reason shown');

  -- Another Enterprise's view of the same vendor is its own.
  perform tests.as_user(owner2);
  select count(*) into n from public.enterprise_claim_reviews; perform tests.eq(n, 0::bigint, 'the other Enterprise cannot see these decisions');
  perform tests.as_user(vend_u);
  select count(*) into n from public.enterprise_claim_reviews; perform tests.eq(n, 2::bigint, 'the vendor sees what was said about its own claims');
  select count(*) into n from public.enterprise_claim_reviews where decision = 'rejected' and note is not null; perform tests.eq(n, 1::bigint, 'including why one was rejected');
  perform tests.throws(format('insert into public.enterprise_claim_reviews (enterprise_org_id, claim_id, decision) values (%L, %L, ''accepted'')', ent1, pli), '%row-level security%', 'a vendor cannot write a decision for itself');
  perform tests.as_user(owner1);
  perform tests.throws(format('insert into public.enterprise_claim_reviews (enterprise_org_id, claim_id, decision) values (%L, %L, ''accepted'')', ent1, pli), '%row-level security%', 'nor can the Enterprise write directly: the function does');

  -- A change to the claim clears the decision.
  perform tests.as_user(vend_u);
  update public.verification_claims set valid_until = current_date + 365, reference = 'PL-2' where id = pli;
  select count(*) into n from public.enterprise_claim_reviews where claim_id = pli; perform tests.eq(n, 0::bigint, 'the vendor changing a claim clears the Enterprise''s decision on it');
  perform tests.as_user(owner1);
  select state into r from public.enterprise_vendor_compliance(ent1) where vendor_org_id = vend and kind = 'public_liability_insurance'; perform tests.eq(r.state, 'awaiting', 'so it waits for review again');
  perform tests.as_user(vend_u);
  update public.verification_claims set notes = 'just a note' where id = ch;
  select count(*) into n from public.enterprise_claim_reviews where claim_id = ch; perform tests.eq(n, 1::bigint, 'a note alone does not clear a decision');

  -- Expiry and the latest claim.
  perform tests.as_su();
  update public.verification_claims set valid_until = current_date - 1 where id = pli;
  perform tests.as_user(owner1);
  perform public.enterprise_review_claim(ent1, pli, 'accepted');
  select state into r from public.enterprise_vendor_compliance(ent1) where vendor_org_id = vend and kind = 'public_liability_insurance'; perform tests.eq(r.state, 'expired', 'an accepted claim past its date is expired, needing renewal');
  perform tests.as_user(vend_u);
  ch_old := ch;
  insert into public.verification_claims (org_id, kind, reference, status, created_at) values (vend, 'companies_house', '99999999', 'pending', now() + interval '1 minute') returning id into ch;
  perform tests.as_user(owner1);
  select state, reference into r from public.enterprise_vendor_compliance(ent1) where vendor_org_id = vend and kind = 'companies_house';
  perform tests.eq(r.reference, '99999999', 'the latest claim of a kind is the one that counts'); perform tests.eq(r.state, 'awaiting', 'and it waits for review');

  -- Operative claims are never reviewable here.
  perform tests.as_su();
  insert into public.verification_claims (org_id, subject_user_id, kind, reference, status) values (vend, stranger, 'dbs', 'D1', 'pending');
  perform tests.as_user(owner1);
  perform tests.throws(format('select public.enterprise_review_claim(%L, %L, ''accepted'')', ent1, (select id from public.verification_claims where kind = 'dbs')), '%not a company claim%', 'a personal claim cannot be reviewed by the Enterprise');

  -- Changing the list of requirements.
  perform public.enterprise_set_requirements(ent1, array['iso_9001']::public.claim_kind[]);
  select count(*) into n from public.enterprise_vendor_compliance(ent1); perform tests.eq(n, 2::bigint, 'replacing the list changes the matrix (two vendors, one kind)');
  perform public.enterprise_set_requirements(ent1, array[]::public.claim_kind[]);
  select count(*) into n from public.enterprise_vendor_compliance(ent1); perform tests.eq(n, 0::bigint, 'and an empty list is allowed');

  -- On the record.
  perform tests.as_su();
  select count(*) into n from public.audit_log where table_name = 'enterprise_claim_reviews'; perform tests.ok(n >= 3, 'decisions are in the audit log');
  select count(*) into n from public.audit_log where table_name = 'enterprise_requirements'; perform tests.ok(n >= 3, 'and so are the requirements');
end $$;
