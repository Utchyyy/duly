-- Per-area ticks and photos on a job that has a work schedule, and the client's check against it.
create function pg_temp.legend() returns jsonb language sql as $$
  select '{"scrub":{"label":"Scrub","minutes":10},"wash":{"label":"Wash","minutes":6},"clean":{"label":"Clean","minutes":3},"mop":{"label":"Mop","minutes":5}}'::jsonb
$$;
create function pg_temp.alldays(m text) returns text language sql as $$
  select format('{"mon":"%1$s","tue":"%1$s","wed":"%1$s","thu":"%1$s","fri":"%1$s","sat":"%1$s","sun":"%1$s"}', m)
$$;
-- Every row is planned on every weekday except r4 (never planned), so the visit day does not matter.
create function pg_temp.plan() returns jsonb language sql as $$
  select ('{"sections":[{"id":"s1","name":"Changing room","subsections":['
    || '{"id":"g1","name":"Showers","brief_area_id":null,"areas":['
    || '{"id":"r1","name":"Shower drains","days":' || pg_temp.alldays('scrub') || '},'
    || '{"id":"r2","name":"Cubicle walls","days":' || pg_temp.alldays('wash') || '},'
    || '{"id":"r4","name":"Spare room","days":{}}]},'
    || '{"id":"g2","name":"Lockers","brief_area_id":null,"areas":['
    || '{"id":"r3","name":"Locker tops","days":' || pg_temp.alldays('clean') || '}]}]}]}')::jsonb
$$;

-- Books a job with a locked schedule: the vendor sends it, the client accepts, the vendor assigns the crew.
create function pg_temp.book_with_plan(p_start timestamptz default null, p_plan jsonb default null) returns jsonb language plpgsql as $$
declare
  admin_u uuid := tests.mk_user('admin'); buyer_u uuid := tests.mk_user('buyer'); vendor_u uuid := tests.mk_user('vendor'); crew_u uuid := tests.mk_user('crew');
  duly_org uuid; vend uuid; buyer_org uuid; site uuid; brief uuid; quote uuid; job uuid;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  select id into vend from public.organisations where name = 'Clean-Fit';
  insert into public.memberships values (duly_org, admin_u, 'platform_admin'), (vend, vendor_u, 'vendor_admin'), (vend, crew_u, 'operative');
  insert into public.vendor_profiles (org_id, hourly_rate, base_lat, base_lng) values (vend, 20, 51.89, 0.90) on conflict (org_id) do update set hourly_rate = 20;
  perform tests.as_user(admin_u); update public.organisations set verification_tier = 3 where id = vend;
  perform tests.as_user(buyer_u); buyer_org := public.create_buyer_org('Gym Ltd', 'sme');
  insert into public.sites (org_id, name, town, postcode, lat, lng, geofence_m) values (buyer_org, 'Gym', 'Colchester', 'CO1 1AA', 51.8892, 0.9042, 150) returning id into site;
  insert into public.briefs (buyer_org_id, site_id, title) values (buyer_org, site, 'Gym clean') returning id into brief;
  insert into public.brief_versions (brief_id, version, visits_per_week, schedule) values (brief, 1, 1,
    '[{"name":"Showers","areas":[{"id":"a1","name":"Showers","minutes":60,"standards":[{"id":"s1","text":"Drains clear"}]}]}]'::jsonb);
  update public.brief_versions set locked_at = now(), locked_by = auth.uid() where brief_id = brief and version = 1;
  insert into public.quotes (brief_id, brief_version, vendor_org_id) values (brief, 1, vend) returning id into quote;
  perform tests.as_user(vendor_u);
  insert into public.work_schedules (quote_id, legend, plan) values (quote, pg_temp.legend(), coalesce(p_plan, pg_temp.plan()));
  update public.work_schedules set status = 'submitted' where quote_id = quote;
  perform public.submit_quote(quote);
  perform tests.as_user(buyer_u); job := public.accept_quote(quote, now() + interval '1 day');
  perform tests.as_user(vendor_u); insert into public.job_assignments (job_id, user_id, role) values (job, crew_u, 'lead');
  perform tests.as_su();
  if p_start is not null then update public.jobs set scheduled_start = p_start, scheduled_end = p_start + interval '90 minutes' where id = job; end if;
  return jsonb_build_object('admin', admin_u, 'buyer', buyer_u, 'vendor', vendor_u, 'crew', crew_u, 'job', job, 'brief', brief);
end $$;

-- The crew do the whole visit and finish.
create function pg_temp.crew_finishes(f jsonb) returns void language plpgsql as $$
declare job uuid := (f ->> 'job')::uuid;
begin
  perform tests.as_user((f ->> 'crew')::uuid);
  perform public.check_in(job, 51.8893, 0.9043);
  insert into public.plan_results (job_id, plan_item_id, done) values (job, 'r1', true), (job, 'r2', true), (job, 'r3', true);
  insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng) values
    (job, 'g1', 'photo_after', job || '/g1/1.jpg', 51.8893, 0.9043), (job, 'g2', 'photo_after', job || '/g2/1.jpg', 51.8893, 0.9043);
  perform public.complete_job(job, 51.8893, 0.9043);
  perform tests.as_su();
