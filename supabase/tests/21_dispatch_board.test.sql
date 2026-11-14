-- The vendor dispatch board: every visit, who is on it, and what needs attention, worked out in SQL.
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
declare
  vend uuid; disp uuid := tests.mk_user('dispatcher'); crew2 uuid := tests.mk_user('crew2'); stranger uuid := tests.mk_user('stranger-db');
  a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; f jsonb; g jsonb; k jsonb; i jsonb; jx jsonb;
  ja uuid; jb uuid; jc uuid; jd uuid; je uuid; jf uuid; jg uuid; jh uuid; ji uuid; jj uuid; jk uuid;
  crewa uuid; adm uuid; vendor_user uuid; issue uuid; n integer; r record; s text;
begin
  insert into public.organisations (kind, name, segment) values ('vendor', 'Dispatch Vendor', 'sme') returning id into vend;
  a := pg_temp.book_with_plan(now() + interval '3 hours');   ja := (a ->> 'job')::uuid; crewa := (a ->> 'crew')::uuid; adm := (a ->> 'admin')::uuid; vendor_user := (a ->> 'vendor')::uuid;
  b := pg_temp.book_with_plan(now() + interval '5 hours');   jb := (b ->> 'job')::uuid;
  c := pg_temp.book_with_plan(now() + interval '4 hours');   jc := (c ->> 'job')::uuid;
  d := pg_temp.book_with_plan(now() + interval '30 hours');  jd := (d ->> 'job')::uuid;
  e := pg_temp.book_with_plan(now() - interval '1 hour');    je := (e ->> 'job')::uuid;
  f := pg_temp.book_with_plan(now() - interval '3 hours');   jf := (f ->> 'job')::uuid;
  g := pg_temp.book_with_plan(now() - interval '1 day');     jg := (g ->> 'job')::uuid;
  i := pg_temp.book_with_plan(now() + interval '6 hours');   ji := (i ->> 'job')::uuid;
  jx := pg_temp.book_with_plan(now() + interval '40 days');  jj := (jx ->> 'job')::uuid;
  k := pg_temp.book_with_plan(now() - interval '10 days');   jk := (k ->> 'job')::uuid;

  -- G: the cleaner finishes, the client reports a problem on one area, and the vendor books a rework visit two days out.
  perform pg_temp.crew_finishes(g);
  perform tests.as_user((g ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description, plan_item_id) values (jg, 'quality', 'Walls still dirty', 'r2') returning id into issue;
  perform tests.as_user((g ->> 'vendor')::uuid);
  jh := public.book_rework(issue, now() + interval '2 days');
  perform tests.as_su();

  -- F is in progress and past its planned end: the cleaner checked in three hours ago.
  perform tests.as_user((f ->> 'crew')::uuid); perform public.check_in(jf, 51.8893, 0.9043); perform tests.as_su();
  update public.job_events set at = now() - interval '3 hours' where job_id = jf and kind = 'check_in';

  -- Everything belongs to the dispatch vendor. One shared cleaner is on A, C (overlapping), D, E, F and G; B, H, K have nobody; I is cancelled.
  update public.jobs set vendor_org_id = vend where id in (ja, jb, jc, jd, je, jf, jg, jh, ji, jj, jk);
  update public.jobs set status = 'cancelled' where id = ji;
  delete from public.job_assignments where job_id in (ja, jb, jc, jd, je, jf, jg, jh, ji, jj, jk);
  insert into public.job_assignments (job_id, user_id, role) select x, crewa, 'lead' from unnest(array[ja, jc, jd, je, jf, jg]) x;
  insert into public.memberships values (vend, disp, 'dispatcher'), (vend, crewa, 'operative'), (vend, crew2, 'operative'), (vend, vendor_user, 'vendor_admin');

  -- The board, as the dispatcher: attention first (oldest first), then the rest in time order.
  perform tests.as_user(disp);
  select string_agg(coalesce(attention, '-'), ',' order by ord) into s from (select row_number() over () as ord, x.attention from public.dispatch_board(vend, current_date - 2, current_date + 7) x) q;
  perform tests.eq(s, 'late,held,overrunning,late,crew_clash,crew_clash,no_crew,no_crew,-', 'attention first, oldest first, then the rest: K late, G held, F overrunning, E late, A and C clash, B and H nobody, D fine');
  select count(*) into n from public.dispatch_board(vend, current_date - 2, current_date + 7);
  perform tests.eq(n, 9, 'nine visits: the cancelled one and the one 40 days out are left out, and the unfinished one from before the range is kept');
  perform tests.eq((select count(*) from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id in (ji, jj)), 0::bigint, 'cancelled and out-of-range visits are not shown');

  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = je;
  perform tests.eq(r.attention, 'late', 'booked, not checked in, past the tolerance: late');
  perform tests.ok(r.late_minutes >= 60, 'with the minutes late');
  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = jk;
  perform tests.ok(r.attention = 'late' and r.late_minutes > 14000, 'an unfinished visit from ten days ago is still shown, as very late');
  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = jf;
  perform tests.ok(r.overrunning and r.status = 'in_progress' and r.on_site_minutes >= 179, 'in progress and past its planned end: overrunning, with the minutes on site');
  perform tests.ok(r.checked_in_at is not null and r.late_minutes is null, 'a visit that was checked in is not late');
  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = jg;
  perform tests.ok(r.held and r.attention = 'held', 'a complaint holds the visit');
  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = jb;
  perform tests.ok(r.needs_crew and r.attention = 'no_crew' and r.crew = '[]'::jsonb, 'a visit with nobody assigned needs crew');
  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = ja;
  perform tests.ok(r.crew_clash and r.attention = 'crew_clash' and jsonb_array_length(r.crew) = 1, 'a cleaner on two overlapping visits is a clash');
  perform tests.eq(r.crew -> 0 ->> 'role', 'lead', 'the crew list says who leads');
  perform tests.eq(r.planned_minutes, 19, 'planned minutes come from the work schedule');
  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = jd;
  perform tests.ok(r.attention is null and not r.crew_clash and not r.needs_crew, 'a visit with its own cleaner at a clear time needs nothing');
  select * into r from public.dispatch_board(vend, current_date - 2, current_date + 7) where job_id = jh;
  perform tests.ok(r.is_rework and r.rework_area = 'Changing room > Showers > Cubicle walls' and r.needs_crew, 'a rework visit is marked with its area, and needs crew like any other');

  -- Crew load: lightest first.
  select string_agg(visits || ':' || scheduled_minutes || ':' || on_a_visit, ',' order by ord) into s from (select row_number() over () as ord, x.* from public.dispatch_crew(vend, current_date - 2, current_date + 7) x) q;
  perform tests.eq(s, '0:0:false,6:540:true', 'the cleaner with nothing booked is first; the busy one has six visits, 540 minutes and is on a visit now');
  perform tests.ok((select next_visit from public.dispatch_crew(vend, current_date - 2, current_date + 7) where user_id = crewa) is not null, 'and has a next visit');
  perform tests.ok((select name from public.dispatch_crew(vend, current_date - 2, current_date + 7) where user_id = crew2) is not null, 'every cleaner has a name');

  -- Who can see it.
  perform tests.as_user(vendor_user);
  perform tests.ok((select count(*) from public.dispatch_board(vend, current_date - 2, current_date + 7)) = 9, 'a vendor admin can');
  perform tests.as_user(adm);
  perform tests.ok((select count(*) from public.dispatch_board(vend, current_date - 2, current_date + 7)) = 9, 'and Duly can');
  perform tests.as_user(crewa);
  perform tests.throws(format('select * from public.dispatch_board(%L, current_date, current_date + 7)', vend), '%Not allowed%', 'a cleaner cannot see the board');
  perform tests.throws(format('select * from public.dispatch_crew(%L, current_date, current_date + 7)', vend), '%Not allowed%', 'nor the crew load');
  perform tests.as_user((a ->> 'buyer')::uuid);
  perform tests.throws(format('select * from public.dispatch_board(%L, current_date, current_date + 7)', vend), '%Not allowed%', 'a client cannot');
  perform tests.as_user(stranger);
  perform tests.throws(format('select * from public.dispatch_board(%L, current_date, current_date + 7)', vend), '%Not allowed%', 'nor a stranger');
  perform tests.as_user((b ->> 'vendor')::uuid);
  perform tests.throws(format('select * from public.dispatch_board(%L, current_date, current_date + 7)', vend), '%Not allowed%', 'nor another vendor''s staff (this one only belongs to Clean-Fit)');
end $$;
