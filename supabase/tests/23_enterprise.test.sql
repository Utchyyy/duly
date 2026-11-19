-- Enterprise foundation: payments off, the vendor roster, Client access to a site, isolation between Enterprises, feature switches.

create function pg_temp.email_of(u uuid) returns text language sql security definer as $$ select email::text from auth.users where id = u $$;

-- A brief for a site, locked, ready to invite on.
create function pg_temp.brief_for(p_owner uuid, p_org uuid, p_site uuid, p_title text) returns uuid language plpgsql as $$
declare brief uuid;
begin
  perform tests.as_user(p_owner);
  insert into public.briefs (buyer_org_id, site_id, title) values (p_org, p_site, p_title) returning id into brief;
  insert into public.brief_versions (brief_id, version, visits_per_week, schedule) values (brief, 1, 1,
    '[{"name":"Clinical","areas":[{"id":"a1","name":"Surgery","minutes":60,"standards":[{"id":"s1","text":"Floors clean"},{"id":"s2","text":"Surfaces wiped"}]},{"id":"a2","name":"Reception","minutes":30,"standards":[{"id":"s3","text":"Bins empty"}]}]}]'::jsonb);
  update public.brief_versions set locked_at = now(), locked_by = auth.uid() where brief_id = brief and version = 1;
  perform tests.as_su();
  return brief;
end $$;

