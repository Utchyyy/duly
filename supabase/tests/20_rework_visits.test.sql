-- Rework visits: a complaint on a cleaning area becomes a visit to put that area right.
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

-- The plan with r2 planned on Mondays only; the rest every day.
create function pg_temp.monday_plan() returns jsonb language sql as $$
  select ('{"sections":[{"id":"s1","name":"Changing room","subsections":['
    || '{"id":"g1","name":"Showers","brief_area_id":null,"areas":['
    || '{"id":"r1","name":"Shower drains","days":' || pg_temp.alldays('scrub') || '},'
    || '{"id":"r2","name":"Cubicle walls","days":{"mon":"wash"}}]},'
    || '{"id":"g2","name":"Lockers","brief_area_id":null,"areas":['
    || '{"id":"r3","name":"Locker tops","days":' || pg_temp.alldays('clean') || '}]}]}]}')::jsonb
$$;

-- A Monday at 10:00 in the market's timezone, next week, and the Wednesday after it.
create function pg_temp.next_monday() returns timestamptz language sql as $$
  select ((date_trunc('week', (now() at time zone 'Europe/London') + interval '7 days')::date) + time '10:00') at time zone 'Europe/London'
$$;

do $$
declare
  a jsonb; ja uuid; i1 uuid; rw uuid; vend uuid := (select id from public.organisations where name = 'Clean-Fit');
  crew uuid; vendor uuid; buyer uuid; stranger uuid := tests.mk_user('stranger-rw'); n integer; r record; mon timestamptz := pg_temp.next_monday();
