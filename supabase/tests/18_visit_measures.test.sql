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


-- A visit that was late, took longer than planned, and was accepted later: every measure is worked out in SQL.
do $$
declare f jsonb; job uuid; st timestamptz; ci timestamptz; co timestamptz; m record; n bigint; other_v uuid := tests.mk_user('other-vendor');
  stranger uuid := tests.mk_user('stranger'); vend uuid;
begin
  f := pg_temp.book_with_plan(now() - interval '3 hours'); job := (f ->> 'job')::uuid;
  select id into vend from public.organisations where name = 'Clean-Fit';
  insert into public.organisations (kind, name, segment) values ('vendor', 'Other Vendor', 'sme');
  insert into public.memberships select id, other_v, 'vendor_admin' from public.organisations where name = 'Other Vendor';

  -- Before check-in there is nothing to measure.
  perform tests.as_user((f ->> 'vendor')::uuid);
  select count(*) into n from public.visit_measures(job); perform tests.eq(n, 0::bigint, 'a visit that was never checked in has no measures');

  perform pg_temp.crew_finishes(f);
  perform tests.as_su();
  select scheduled_start into st from public.jobs where id = job;
  -- Arrived 20 minutes after the start, finished 50 minutes later; ticks 10, 25 and 45 minutes after arriving.
  update public.job_events set at = st + interval '20 minutes' where job_id = job and kind = 'check_in';
  ci := st + interval '20 minutes'; co := ci + interval '50 minutes';
  update public.job_events set at = co where job_id = job and kind = 'check_out';
  update public.plan_results set done_at = ci + interval '10 minutes' where job_id = job and plan_item_id = 'r1';
  update public.plan_results set done_at = ci + interval '25 minutes' where job_id = job and plan_item_id = 'r2';
  update public.plan_results set done_at = ci + interval '45 minutes' where job_id = job and plan_item_id = 'r3';

  perform tests.as_user((f ->> 'vendor')::uuid);
  select * into m from public.visit_measures(job);
  perform tests.eq(m.late_minutes, 20, 'the arrival is measured against the start time: 20 minutes late');
  perform tests.eq(m.tolerance_minutes, 15, 'against the 15-minute tolerance from the policy');
  perform tests.eq(m.on_time, false, 'so it was not on time');
  perform tests.ok(m.uses_plan, 'the schedule decided the check');
  perform tests.eq(m.planned_minutes, 19, 'planned time is the vendor''s minutes for the planned areas: scrub 10 + wash 6 + clean 3');
  perform tests.eq(m.on_site_minutes, 50, 'time on site runs from check-in to check-out');
  perform tests.eq(m.planned_areas, 3, 'three areas were planned');
  perform tests.eq(m.ticked_areas, 3, 'and all three were ticked');
  perform tests.eq(m.complaints, 0, 'no complaints');
  perform tests.ok(m.first_time_right, 'so it was right first time');
  perform tests.eq(m.photos, 2, 'two photos');
  perform tests.eq(m.photos_on_site, 2, 'both taken on site');

  -- The client accepts five hours after the cleaner finished.
  perform tests.as_user((f ->> 'buyer')::uuid);
  update public.plan_results set verdict = 'met' where job_id = job;
  perform public.approve_job(job);
  perform tests.as_su();
  update public.job_events set at = co + interval '5 hours' where job_id = job and kind = 'status_change' and data ->> 'to' = 'quality_verified';
  perform tests.as_user((f ->> 'buyer')::uuid);
  select * into m from public.visit_measures(job);
  perform tests.eq(m.hours_to_accept, 5.0::numeric, 'time for the client to accept is measured: 5 hours');
  perform tests.eq(m.status, 'quality_verified', 'and the status is carried');

  -- Time between ticks.
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.eq((select count(*) from public.visit_area_times(job)), 3::bigint, 'one line for each planned area');
  perform tests.eq((select string_agg(item_id || ':' || method || ':' || planned_minutes || ':' || minutes_since_previous, ' ' order by sequence_no) from public.visit_area_times(job)),
                   'r1:scrub:10:10.0 r2:wash:6:15.0 r3:clean:3:20.0', 'in tick order, with the method, the planned minutes and the time since the previous tick (or check-in)');

  -- Who can see it.
  foreach other_v in array array[(f ->> 'crew')::uuid, stranger, other_v] loop
    perform tests.as_user(other_v);
    perform tests.throws(format('select * from public.visit_measures(%L)', job), '%Job not found%', 'a cleaner, a stranger and another vendor cannot see a visit''s measures');
    perform tests.throws(format('select * from public.visit_area_times(%L)', job), '%Job not found%', 'nor its area times');
  end loop;
  perform tests.as_user((f ->> 'buyer')::uuid); perform tests.ok((select count(*) from public.visit_measures(job)) = 1, 'the client can');
  perform tests.as_user((f ->> 'admin')::uuid); perform tests.ok((select count(*) from public.visit_measures(job)) = 1, 'and Duly can');