end $$;

do $$
declare f jsonb; job uuid; n bigint;
begin
  f := pg_temp.book_with_plan(); job := (f ->> 'job')::uuid;

  -- The app is told when the schedule decides the check.
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.ok(public.job_plan_day(job) in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'), 'the crew are told the visit weekday when a schedule applies');
  perform tests.as_user((f ->> 'buyer')::uuid); perform tests.ok(public.job_plan_day(job) is not null, 'and so is the client');
  perform tests.as_user(tests.mk_user('stranger'));
  perform tests.throws(format('select public.job_plan_day(%L)', job), '%Job not found%', 'someone not on the job cannot ask');

  -- Ticks: only while the job is in progress, only planned areas, only crew.
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.throws(format('insert into public.plan_results (job_id, plan_item_id, done) values (%L, %L, true)', job, 'r1'), '%only be ticked while the job is in progress%', 'nothing can be ticked before check-in');
  perform public.check_in(job, 51.8893, 0.9043);
  perform tests.throws(format('insert into public.plan_results (job_id, plan_item_id, done) values (%L, %L, true)', job, 'r4'), '%not planned for this visit%', 'an area not planned that day cannot be ticked');
  perform tests.throws(format('insert into public.plan_results (job_id, plan_item_id, done) values (%L, %L, true)', job, 'nope'), '%not planned for this visit%', 'nor one that is not in the schedule');
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('insert into public.plan_results (job_id, plan_item_id, done) values (%L, %L, true)', job, 'r1'), '%Only the crew can tick%', 'the client cannot tick');
  perform tests.as_user((f ->> 'crew')::uuid);
  insert into public.plan_results (job_id, plan_item_id, done) values (job, 'r1', true);
  perform tests.as_su();
  perform tests.ok((select done_at is not null and done_by = (f ->> 'crew')::uuid from public.plan_results where job_id = job and plan_item_id = 'r1'), 'a tick records when and who');
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.throws(format('update public.plan_results set verdict = %L where job_id = %L and plan_item_id = %L', 'met', job, 'r1'), '%Only the client can mark%', 'the crew cannot give a verdict');

  -- Finishing needs every planned area ticked and a photo for every sub-section worked.
  perform tests.throws(format('select public.complete_job(%L)', job), '%2 part(s) of the site still need an after photo%', 'no photos: both sub-sections need one');
  insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng) values (job, 'g1', 'photo_after', job || '/g1/1.jpg', 51.8893, 0.9043);
  perform tests.throws(format('select public.complete_job(%L)', job), '%1 part(s) of the site still need an after photo%', 'a photo for one sub-section is not enough');
  insert into public.evidence (job_id, area_id, plan_item_id, kind, storage_path, lat, lng) values (job, 'wrong', 'r3', 'photo_after', job || '/g2/1.jpg', 51.8893, 0.9043);
  perform tests.as_su();
  perform tests.eq((select area_id from public.evidence where storage_path = job || '/g2/1.jpg'), 'g2', 'a photo tagged to a cleaning area is filed under its sub-section, whatever the browser said');
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.throws(format('insert into public.evidence (job_id, area_id, plan_item_id, kind, storage_path) values (%L, %L, %L, %L, %L)', job, 'g1', 'r4', 'photo_after', job || '/x.jpg'), '%not planned for this visit%', 'a photo cannot be tagged to an area that is not planned');
  perform tests.throws(format('select public.complete_job(%L)', job), '%2 cleaning area(s) still need ticking%', 'photos done, two areas still unticked');
  insert into public.plan_results (job_id, plan_item_id, done) values (job, 'r2', true), (job, 'r3', true);
  perform public.complete_job(job, 51.8893, 0.9043);
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = job), 'completed', 'with everything ticked and photographed, the job completes');
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.throws(format('update public.plan_results set done = false where job_id = %L and plan_item_id = %L', job, 'r1'), '%only be ticked while the job is in progress%', 'ticks cannot be changed after the job is finished');

  -- The client checks the same areas.
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.throws(format('update public.plan_results set verdict = %L where job_id = %L and plan_item_id = %L', 'met', job, 'r1'), '%Only the client can mark%', 'the vendor cannot judge its own work');
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.throws(format('select public.approve_job(%L)', job), '%Check every cleaning area first%', 'approval needs every planned area checked');
  update public.plan_results set verdict = 'met' where job_id = job and plan_item_id in ('r1', 'r2');
  perform tests.throws(format('select public.approve_job(%L)', job), '%Check every cleaning area first%', 'one area unchecked still blocks approval');
  update public.plan_results set verdict = 'not_met' where job_id = job and plan_item_id = 'r3';
  perform tests.throws(format('select public.approve_job(%L)', job), '%not right%', 'an area marked not met blocks approval');
  update public.plan_results set verdict = 'met' where job_id = job and plan_item_id = 'r3';
  perform public.approve_job(job);
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = job), 'quality_verified', 'with every area accepted the job can be approved');
  perform tests.ok((select verdict_by = (f ->> 'buyer')::uuid and verdict_at is not null from public.plan_results where job_id = job and plan_item_id = 'r1'), 'a verdict records when and who');
  perform tests.ok(not exists (select 1 from public.area_results where job_id = job), 'the brief standards were not needed');

  -- The audit log records each tick and verdict on an area.
  perform tests.ok(exists (select 1 from public.audit_log where job_id = job and summary = 'Cleaning area ticked by crew' and actor = (f ->> 'crew')::uuid and row_id like '%r1%'), 'a tick is logged against the crew member, with the area');
  perform tests.ok(exists (select 1 from public.audit_log where job_id = job and summary = 'Cleaning area marked met' and actor = (f ->> 'buyer')::uuid), 'and a verdict against the client');
  perform tests.ok(exists (select 1 from public.audit_log where job_id = job and summary = 'Cleaning area marked not met'), 'including one that was changed after');