begin
  a := pg_temp.book_with_plan(mon, pg_temp.monday_plan()); ja := (a ->> 'job')::uuid;
  crew := (a ->> 'crew')::uuid; vendor := (a ->> 'vendor')::uuid; buyer := (a ->> 'buyer')::uuid;
  perform pg_temp.crew_finishes(a);

  -- The client reports a problem on Cubicle walls: the visit is held and the area is not met.
  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description, plan_item_id) values (ja, 'quality', 'Walls still dirty', 'r2') returning id into i1;
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = ja), 'disputed', 'the complaint holds the original visit');
  perform tests.eq((select verdict from public.plan_results where job_id = ja and plan_item_id = 'r2'), 'not_met', 'and the area is not met');

  -- Who can book it.
  perform tests.as_user(buyer);
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''2 days'')', i1), '%Issue not found%', 'the client cannot book a rework');
  perform tests.as_user(stranger);
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''2 days'')', i1), '%Issue not found%', 'nor a stranger');
  perform tests.as_user(vendor);
  perform tests.throws(format('select public.book_rework(%L, now() - interval ''1 hour'')', i1), '%future%', 'a rework must be in the future');

  -- The vendor books it for the Wednesday after: the area is only planned on Mondays.
  rw := public.book_rework(i1, mon + interval '9 days' + interval '0 hours');
  perform tests.as_su();
  perform tests.eq((select status::text from public.issues where id = i1), 'vendor_fix', 'the complaint moves to vendor fix');
  select * into r from public.jobs where id = rw;
  perform tests.eq(r.rework_of_issue, i1, 'the rework visit is linked to the complaint');
  perform tests.ok(r.contract_id is null and r.value is null, 'it has no contract and no price');
  perform tests.eq(r.status::text, 'matched', 'it starts matched');
  perform tests.eq(extract(epoch from (r.scheduled_end - r.scheduled_start))::integer / 60, 30, 'it lasts 30 minutes (the area needs 6, the minimum is 30)');
  perform tests.eq((select count(*) from public.payments where job_id = rw), 0::bigint, 'and creates no payment');
  perform tests.eq(private.job_weekday(rw), 'mon', 'its weekday is the first the area is planned on');
  perform tests.eq((select string_agg(item_id, ',') from private.job_planned_rows(rw)), 'r2', 'its checklist is the one area');
  perform tests.eq(private.job_planned_minutes(rw), 6, 'planned at the vendor''s minutes for a wash');
  perform tests.eq((select count(*) from public.notifications where user_id = buyer and event = 'rework_booked'), 1::bigint, 'the client is told');

  perform tests.as_user(vendor);
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''3 days'')', i1), '%already booked%', 'only one rework at a time');
  insert into public.job_assignments (job_id, user_id, role) values (rw, crew, 'lead');

  -- The crew do it: only that area, with a photo.
  perform tests.as_user(crew);
  perform public.check_in(rw, 51.8893, 0.9043);
  perform tests.throws(format('insert into public.plan_results (job_id, plan_item_id, done) values (%L, ''r1'', true)', rw), '%not planned for this visit%', 'other areas are not part of a rework');
  insert into public.plan_results (job_id, plan_item_id, done) values (rw, 'r2', true);
  perform tests.throws(format('select public.complete_job(%L, 51.8893, 0.9043)', rw), '%after photo%', 'it needs an after photo');
  insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng, plan_item_id)
    values (rw, 'g1', 'photo_after', rw || '/g1/1.jpg', 51.8893, 0.9043, 'r2');
  perform public.complete_job(rw, 51.8893, 0.9043);

  -- The client cannot approve it for payment, and a stranger cannot review it.
  perform tests.as_user(buyer);
  perform tests.throws(format('select public.approve_job(%L)', rw), '%not approved for payment%', 'a rework is never approved for payment');
  perform tests.as_user(stranger);
  perform tests.throws(format('select public.review_rework(%L, true)', rw), '%Rework visit not found%', 'a stranger cannot review it');
  perform tests.as_user(vendor);
  perform tests.throws(format('select public.review_rework(%L, true)', rw), '%Rework visit not found%', 'and the vendor cannot mark its own work as accepted');

  -- The client accepts: the complaint is resolved and the original visit can be approved.
  perform tests.as_user(buyer);
  perform public.review_rework(rw, true, 'Looks clean now');
  perform tests.as_su();
  perform tests.eq((select status::text from public.issues where id = i1), 'resolved', 'the complaint is resolved');
  perform tests.eq((select resolution from public.issues where id = i1), 'Looks clean now', 'with the client''s note');
  perform tests.eq((select status::text from public.jobs where id = rw), 'quality_verified', 'the rework visit is accepted');
  perform tests.eq((select verdict from public.plan_results where job_id = ja and plan_item_id = 'r2'), 'met', 'the area is met on the original visit too');
  perform tests.eq((select status::text from public.jobs where id = ja), 'completed', 'the original visit is back to review');
  perform tests.as_user(buyer);
  update public.plan_results set verdict = 'met' where job_id = ja;
  perform public.approve_job(ja);
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = ja), 'quality_verified', 'and it can be approved: the money follows the policy');
  perform tests.eq((select count(*) from public.payments where job_id = rw), 0::bigint, 'the rework visit still has no payment');
end $$;

-- A rework that is not accepted goes to Duly. Refusals, and what the vendor's own rates leave out.
do $$
declare
  b jsonb; jb uuid; i2 uuid; i3 uuid; i4 uuid; i5 uuid; rw uuid; vendor uuid; buyer uuid; crew uuid; admin_u uuid; s record; w record; v uuid;
