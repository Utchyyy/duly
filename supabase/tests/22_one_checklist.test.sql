-- One checklist: the work schedule is the checklist for every new job, and the brief's standards live on inside it.

-- Books a job on a brief of the caller's choosing. The vendor sends a schedule only if one is given.
create function pg_temp.book_custom(p_brief_schedule jsonb, p_plan jsonb default null, p_legend jsonb default null, p_start timestamptz default null) returns jsonb language plpgsql as $$
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
  insert into public.brief_versions (brief_id, version, visits_per_week, schedule) values (brief, 1, 1, p_brief_schedule);
  update public.brief_versions set locked_at = now(), locked_by = auth.uid() where brief_id = brief and version = 1;
  insert into public.quotes (brief_id, brief_version, vendor_org_id) values (brief, 1, vend) returning id into quote;
  perform tests.as_user(vendor_u);
  if p_plan is not null then
    insert into public.work_schedules (quote_id, legend, plan) values (quote, p_legend, p_plan);
    update public.work_schedules set status = 'submitted' where quote_id = quote;
  end if;
  perform public.submit_quote(quote);
  perform tests.as_user(buyer_u); job := public.accept_quote(quote, now() + interval '1 day');
  perform tests.as_user(vendor_u); insert into public.job_assignments (job_id, user_id, role) values (job, crew_u, 'lead');
  perform tests.as_su();
  if p_start is not null then update public.jobs set scheduled_start = p_start, scheduled_end = p_start + interval '90 minutes' where id = job; end if;
  return jsonb_build_object('admin', admin_u, 'buyer', buyer_u, 'vendor', vendor_u, 'crew', crew_u, 'job', job, 'quote', quote, 'brief', brief);
end $$;

-- A Monday at 10:00 in the market's timezone, next week.
create function pg_temp.next_monday() returns timestamptz language sql as $$
  select ((date_trunc('week', (now() at time zone 'Europe/London') + interval '7 days')::date) + time '10:00') at time zone 'Europe/London'
$$;

-- No schedule from the vendor: Duly builds one from the brief when the client accepts.
do $$
declare
  f jsonb; job uuid; ws public.work_schedules; v_rw uuid; issue uuid; n integer;
begin
  f := tests.book_job('sme'); job := (f ->> 'job')::uuid;
  select * into ws from public.work_schedules where quote_id = (f ->> 'quote')::uuid;
  perform tests.eq(ws.status, 'locked', 'the client accepted a quote with no schedule: one was built and locked');
  perform tests.eq(jsonb_array_length(ws.plan -> 'sections'), 1, 'one section, from the brief''s section');
  perform tests.eq(ws.plan -> 'sections' -> 0 ->> 'name', 'Clinical', 'with its name');
  perform tests.eq((select string_agg(ss ->> 'id' || ':' || (ss ->> 'brief_area_id') || ':' || (ss ->> 'name'), ',' order by ord)
                      from jsonb_array_elements(ws.plan -> 'sections' -> 0 -> 'subsections') with ordinality t(ss, ord)), 'a1:a1:Surgery,a2:a2:Reception',
                   'each brief area is a sub-section with the same id, linked back to it');
  perform tests.eq((select string_agg(a ->> 'id' || '=' || (a ->> 'name'), ',' order by a ->> 'id')
                      from jsonb_array_elements(ws.plan -> 'sections' -> 0 -> 'subsections') ss,
                           jsonb_array_elements(ss -> 'areas') a), 'd1=Floors clean,d2=Surfaces wiped,d3=Bins empty', 'each standard is a cleaning area');
  perform tests.eq((select count(*) from jsonb_object_keys(ws.plan -> 'sections' -> 0 -> 'subsections' -> 0 -> 'areas' -> 0 -> 'days') x), 7::bigint, 'planned on every day');
  perform tests.eq(ws.legend -> 'clean' ->> 'minutes', '30', 'the brief''s 90 minutes are shared across the three: 30 each');
  perform tests.eq(ws.legend -> 'clean' ->> 'label', 'Clean', 'under one method');
  perform tests.eq(private.job_planned_minutes(job), 90, 'so planned time still matches the booking');

  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.eq(public.job_check_mode(job), 'plan', 'the job is checked against its schedule');
  perform tests.as_su();
  perform tests.crew_completes(f);
  perform tests.eq((select count(*) from public.plan_results where job_id = job and done), 3::bigint, 'the crew ticked the three cleaning areas');
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.eq(public.job_check_mode(job), 'plan', 'the client sees the same');
  perform tests.eq((select planned_areas || ':' || ticked_areas from public.visit_measures(job)), '3:3', 'the measures count the three areas');
  -- A complaint can name a standard, and so can get a rework visit.
  insert into public.issues (job_id, kind, description, plan_item_id) values (job, 'quality', 'Surfaces were not wiped', 'd2') returning id into issue;
  perform tests.eq((select plan_label from public.issues where id = issue), 'Clinical > Surgery > Surfaces wiped', 'a complaint names the exact standard');
  perform tests.eq((select verdict from public.plan_results where job_id = job and plan_item_id = 'd2'), 'not_met', 'which marks it not met');
  perform tests.as_user((f ->> 'vendor')::uuid);
  v_rw := public.book_rework(issue, now() + interval '2 days');
  perform tests.as_su();
  perform tests.eq((select string_agg(item_id, ',') from private.job_planned_rows(v_rw)), 'd2', 'and that standard can be put right on a rework visit');