end $$;

-- A visit with a complaint, a legacy visit, and the summaries across visits.
do $$
declare a jsonb; b jsonb; l jsonb; job_b uuid; s record; vend uuid; other_v uuid := tests.mk_user('other-vendor-2'); stranger uuid := tests.mk_user('stranger-2'); fv uuid := tests.mk_user('fresh-vendor-staff');
begin
  insert into public.organisations (kind, name, segment) values ('vendor', 'Fresh Vendor', 'sme') returning id into vend;
  insert into public.memberships values (vend, fv, 'vendor_admin');
  insert into public.memberships select id, other_v, 'vendor_admin' from public.organisations where name = 'Other Vendor';
  a := pg_temp.book_with_plan(now() - interval '3 hours');
  perform pg_temp.crew_finishes(a);
  perform tests.as_su();
  update public.job_events set at = (select scheduled_start from public.jobs where id = (a ->> 'job')::uuid) + interval '20 minutes' where job_id = (a ->> 'job')::uuid and kind = 'check_in';
  update public.job_events set at = (select at from public.job_events where job_id = (a ->> 'job')::uuid and kind = 'check_in') + interval '50 minutes' where job_id = (a ->> 'job')::uuid and kind = 'check_out';

  b := pg_temp.book_with_plan(); job_b := (b ->> 'job')::uuid;
  perform pg_temp.crew_finishes(b);
  perform tests.as_user((b ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description, plan_item_id) values (job_b, 'quality', 'Walls still dirty', 'r2');
  insert into public.issues (job_id, kind, description) values (job_b, 'safeguarding', 'Private concern');
  perform tests.as_user((b ->> 'vendor')::uuid);
  perform tests.eq((select complaints from public.visit_measures(job_b)), 1, 'a complaint is counted, and a safeguarding report is not');
  perform tests.ok(not (select first_time_right from public.visit_measures(job_b)), 'a visit with a complaint was not right first time');

  l := tests.book_job('sme');
  perform tests.crew_completes(l);
  perform tests.as_su();
  -- Count only these three visits: give them to a vendor with no other history.
  update public.jobs set vendor_org_id = vend where id in ((a ->> 'job')::uuid, job_b, (l ->> 'job')::uuid);
  perform tests.as_user(fv);
  perform tests.ok(not (select uses_plan from public.visit_measures((l ->> 'job')::uuid)), 'a visit with no schedule is measured against the brief');
  perform tests.eq((select planned_minutes from public.visit_measures((l ->> 'job')::uuid)), 90, 'with the brief''s minutes as the plan (60 + 30)');
  perform tests.eq((select planned_areas from public.visit_measures((l ->> 'job')::uuid)), 3, 'and its three standards as the areas');
  perform tests.eq((select ticked_areas from public.visit_measures((l ->> 'job')::uuid)), 3, 'all ticked');
  perform tests.eq((select count(*) from public.visit_area_times((l ->> 'job')::uuid)), 0::bigint, 'with no per-area times, as there is no schedule');

  -- The vendor summary: three visits, one late, one with a complaint.
  perform tests.as_user(fv);
  select * into s from public.vendor_operations(vend, current_date - 30, current_date + 30);
  perform tests.eq(s.visits, 3, 'three visits checked in');
  perform tests.eq(s.on_time_rate, 0.667::numeric, 'two of three on time');
  perform tests.eq(s.first_time_right_rate, 0.667::numeric, 'two of three right first time');
  perform tests.eq(s.complaints_per_100, 33.3::numeric, 'one complaint in three visits: 33.3 per 100');
  perform tests.eq(s.plan_followed_rate, 1.000::numeric, 'every planned area ticked');
  perform tests.eq(s.photos_on_site_rate, 1.000::numeric, 'every photo on site');
  perform tests.eq(s.avg_planned_minutes, 42.7::numeric, 'average planned time (19, 19 and 90)');
  perform tests.eq(s.time_vs_plan, 0.39::numeric, 'time on site against plan: 50 of 128 planned minutes');
  perform tests.eq(s.open_issues, 1, 'one open issue (the safeguarding report is not counted)');
  perform tests.eq(s.sla_breaches, 0, 'and none past their response deadline');
  perform tests.eq((select visits from public.vendor_operations(vend, current_date - 30, current_date - 20)), 0, 'a range with no visits shows none');
  perform tests.eq((select area || ':' || complaints from public.vendor_problem_areas(vend, current_date - 30, current_date + 30)), 'Changing room > Showers > Cubicle walls:1', 'the problem areas list names the exact area complained about');

  perform tests.eq((select count(*) from public.vendor_visits(vend, current_date - 30, current_date + 30)), 3::bigint, 'the vendor''s recent visits list has one line for each visit');
  perform tests.ok((select bool_and(scheduled_start <= lag_start) from (select scheduled_start, coalesce(lag(scheduled_start) over (order by ord), scheduled_start) as lag_start from public.vendor_visits(vend, current_date - 30, current_date + 30) with ordinality as v(job_id, scheduled_start, site_name, status, late_minutes, on_time, planned_minutes, on_site_minutes, planned_areas, ticked_areas, complaints, first_time_right, ord)) q), 'most recent first');
  perform tests.eq((select count(*) filter (where late_minutes = 20 and not on_time) from public.vendor_visits(vend, current_date - 30, current_date + 30)), 1::bigint, 'the late one is marked late');
  perform tests.as_user(other_v);
  perform tests.throws(format('select * from public.vendor_visits(%L, current_date - 30, current_date)', vend), '%Not allowed%', 'another vendor cannot list this vendor''s visits');
  perform tests.throws(format('select * from public.vendor_operations(%L, current_date - 30, current_date)', vend), '%Not allowed%', 'another vendor cannot see this vendor''s summary');
  perform tests.throws(format('select * from public.vendor_problem_areas(%L, current_date - 30, current_date)', vend), '%Not allowed%', 'or its problem areas');
  perform tests.throws('select * from public.platform_operations(current_date - 30, current_date)', '%Only Duly%', 'or the comparison across vendors');
  perform tests.as_user((a ->> 'buyer')::uuid);
  perform tests.throws(format('select * from public.vendor_operations(%L, current_date - 30, current_date)', vend), '%Not allowed%', 'a client cannot see a vendor''s summary');
  perform tests.as_user(stranger);
  perform tests.throws('select * from public.platform_operations(current_date - 30, current_date)', '%Only Duly%', 'a stranger cannot see the comparison');
  perform tests.as_user((a ->> 'admin')::uuid);
  perform tests.eq((select vendor_name || ':' || visits from public.platform_operations(current_date - 30, current_date + 30) where vendor_org_id = vend), 'Fresh Vendor:3', 'Duly sees the comparison across vendors');
  perform tests.eq((select visits from public.vendor_operations(vend, current_date - 30, current_date + 30)), 3, 'and any vendor''s summary');
  perform tests.as_anon();
  perform tests.throws('select * from public.platform_operations(current_date - 30, current_date)', '%permission denied%', 'signed-out visitors cannot call it at all');
end $$;