begin
  b := pg_temp.book_with_plan(now() - interval '3 hours'); jb := (b ->> 'job')::uuid;
  vendor := (b ->> 'vendor')::uuid; buyer := (b ->> 'buyer')::uuid; crew := (b ->> 'crew')::uuid; admin_u := (b ->> 'admin')::uuid;
  perform pg_temp.crew_finishes(b);

  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description, plan_item_id) values (jb, 'quality', 'Walls still dirty', 'r2') returning id into i2;
  insert into public.issues (job_id, kind, description, plan_item_id) values (jb, 'damage', 'Broken tile', 'r1') returning id into i3;
  insert into public.issues (job_id, kind, description) values (jb, 'quality', 'Smells in general') returning id into i4;
  insert into public.issues (job_id, kind, description) values (jb, 'safeguarding', 'Private concern') returning id into i5;

  perform tests.as_user(vendor);
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''2 days'')', i3), '%handles this kind of report%', 'damage is handled by Duly');
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''2 days'')', i4), '%name a cleaning area%', 'a complaint must name a cleaning area');
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''2 days'')', i5), '%Issue not found%', 'a safeguarding report is not even visible to the vendor');

  rw := public.book_rework(i2, now() + interval '2 days');
  perform tests.as_su();
  perform tests.as_user(vendor);
  insert into public.job_assignments (job_id, user_id, role) values (rw, crew, 'lead');
  perform tests.as_user(crew);
  perform public.check_in(rw, 51.8893, 0.9043);
  insert into public.plan_results (job_id, plan_item_id, done) values (rw, 'r2', true);
  insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng, plan_item_id) values (rw, 'g1', 'photo_after', rw || '/g1/1.jpg', 51.8893, 0.9043, 'r2');
  perform public.complete_job(rw, 51.8893, 0.9043);

  perform tests.as_user(vendor);
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''3 days'')', i2), '%already booked%', 'a finished rework still counts until it is reviewed');

  perform tests.as_user(buyer);
  perform public.review_rework(rw, false, 'Still marks on the walls');
  perform tests.as_su();
  perform tests.eq((select status::text from public.jobs where id = rw), 'disputed', 'a rejected rework is disputed');
  perform tests.eq((select status::text from public.issues where id = i2), 'mediation', 'and the complaint goes to Duly');
  perform tests.eq((select status::text from public.jobs where id = jb), 'disputed', 'the original visit stays held');
  perform tests.eq((select count(*) from public.job_events where job_id = rw and kind = 'note' and data ->> 'text' = 'Still marks on the walls'), 1::bigint, 'the client''s note is kept on the record');
  perform tests.as_user(vendor);
  perform tests.throws(format('select public.book_rework(%L, now() + interval ''3 days'')', i2), '%already mediation%', 'no more reworks once Duly has it');
  perform tests.as_user(admin_u);
  perform tests.ok((select count(*) from public.notifications where event = 'rework_rejected') >= 1, 'Duly and the vendor are told');

  -- The vendor's rates leave rework visits out.
  perform tests.as_su();
  insert into public.organisations (kind, name, segment) values ('vendor', 'Rework Vendor', 'sme') returning id into v;
  insert into public.memberships select v, vendor, 'vendor_admin' on conflict do nothing;
  update public.jobs set vendor_org_id = v where id in (jb, rw);
  perform tests.as_user(vendor);
  select * into s from public.vendor_operations(v, current_date - 30, current_date + 60);
  perform tests.eq(s.visits, 1, 'only the original visit counts as a visit: the rework is left out');
  perform tests.eq((select count(*) from public.vendor_visits(v, current_date - 30, current_date + 60)), 1::bigint, 'and in the recent visits list');
  select * into w from public.vendor_rework(v, current_date - 30, current_date + 60);
  perform tests.eq(w.complaints, 3, 'three complaints (safeguarding is not counted)');
  perform tests.eq(w.reworks_booked, 1, 'one rework visit booked');
  perform tests.eq(w.reworks_accepted, 0, 'none accepted');
  perform tests.eq(w.reworks_rejected, 1, 'one not accepted');
  perform tests.eq(w.reworks_open, 0, 'none still open');
  perform tests.eq(w.awaiting_rework, 0, 'nothing waiting for one: damage and unnamed areas are not eligible, and the named area is in mediation');
  perform tests.ok(w.avg_hours_to_put_right is null, 'no problem has been put right yet');
  perform tests.as_su();
  perform private.recompute_vendor_score(v);
  perform tests.eq((select jobs_completed from public.vendor_scores where org_id = v), 0, 'and the score counts no rework as a completed job');

  -- Who can see the report.
  perform tests.as_user(buyer);
  perform tests.throws(format('select * from public.vendor_rework(%L, current_date - 30, current_date + 60)', v), '%Not allowed%', 'a client cannot see a vendor''s rework report');
  perform tests.as_user(admin_u);
  perform tests.ok((select count(*) from public.vendor_rework(v, current_date - 30, current_date + 60)) = 1, 'Duly can');
end $$;