end $$;

-- Ids that clash, an area with no standards, an empty brief, and a draft that was never sent.
do $$
declare f jsonb; ws public.work_schedules; n bigint;
begin
  f := pg_temp.book_custom('[{"name":"Rooms","areas":[
    {"id":"x1","name":"Kitchen","minutes":30,"standards":[{"id":"s1","text":"Hob clean"},{"id":"s2","text":"Sink clean"}]},
    {"id":"x2","name":"Hall","minutes":30,"standards":[{"id":"s1","text":"Floor swept"}]},
    {"id":"x3","name":"Garden path","minutes":20,"standards":[]}]}]'::jsonb);
  select * into ws from public.work_schedules where quote_id = (f ->> 'quote')::uuid;
  perform tests.eq((select count(*) from jsonb_array_elements(ws.plan -> 'sections' -> 0 -> 'subsections') ss, jsonb_array_elements(ss -> 'areas') a), 4::bigint,
                   'standards that share an id across areas still give unique cleaning areas, and an area with none is one cleaning area');
  perform tests.eq((select string_agg(a ->> 'id', ',' order by a ->> 'id') from jsonb_array_elements(ws.plan -> 'sections' -> 0 -> 'subsections') ss, jsonb_array_elements(ss -> 'areas') a), 'd1,d2,d3,d4', 'numbered d1 to d4');
  perform tests.ok((select a ->> 'name' from jsonb_array_elements(ws.plan -> 'sections' -> 0 -> 'subsections' -> 2 -> 'areas') a) = 'Garden path', 'the area with no standards is named for the area');
  perform tests.eq(ws.legend -> 'clean' ->> 'minutes', '20', '80 minutes across four areas: 20 each');

  f := pg_temp.book_custom('[]'::jsonb);
  perform tests.eq((select count(*) from public.work_schedules where quote_id = (f ->> 'quote')::uuid), 0::bigint, 'a brief with nothing in it gets no schedule');
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.eq(public.job_check_mode((f ->> 'job')::uuid), 'standards', 'and its job keeps the standards check');
  perform tests.as_su();

end $$;

-- A vendor's schedule with sub-sections linked to brief areas: the client's standards come along.
do $$
declare
  f jsonb; job uuid; ws public.work_schedules; mon timestamptz := pg_temp.next_monday(); n bigint; r record;
  brief_s jsonb := '[{"name":"Gym","areas":[
    {"id":"a1","name":"Showers","minutes":30,"standards":[{"id":"s1","text":"Drains clear"},{"id":"s2","text":"Walls dry"}]},
    {"id":"a2","name":"Lockers","minutes":30,"standards":[{"id":"s3","text":"Tops wiped"}]}]}]';
  plan jsonb := '{"sections":[{"id":"s1","name":"Changing room","subsections":[
    {"id":"g1","name":"Showers","brief_area_id":"a1","areas":[{"id":"r1","name":"Shower drains","days":{"mon":"scrub","tue":"scrub"}}]},
    {"id":"g2","name":"Lockers","brief_area_id":null,"areas":[{"id":"r2","name":"Locker tops","days":{"mon":"scrub"}}]}]}]}';
  legend jsonb := '{"scrub":{"label":"Scrub","minutes":10}}';