end $$;

-- A problem on an exact area marks it not met; a vendor's report does not.
do $$
declare f jsonb; job uuid; iss uuid;
begin
  f := pg_temp.book_with_plan(); job := (f ->> 'job')::uuid;
  perform pg_temp.crew_finishes(f);
  perform tests.as_user((f ->> 'vendor')::uuid);
  insert into public.issues (job_id, kind, description, plan_item_id) values (job, 'other', 'Access was blocked', 'r1');
  perform tests.as_su();
  perform tests.ok((select verdict is null from public.plan_results where job_id = job and plan_item_id = 'r1'), 'a vendor reporting on an area does not mark the work not met');
  perform tests.as_user((f ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description, plan_item_id) values (job, 'quality', 'Walls still dirty', 'r2') returning id into iss;
  perform tests.as_su();
  perform tests.eq((select verdict from public.plan_results where job_id = job and plan_item_id = 'r2'), 'not_met', 'the client reporting on an area marks it not met');
  perform tests.eq((select status::text from public.jobs where id = job), 'disputed', 'and the job is held');
  perform tests.as_user((f ->> 'vendor')::uuid);
  update public.issues set status = 'resolved' where job_id = job and raised_by = (f ->> 'vendor')::uuid;
  perform tests.as_user((f ->> 'buyer')::uuid);
  update public.issues set status = 'resolved' where id = iss;
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = job), 'completed', 'once the problem is resolved the job is back with the client');
  perform tests.eq((select verdict from public.plan_results where job_id = job and plan_item_id = 'r2'), 'not_met', 'the area stays not met until the client accepts it again');
  perform tests.as_user((f ->> 'buyer')::uuid);
  update public.plan_results set verdict = 'met' where job_id = job and plan_item_id in ('r1', 'r2', 'r3');
  perform public.approve_job(job);
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = job), 'quality_verified', 'then the job can be approved');
end $$;

-- The weekday is taken in the market timezone, and a day with nothing planned falls back to the standards check.
do $$
declare f jsonb; job uuid; tz text;
begin
  select m.timezone into tz from public.markets m where m.code = 'UK';
  perform tests.eq(tz, 'Europe/London', 'the UK market uses London time');
  -- 23:30 UTC on Saturday 6 June 2026 is 00:30 on Sunday in London (British Summer Time).
  f := pg_temp.book_with_plan('2026-06-06 23:30:00+00'); job := (f ->> 'job')::uuid;
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.eq(public.job_plan_day(job), 'sun', 'the weekday follows local time, not UTC');

  -- A schedule that plans nothing on the visit day: the brief standards decide, as before.
  f := pg_temp.book_with_plan('2026-06-09 10:00:00+00', ('{"sections":[{"id":"s1","name":"A","subsections":[{"id":"g1","name":"B","brief_area_id":null,"areas":[{"id":"r1","name":"C","days":{"mon":"clean"}}]}]}]}')::jsonb);
  job := (f ->> 'job')::uuid; -- a Tuesday
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.ok(public.job_plan_day(job) is null, 'a day with nothing planned has no schedule check');
  perform public.check_in(job, 51.8893, 0.9043);
  perform tests.throws(format('select public.complete_job(%L)', job), '%area(s) still need an after photo%', 'it falls back to the brief standards check');
end $$;

-- A job with no schedule is unchanged.
do $$
declare r jsonb;
begin
  r := tests.book_job('sme');
  perform tests.as_user((r ->> 'crew')::uuid);
  perform tests.ok(public.job_plan_day((r ->> 'job')::uuid) is null, 'a job with no schedule keeps the standards check');
  perform tests.as_su();
  perform tests.crew_completes(r);
  perform tests.buyer_approves(r);
  perform tests.eq((select status::text from public.jobs where id = (r ->> 'job')::uuid), 'quality_verified', 'and still completes and approves as before');
end $$;