do $$
declare
  admin_u uuid := tests.mk_user('admin'); owner1 uuid := tests.mk_user('ent1-owner'); owner2 uuid := tests.mk_user('ent2-owner');
  vend_u uuid := tests.mk_user('vendor-admin'); vend2_u uuid := tests.mk_user('other-vendor-admin'); crew uuid := tests.mk_user('crew');
  mgr uuid := tests.mk_user('client-manager'); viewer uuid := tests.mk_user('client-viewer'); stranger uuid := tests.mk_user('stranger');
  duly_org uuid; ent1 uuid; ent2 uuid; vend uuid; vend2 uuid; site1 uuid; site2 uuid; brief uuid; brief2 uuid; brief3 uuid; quote uuid; quote2 uuid; job uuid;
  n bigint; r record; v_total numeric; v_lines jsonb;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  insert into public.memberships values (duly_org, admin_u, 'platform_admin');

  -- Duly staff set an Enterprise and two vendors up.
  perform tests.as_user(owner1);
  perform tests.throws(format('select public.admin_create_enterprise(%L, %L)', 'Nope', pg_temp.email_of(owner1)), '%Only Duly staff%', 'only Duly staff create an Enterprise');
  perform tests.throws(format('select public.admin_create_vendor(%L, %L)', 'Nope', pg_temp.email_of(owner1)), '%Only Duly staff%', 'or a vendor');
  perform tests.as_user(admin_u);
  perform tests.throws(format('select public.admin_create_enterprise(%L, %L)', 'Ghost', 'nobody@nowhere.invalid'), '%No account for%', 'an owner needs an account first');
  ent1 := public.admin_create_enterprise('Soft FM One', pg_temp.email_of(owner1));
  ent2 := public.admin_create_enterprise('Soft FM Two', pg_temp.email_of(owner2));
  vend := public.admin_create_vendor('Vendor Co', pg_temp.email_of(vend_u));
  vend2 := public.admin_create_vendor('Other Vendor Co', pg_temp.email_of(vend2_u));
  perform tests.as_su();
  insert into public.memberships values (vend, crew, 'operative');
  perform tests.eq((select segment || ':' || kind from public.organisations where id = ent1), 'enterprise:buyer', 'an Enterprise is a buyer organisation in the enterprise segment');
  perform tests.eq((select role::text from public.memberships where org_id = ent1 and user_id = owner1), 'owner', 'with its owner');
  perform tests.eq((select payment_model from public.policies where market = 'UK' and segment = 'enterprise'), 'external', 'whose payments are external: invoicing is outside Duly');

  -- Sites and a brief for each Enterprise.
  perform tests.as_user(owner1);
  insert into public.sites (org_id, name, town, postcode, lat, lng, geofence_m) values (ent1, 'Hospital Wing', 'Colchester', 'CO1 1AA', 51.8892, 0.9042, 150) returning id into site1;
  perform tests.as_user(owner2);
  insert into public.sites (org_id, name, town, postcode, lat, lng, geofence_m) values (ent2, 'Office Block', 'Ipswich', 'IP1 1AA', 52.0567, 1.1482, 150) returning id into site2;
  brief := pg_temp.brief_for(owner1, ent1, site1, 'Wing clean');

  -- The roster: nothing starts with a vendor the Enterprise has not accepted.
  perform tests.as_user(owner1);
  perform tests.throws(format('insert into public.quotes (brief_id, brief_version, vendor_org_id) values (%L, 1, %L)', brief, vend), '%row-level security%', 'an Enterprise cannot invite a vendor that is not on its roster');
  perform tests.throws(format('select public.enterprise_add_vendor(%L, %L)', ent1, vend), '%Only Duly staff%', 'and cannot add one itself: Duly staff do');
  perform tests.as_user(admin_u);
  perform public.enterprise_add_vendor(ent1, vend, 'Pilot vendor');
  perform public.enterprise_add_vendor(ent1, vend);   -- again: nothing changes
  perform tests.throws(format('select public.enterprise_add_vendor(%L, %L)', vend, vend2), '%not an Enterprise%', 'the first must be an Enterprise');
  perform tests.throws(format('select public.enterprise_add_vendor(%L, %L)', ent1, ent2), '%not a vendor%', 'the second must be a vendor');
  perform tests.as_su();
  perform tests.eq((select status || ':' || note from public.enterprise_vendors where enterprise_org_id = ent1 and vendor_org_id = vend), 'invited:Pilot vendor', 'a vendor added by Duly is invited');
  perform tests.as_user(owner1);
  perform tests.throws(format('insert into public.quotes (brief_id, brief_version, vendor_org_id) values (%L, 1, %L)', brief, vend), '%row-level security%', 'an invited vendor still cannot be appointed');
  perform tests.as_user(vend_u);
  perform tests.throws(format('select public.enterprise_set_vendor_status(%L, %L, %L)', ent1, vend, 'active'), '%owner or approvers%', 'a vendor cannot accept itself');
  perform tests.as_user(owner2);
  perform tests.throws(format('select public.enterprise_set_vendor_status(%L, %L, %L)', ent1, vend, 'active'), '%owner or approvers%', 'nor can another Enterprise');
  perform tests.as_user(owner1);
  perform tests.throws(format('select public.enterprise_set_vendor_status(%L, %L, %L)', ent1, vend, 'invited'), '%active or suspended%', 'a status is active or suspended');
  perform tests.throws(format('select public.enterprise_set_vendor_status(%L, %L, %L)', ent1, vend2, 'active'), '%not on this Enterprise%', 'and the vendor must be on its roster');
  perform public.enterprise_set_vendor_status(ent1, vend, 'active');
  insert into public.quotes (brief_id, brief_version, vendor_org_id) values (brief, 1, vend) returning id into quote;
  perform tests.ok(true, 'once active, the Enterprise appoints the vendor');
  perform tests.as_su();
  perform tests.eq((select count(*) from public.audit_log where table_name = 'enterprise_vendors' and vend = any (org_ids)), 2::bigint, 'adding, and activating, a vendor is on the record');

  -- Work with no price: the vendor sends, the Enterprise accepts, nothing is written to the ledger.
  perform tests.as_user(vend_u);
  select jsonb_build_object('t', (public.submit_quote(quote) ->> 'total')) into r;
  perform tests.as_su();
  select total, lines into v_total, v_lines from public.quotes where id = quote;
  perform tests.ok(v_total is null and v_lines = '[]'::jsonb, 'an enterprise quote carries no price');
  perform tests.as_user(owner1);
  job := public.accept_quote(quote, now() + interval '1 day');
  perform tests.as_su();
  perform tests.ok((select value is null from public.jobs where id = job), 'the visit has no value');
  perform tests.eq((select count(*) from public.contracts where buyer_org_id = ent1 and vendor_org_id = vend), 1::bigint, 'and a contract exists, with the Enterprise as the buyer');
  perform tests.eq((select count(*) from public.payments where job_id = job or contract_id = (select contract_id from public.jobs where id = job)), 0::bigint, 'with no escrow, charge or release lines');
  perform tests.eq((select status from public.work_schedules where quote_id = quote), 'locked', 'and the schedule built from the brief is locked');
  perform tests.as_user(vend_u); insert into public.job_assignments (job_id, user_id, role) values (job, crew, 'lead'); perform tests.as_su();

  -- A suspended vendor cannot be appointed, or have a pending quote accepted.
  brief2 := pg_temp.brief_for(owner1, ent1, site1, 'Second clean');
  brief3 := pg_temp.brief_for(owner1, ent1, site1, 'Third clean');
  perform tests.as_user(owner1);
  insert into public.quotes (brief_id, brief_version, vendor_org_id) values (brief2, 1, vend) returning id into quote2;
  perform tests.as_user(vend_u); perform public.submit_quote(quote2);
  perform tests.as_user(owner1);
  perform public.enterprise_set_vendor_status(ent1, vend, 'suspended');
  perform tests.throws(format('select public.accept_quote(%L, now() + interval ''2 days'')', quote2), '%not an active vendor on your roster%', 'a quote from a suspended vendor cannot be accepted');
  perform tests.throws(format('insert into public.quotes (brief_id, brief_version, vendor_org_id) values (%L, 1, %L)', brief3, vend), '%row-level security%', 'nor can it be invited');
  perform public.enterprise_set_vendor_status(ent1, vend, 'active');
  perform tests.as_user(owner1);
  perform public.accept_quote(quote2, now() + interval '2 days');
  perform tests.ok(true, 'active again, it can');
  perform tests.as_su();

  -- The crew do the visit; the Enterprise's approval writes no releases.
  perform tests.crew_completes(jsonb_build_object('job', job, 'crew', crew));

  -- Clients: no access, then a manager and a viewer.
  perform tests.as_user(mgr);
  select count(*) into n from public.sites; perform tests.eq(n, 0::bigint, 'a Client with no access sees no sites');
  select count(*) into n from public.jobs; perform tests.eq(n, 0::bigint, 'and no visits');
  perform tests.throws(format('select public.can_judge_job(%L)', job), '%Job not found%', 'and cannot even ask about one');
  perform tests.throws(format('select public.grant_site_access(%L, %L, %L)', site1, pg_temp.email_of(mgr), 'manager'), '%Only the owner or approvers%', 'a Client cannot give itself access');
  perform tests.as_user(owner2);
  perform tests.throws(format('select public.grant_site_access(%L, %L, %L)', site1, pg_temp.email_of(mgr), 'manager'), '%Only the owner or approvers%', 'nor can another Enterprise');
  perform tests.as_user(owner1);
  perform tests.throws(format('select public.grant_site_access(%L, %L, %L)', site1, 'nobody@nowhere.invalid', 'manager'), '%No account for%', 'access needs an account');
  perform tests.throws(format('select public.grant_site_access(%L, %L, %L)', site1, pg_temp.email_of(mgr), 'boss'), '%manager%viewer%', 'and a role of manager or viewer');
  perform public.grant_site_access(site1, pg_temp.email_of(mgr), 'manager');
  perform public.grant_site_access(site1, pg_temp.email_of(viewer), 'viewer');
  perform tests.as_su();
  perform tests.eq((select count(*) from public.audit_log where table_name = 'site_access' and changes ->> 'site_id' = site1::text), 2::bigint, 'granting access is on the record');

  perform tests.as_user(viewer);
  select count(*) into n from public.sites where id = site1; perform tests.eq(n, 1::bigint, 'a viewer sees the site');
  select count(*) into n from public.jobs where id = job; perform tests.eq(n, 1::bigint, 'and its visit');
  select count(*) into n from public.plan_results where job_id = job; perform tests.eq(n, 3::bigint, 'and what the crew ticked');
  select count(*) into n from public.evidence where job_id = job; perform tests.ok(n > 0, 'and the photos');
  select count(*) into n from public.work_schedules where quote_id = quote; perform tests.eq(n, 1::bigint, 'and the schedule');
  select count(*) into n from public.brief_versions where brief_id = brief; perform tests.eq(n, 1::bigint, 'and the specification');
  select count(*) into n from public.payments; perform tests.eq(n, 0::bigint, 'but no money');
  select count(*) into n from public.quotes; perform tests.eq(n, 0::bigint, 'no quotes');
  select count(*) into n from public.contracts; perform tests.eq(n, 0::bigint, 'and no contracts');
  select count(*) into n from public.enterprise_vendors; perform tests.eq(n, 0::bigint, 'nor the roster');
  perform tests.ok(not public.can_judge_job(job), 'a viewer cannot judge the work');
  update public.plan_results set verdict = 'met' where job_id = job; get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'and a verdict from a viewer changes nothing');
  perform tests.throws(format('select public.approve_job(%L)', job), '%Only the client%', 'nor can it approve');

  perform tests.as_user(mgr);
  perform tests.ok(public.can_judge_job(job), 'a manager can judge');
  select count(*) into n from public.payments; perform tests.eq(n, 0::bigint, 'a manager sees no money either');
  update public.plan_results set verdict = 'met' where job_id = job; get diagnostics n = row_count;
  perform tests.eq(n, 3::bigint, 'and gives verdicts like the Enterprise''s own staff');
  perform public.approve_job(job);
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = job), 'quality_verified', 'and approves the visit');
  perform tests.eq((select count(*) from public.payments where job_id = job), 0::bigint, 'which writes no releases: invoicing is outside Duly');

  -- A Client can report a problem on what it sees; access can be taken away.
  perform tests.as_user(viewer);
  insert into public.issues (job_id, kind, description) values (job, 'quality', 'Smell in the corridor');
  perform tests.ok(true, 'a viewer can report a problem');
  perform tests.as_user(owner1); perform public.revoke_site_access(site1, viewer);
  perform tests.as_user(viewer);
  select count(*) into n from public.jobs; perform tests.eq(n, 0::bigint, 'and loses sight of the site when access is taken away');

  -- Another Enterprise sees none of it.
  perform tests.as_user(owner2);
  select count(*) into n from public.sites where id = site1; perform tests.eq(n, 0::bigint, 'another Enterprise does not see the site');
  select count(*) into n from public.jobs; perform tests.eq(n, 0::bigint, 'its visits');
  select count(*) into n from public.contracts; perform tests.eq(n, 0::bigint, 'its contracts');
  select count(*) into n from public.quotes; perform tests.eq(n, 0::bigint, 'its quotes');
  select count(*) into n from public.briefs where buyer_org_id = ent1; perform tests.eq(n, 0::bigint, 'its briefs');
  select count(*) into n from public.enterprise_vendors where enterprise_org_id = ent1; perform tests.eq(n, 0::bigint, 'or its roster');
  select count(*) into n from public.site_access where site_id = site1; perform tests.eq(n, 0::bigint, 'or who has access to it');
  select count(*) into n from public.issues; perform tests.eq(n, 0::bigint, 'or its problems');

  -- A vendor sees only the roster rows that name it.
  perform tests.as_user(vend_u);
  select count(*) into n from public.enterprise_vendors; perform tests.eq(n, 1::bigint, 'a vendor sees that it is on the Enterprise''s roster');
  perform tests.as_user(vend2_u);
  select count(*) into n from public.enterprise_vendors; perform tests.eq(n, 0::bigint, 'and another vendor does not');
  perform tests.as_user(stranger);
  select count(*) into n from public.enterprise_vendors; perform tests.eq(n, 0::bigint, 'nor does a stranger');
  perform tests.as_su();