begin
  f := pg_temp.book_custom(brief_s, plan, legend, mon); job := (f ->> 'job')::uuid;
  select * into ws from public.work_schedules where quote_id = (f ->> 'quote')::uuid;
  perform tests.eq(ws.status, 'locked', 'the vendor''s schedule locked even though it never set minutes for the placeholder method');
  perform tests.eq((select string_agg(a ->> 'id', ',' order by ord) from jsonb_array_elements(ws.plan -> 'sections' -> 0 -> 'subsections' -> 0 -> 'areas') with ordinality t(a, ord)), 'r1,std-1,std-2',
                   'the linked sub-section carries the two standards of its brief area after the vendor''s own area');
  perform tests.eq((select string_agg(a ->> 'name', ',' order by ord) from jsonb_array_elements(ws.plan -> 'sections' -> 0 -> 'subsections' -> 0 -> 'areas') with ordinality t(a, ord) where a ->> 'standard' = 'true'), 'Drains clear,Walls dry', 'with the client''s words');
  perform tests.eq(jsonb_array_length(ws.plan -> 'sections' -> 0 -> 'subsections' -> 1 -> 'areas'), 1, 'a sub-section with no link carries nothing');
  perform tests.eq((select string_agg(k, ',' order by k) from jsonb_object_keys(ws.plan -> 'sections' -> 0 -> 'subsections' -> 0 -> 'areas' -> 1 -> 'days') k), 'mon,tue', 'on the days the sub-section is worked');

  perform tests.eq((select string_agg(item_id, ',' order by item_id) from private.job_planned_rows(job)), 'r1,r2,std-1,std-2', 'on Monday the visit has four rows');
  perform tests.eq(private.job_planned_minutes(job), 20, 'planned minutes are the vendor''s two areas: a standard adds none');

  -- The crew must tick the client's standards too, and the client judges them.
  perform tests.as_user((f ->> 'crew')::uuid);
  perform public.check_in(job, 51.8893, 0.9043);
  insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng) values
    (job, 'g1', 'photo_after', job || '/g1/1.jpg', 51.8893, 0.9043), (job, 'g2', 'photo_after', job || '/g2/1.jpg', 51.8893, 0.9043);
  insert into public.plan_results (job_id, plan_item_id, done) values (job, 'r1', true), (job, 'r2', true);
  perform tests.throws(format('select public.complete_job(%L)', job), '%2 cleaning area(s) still need ticking%', 'the vendor''s areas are ticked but the two standards are not: cannot finish');
  insert into public.plan_results (job_id, plan_item_id, done) values (job, 'std-1', true), (job, 'std-2', true);
  perform public.complete_job(job, 51.8893, 0.9043);
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.eq((select string_agg(item_id || ':' || method || ':' || planned_minutes, ',' order by item_id) from public.visit_area_times(job)), 'r1:scrub:10,r2:scrub:10,std-1:standard:0,std-2:standard:0',
                   'time between ticks shows a client standard as a standard with no planned minutes');
  update public.plan_results set verdict = 'met' where job_id = job and plan_item_id in ('r1', 'r2', 'std-1');
  perform tests.throws(format('select public.approve_job(%L)', job), '%Check every cleaning area%', 'the client has not judged the standard "Walls dry": cannot approve');
  insert into public.issues (job_id, kind, description, plan_item_id) values (job, 'quality', 'Walls were still wet', 'std-2');
  perform tests.eq((select plan_label from public.issues where plan_item_id = 'std-2' and job_id = job), 'Changing room > Showers > Walls dry', 'a complaint can name the client''s standard');
  perform tests.eq((select verdict from public.plan_results where job_id = job and plan_item_id = 'std-2'), 'not_met', 'and marks it not met');
  perform tests.as_su();

  -- The same plan on a Tuesday: the Showers sub-section is worked, the Lockers are not.
  f := pg_temp.book_custom(brief_s, plan, legend, mon + interval '1 day'); job := (f ->> 'job')::uuid;
  perform tests.eq((select string_agg(item_id, ',' order by item_id) from private.job_planned_rows(job)), 'r1,std-1,std-2', 'on Tuesday: the drains and the two standards, no lockers');
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.ok((select count(*) = 3 and bool_and(done_at is null) from public.visit_area_times(job)), 'a visit nobody has done yet lists its three rows with no times');
  perform tests.as_su();
end $$;
