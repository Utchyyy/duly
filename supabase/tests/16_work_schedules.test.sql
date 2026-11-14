-- Work schedules: a vendor's plan for a brief, locked on acceptance, with complaints that name a cleaning area.
create function pg_temp.plan() returns jsonb language sql as $$
  select '{"sections":[{"id":"s1","name":"Changing room","subsections":[{"id":"s1-1","name":"Showers","brief_area_id":null,"areas":[
    {"id":"s1-1-1","name":"Shower drains","days":{"sun":"scrub","tue":"clean"}},
    {"id":"s1-1-2","name":"Cubicle walls","days":{"sun":"wash"}}]}]}]}'::jsonb
$$;
create function pg_temp.legend(p_scrub integer) returns jsonb language sql as $$
  select jsonb_build_object('scrub', jsonb_build_object('label', 'Scrub', 'minutes', p_scrub), 'wash', jsonb_build_object('label', 'Wash', 'minutes', 6),
                            'clean', jsonb_build_object('label', 'Clean', 'minutes', 3), 'mop', jsonb_build_object('label', 'Mop', 'minutes', null))
$$;

do $$
declare
  admin_u uuid := tests.mk_user('admin'); buyer_u uuid := tests.mk_user('buyer'); vendor_u uuid := tests.mk_user('vendor'); crew_u uuid := tests.mk_user('crew');
  other_crew uuid := tests.mk_user('other-crew'); other_v uuid := tests.mk_user('other-vendor-staff'); stranger_b uuid := tests.mk_user('stranger-buyer');
  duly_org uuid; vend uuid; other_vend uuid; buyer_org uuid; stranger_org uuid; site uuid; brief uuid; quote uuid; job uuid; ws uuid; n bigint; r jsonb;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  select id into vend from public.organisations where name = 'Clean-Fit';
  insert into public.organisations (kind, name, segment) values ('vendor', 'Other Vendor', 'sme') returning id into other_vend;
  insert into public.vendor_profiles (org_id, hourly_rate, base_lat, base_lng) values (other_vend, 25, 51.89, 0.90);
  insert into public.memberships values (duly_org, admin_u, 'platform_admin'), (vend, vendor_u, 'vendor_admin'), (vend, crew_u, 'operative'),
    (vend, other_crew, 'operative'), (other_vend, other_v, 'vendor_admin');
  insert into public.vendor_profiles (org_id, hourly_rate, base_lat, base_lng) values (vend, 20, 51.89, 0.90) on conflict (org_id) do update set hourly_rate = 20;
  perform tests.as_user(admin_u); update public.organisations set verification_tier = 3 where id = vend; perform tests.as_su();

  perform tests.as_user(buyer_u); buyer_org := public.create_buyer_org('Gym Ltd', 'sme');
  insert into public.sites (org_id, name, town, postcode, lat, lng, geofence_m) values (buyer_org, 'Gym', 'Colchester', 'CO1 1AA', 51.8892, 0.9042, 150) returning id into site;
  insert into public.briefs (buyer_org_id, site_id, title) values (buyer_org, site, 'Gym clean') returning id into brief;
  insert into public.brief_versions (brief_id, version, visits_per_week, schedule) values (brief, 1, 1,
    '[{"name":"Showers","areas":[{"id":"a1","name":"Showers","minutes":60,"standards":[{"id":"s1","text":"Drains clear"}]}]}]'::jsonb);
  update public.brief_versions set locked_at = now(), locked_by = auth.uid() where brief_id = brief and version = 1;
  insert into public.quotes (brief_id, brief_version, vendor_org_id) values (brief, 1, vend) returning id into quote;
  perform tests.as_user(stranger_b); stranger_org := public.create_buyer_org('Stranger Ltd', 'sme');

  -- The vendor builds a draft. The server fills in who and what it belongs to, whatever the browser sends.
  perform tests.as_user(vendor_u);
  insert into public.work_schedules (quote_id, brief_id, vendor_org_id, status, legend, plan)
    values (quote, gen_random_uuid(), other_vend, 'locked', pg_temp.legend(null), pg_temp.plan()) returning id into ws;
  perform tests.as_su();
  perform tests.eq((select status from public.work_schedules where id = ws), 'draft', 'a new schedule is always a draft, whatever was sent');
  perform tests.eq((select brief_id from public.work_schedules where id = ws), brief, 'its brief comes from the quote');
  perform tests.eq((select vendor_org_id from public.work_schedules where id = ws), vend, 'and its vendor comes from the quote');

  -- Who can see a draft.
  perform tests.as_user(vendor_u); select count(*) into n from public.work_schedules where id = ws; perform tests.eq(n, 1::bigint, 'the vendor sees its draft');
  perform tests.as_user(buyer_u); select count(*) into n from public.work_schedules where id = ws; perform tests.eq(n, 0::bigint, 'the client does not see a draft');
  perform tests.as_user(other_v); select count(*) into n from public.work_schedules where id = ws; perform tests.eq(n, 0::bigint, 'another vendor does not see it');
  perform tests.as_user(crew_u); select count(*) into n from public.work_schedules where id = ws; perform tests.eq(n, 0::bigint, 'crew do not see a draft');
  perform tests.as_user(admin_u); select count(*) into n from public.work_schedules where id = ws; perform tests.eq(n, 1::bigint, 'Duly sees it');

  -- Who can start one.
  perform tests.as_user(other_v);
  perform tests.throws(format('insert into public.work_schedules (quote_id, legend, plan) values (%L, %L, %L)', quote, pg_temp.legend(5), pg_temp.plan()), '%Only the vendor%', 'another vendor cannot build one for this quote');
  perform tests.as_user(buyer_u);
  perform tests.throws(format('insert into public.work_schedules (quote_id, legend, plan) values (%L, %L, %L)', quote, pg_temp.legend(5), pg_temp.plan()), '%Only the vendor%', 'the client cannot build one');

  -- Sending needs the minutes for every method used.
  perform tests.as_user(vendor_u);
  perform tests.throws(format('update public.work_schedules set status = %L where id = %L', 'submitted', ws), '%Set the minutes for scrub%', 'it cannot be sent without minutes for each method it uses');
  perform tests.throws(format('update public.work_schedules set plan = %L where id = %L', jsonb_set(pg_temp.plan(), '{sections,0,subsections,0,areas,0,days,sun}', '"polish"'), ws), '%Unknown cleaning method%', 'an unknown method is refused');
  perform tests.throws(format('update public.work_schedules set plan = %L where id = %L', jsonb_set(pg_temp.plan(), '{sections,0,subsections,0,areas,0,days}', '{"someday":"mop"}'), ws), '%Unknown weekday%', 'an unknown weekday is refused');
  perform tests.throws(format('update public.work_schedules set plan = %L where id = %L', jsonb_set(pg_temp.plan(), '{sections,0,subsections,0,areas,1,id}', '"s1-1-1"'), ws), '%must be unique%', 'duplicate area ids are refused');
  perform tests.throws(format('update public.work_schedules set legend = %L where id = %L', jsonb_set(pg_temp.legend(5), '{scrub,minutes}', '"lots"'), ws), '%whole number%', 'minutes must be a number');

  -- The vendor sets its minutes and sends it.
  update public.work_schedules set legend = pg_temp.legend(10) where id = ws;
  update public.work_schedules set status = 'submitted' where id = ws;
  perform tests.as_su();
  perform tests.eq((select status from public.work_schedules where id = ws), 'submitted', 'a complete schedule can be sent');
  perform tests.ok((select submitted_at is not null from public.work_schedules where id = ws), 'with the time it was sent');

  perform tests.as_user(buyer_u); select count(*) into n from public.work_schedules; perform tests.eq(n, 1::bigint, 'the client sees it once it is sent');
  update public.work_schedules set status = 'draft' where id = ws; get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'but cannot change it');
  perform tests.as_user(stranger_b); select count(*) into n from public.work_schedules; perform tests.eq(n, 0::bigint, 'another client does not see it');
  perform tests.as_user(other_v); select count(*) into n from public.work_schedules; perform tests.eq(n, 0::bigint, 'nor another vendor');
  perform tests.as_user(crew_u); select count(*) into n from public.work_schedules; perform tests.eq(n, 0::bigint, 'crew see nothing until the job is booked');

  -- The vendor can still improve it while the quote is open (an edit to a sent schedule is not a status change).
  perform tests.as_user(vendor_u);
  update public.work_schedules set plan = jsonb_set(pg_temp.plan(), '{sections,0,subsections,0,areas,1,days}', '{"mon":"wash"}') where id = ws;
  perform tests.as_su();
  perform tests.eq((select plan #>> '{sections,0,subsections,0,areas,1,days,mon}' from public.work_schedules where id = ws), 'wash', 'the vendor can still edit it while the quote is open');
  perform tests.eq((select status from public.work_schedules where id = ws), 'submitted', 'and it stays sent');

  -- Accepting the quote locks it.
  perform tests.as_user(vendor_u); perform public.submit_quote(quote);
  perform tests.as_user(buyer_u); job := public.accept_quote(quote, now() + interval '1 day');
  perform tests.as_su();
  perform tests.eq((select status from public.work_schedules where id = ws), 'locked', 'accepting the quote locks the schedule');
  perform tests.ok((select locked_at is not null from public.work_schedules where id = ws), 'with the time it was locked');
  perform tests.as_user(vendor_u);
  update public.work_schedules set plan = pg_temp.plan() where id = ws; get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'the vendor cannot change a locked schedule');
  delete from public.work_schedules where id = ws; get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'or remove it');
  perform tests.as_su();
  perform tests.throws(format('update public.work_schedules set legend = %L where id = %L', pg_temp.legend(1), ws), '%locked%', 'not even the database owner can edit it');
  perform tests.throws(format('update public.work_schedules set status = %L where id = %L', 'draft', ws), '%locked%', 'or reopen it');

  -- Crew see it once they are on the job.
  perform tests.as_user(crew_u); select count(*) into n from public.work_schedules; perform tests.eq(n, 0::bigint, 'crew not yet assigned do not see it');
  perform tests.as_user(vendor_u); insert into public.job_assignments (job_id, user_id, role) values (job, crew_u, 'lead');
  perform tests.as_user(crew_u); select count(*) into n from public.work_schedules; perform tests.eq(n, 1::bigint, 'the assigned crew member sees it');
  perform tests.as_user(other_crew); select count(*) into n from public.work_schedules; perform tests.eq(n, 0::bigint, 'another member of the same vendor, not on the job, does not');
  update public.work_schedules set plan = pg_temp.plan() where id = ws; get diagnostics n = row_count; perform tests.eq(n, 0::bigint, 'and crew cannot change it');

  -- A complaint can name the cleaning area; the label is worked out by the database.
  perform tests.as_user(buyer_u);
  insert into public.issues (job_id, kind, description, plan_item_id, plan_label) values (job, 'quality', 'Drain not cleaned', 's1-1-1', 'forged label');
  perform tests.as_su();
  perform tests.eq((select plan_label from public.issues where job_id = job), 'Changing room > Showers > Shower drains', 'the complaint carries the area path, and a forged label is ignored');
  perform tests.eq((select plan_item_id from public.issues where job_id = job), 's1-1-1', 'and the area id');
  perform tests.as_user(buyer_u);
  perform tests.throws(format('insert into public.issues (job_id, kind, description, plan_item_id) values (%L, %L, %L, %L)', job, 'quality', 'x', 'not-an-area'), '%not in the work schedule%', 'a complaint cannot name an area that is not in the schedule');
  r := tests.without_schedule(tests.book_job('sme'));
  perform tests.as_user((r ->> 'buyer')::uuid);
  perform tests.throws(format('insert into public.issues (job_id, kind, description, plan_item_id) values (%L, %L, %L, %L)', r ->> 'job', 'quality', 'x', 's1-1-1'), '%no work schedule%', 'nor on a job that has no schedule');
  insert into public.issues (job_id, kind, description) values ((r ->> 'job')::uuid, 'quality', 'ordinary complaint');
  perform tests.as_su();
  perform tests.eq((select plan_label from public.issues where description = 'ordinary complaint'), null, 'a complaint with no area is still allowed');

  -- The audit log records the schedule being sent and locked, with who did it, but not every draft save.
  perform tests.eq((select count(*) from public.audit_log where table_name = 'work_schedules' and row_id = ws::text), 3::bigint, 'created, sent and locked are logged (an edit to a sent schedule is not)');
  perform tests.ok(exists (select 1 from public.audit_log where row_id = ws::text and summary = 'Work schedule status draft to submitted' and actor = vendor_u), 'sending is logged against the vendor');
  perform tests.ok(exists (select 1 from public.audit_log where row_id = ws::text and summary = 'Work schedule status submitted to locked' and actor = buyer_u), 'locking is logged against the client who accepted');
  perform tests.ok(exists (select 1 from public.audit_log where row_id = ws::text and brief_id = brief and vend = any (org_ids) and buyer_org = any (org_ids)), 'and it belongs to the brief and both organisations');

  -- Templates: shared ones for vendor staff, private ones for their own organisation.
  perform tests.as_user(vendor_u); select count(*) into n from public.work_plan_templates; perform tests.eq(n, 2::bigint, 'vendor staff see the two shared templates');
  perform tests.ok((select count(*) from public.work_plan_templates where name = 'Gym changing rooms' and jsonb_array_length(plan -> 'sections') = 3) = 1, 'including the gym changing rooms template with its three sections');
  perform tests.ok((select bool_and(legend -> 'scrub' ->> 'minutes' is null) from public.work_plan_templates), 'with no minutes filled in for the vendor');
  insert into public.work_plan_templates (vendor_org_id, name, legend, plan) values (vend, 'Our gym', pg_temp.legend(10), pg_temp.plan());
  select count(*) into n from public.work_plan_templates; perform tests.eq(n, 3::bigint, 'a vendor can save its own template');
  perform tests.throws(format('insert into public.work_plan_templates (vendor_org_id, name, legend, plan) values (%L, %L, %L, %L)', other_vend, 'Theirs', pg_temp.legend(1), pg_temp.plan()), '%row-level%', 'but not for another organisation');
  update public.work_plan_templates set name = 'Hijacked' where vendor_org_id is null; get diagnostics n = row_count; perform tests.eq(n, 0::bigint, 'and cannot change a shared template');
  perform tests.as_user(other_v); select count(*) into n from public.work_plan_templates; perform tests.eq(n, 2::bigint, 'another vendor sees the shared ones but not our template');
  perform tests.as_user(buyer_u); select count(*) into n from public.work_plan_templates; perform tests.eq(n, 0::bigint, 'a client sees no templates');
  perform tests.as_user(admin_u); update public.work_plan_templates set description = 'Edited by Duly' where name = 'Gym floors'; get diagnostics n = row_count;
  perform tests.eq(n, 1::bigint, 'Duly can maintain the shared templates');
end $$;