end $$;

-- Feature switches.
do $$
declare admin_u uuid; plain uuid := tests.mk_user('plain'); org uuid; n bigint;
begin
  select user_id into admin_u from public.memberships where role = 'platform_admin' limit 1;
  perform tests.eq((select count(*) from public.app_features where enabled), 3::bigint, 'three switches, all on by default');
  perform tests.as_user(plain);
  org := public.create_buyer_org('Open account', 'sme');
  perform tests.ok(org is not null, 'with buyer sign-up on, anyone can create a buyer organisation');
  perform tests.throws($q$select public.admin_set_feature('buyer_signup', false)$q$, '%Only Duly staff%', 'only Duly staff change a switch');
  perform tests.as_user(admin_u);
  perform public.admin_set_feature('buyer_signup', false);
  perform tests.throws($q$select public.admin_set_feature('nonsense', false)$q$, '%No feature%', 'and it must be a real one');
  perform tests.as_user(plain);
  perform tests.throws($q$select public.create_buyer_org('Closed', 'sme')$q$, '%by invitation%', 'with it off, new buyer organisations are by invitation');
  select count(*) into n from public.app_features where not enabled; perform tests.ok(n = 1, 'and a signed-in person can read the switches');
  perform tests.as_user(admin_u);
  perform tests.ok(public.create_buyer_org('Duly can still', 'sme') is not null, 'Duly staff still can');
  perform tests.eq((select count(*) from public.audit_log where table_name = 'app_features'), 1::bigint, 'the change is on the record');
  perform public.admin_set_feature('buyer_signup', true);
  perform tests.as_su();
end $$;
