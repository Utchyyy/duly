-- WFX: screening, candidate ranking, shift offers and responses, visibility, DBS.
do $$
declare
  f jsonb;
  v_vendor_u uuid; v_vendor_org uuid; v_other_org uuid; v_other_u uuid; v_buyer_u uuid; v_admin_u uuid;
  uA uuid := tests.mk_user('workerA'); uB uuid := tests.mk_user('workerB'); uC uuid := tests.mk_user('workerC'); uD uuid := tests.mk_user('workerD');
  wA uuid; wB uuid; wC uuid; wD uuid; wFar uuid;
  colch int; clacton int; shift_open uuid; shift_early uuid; shift_job uuid; ids uuid[]; app uuid; n bigint; r record;
begin
  f := tests.book_job('sme');
  v_vendor_u := (f ->> 'vendor')::uuid; v_vendor_org := (f ->> 'vendor_org')::uuid; v_buyer_u := (f ->> 'buyer')::uuid; v_admin_u := (f ->> 'admin')::uuid;
  select id into v_other_org from public.organisations where name = 'Colne Clean Co (sample)';
  v_other_u := tests.mk_user('othervendor');
  insert into public.memberships values (v_other_org, v_other_u, 'vendor_admin');
  select id into colch from public.towns where name = 'Colchester';
  select id into clacton from public.towns where name = 'Clacton-on-Sea';

  -- Workers. A: Colchester, employed, screened 100. B: Colchester, self-registered, screened 80.
  -- Far: Clacton (about 21 km away), will travel 30 km, screened 90. C: Clacton, will only travel 15 km.
  -- D: Colchester, screened 70, not available early.
  insert into public.workers (user_id, vendor_org_id, full_name, home_town_id, max_commute_km, available_early, available_evening)
    values (uA, v_vendor_org, 'Worker A', colch, 15, true, true) returning id into wA;
  insert into public.workers (user_id, full_name, home_town_id, max_commute_km, available_early) values (uB, 'Worker B', colch, 15, true) returning id into wB;
  insert into public.workers (vendor_org_id, full_name, home_town_id, max_commute_km, available_early) values (v_vendor_org, 'Worker Far', clacton, 30, true) returning id into wFar;
  insert into public.workers (vendor_org_id, full_name, home_town_id, max_commute_km, available_early) values (v_vendor_org, 'Worker C', clacton, 15, true) returning id into wC;
  insert into public.workers (user_id, vendor_org_id, full_name, home_town_id, max_commute_km, available_early) values (uD, v_vendor_org, 'Worker D', colch, 15, false) returning id into wD;
  insert into public.wiix_screens (worker_id, reliability, shift_fit, capability, commute_tolerance) values
    (wA, 5, 5, 5, 5), (wB, 4, 4, 4, 4), (wFar, 5, 4, 5, 4), (wC, 5, 5, 5, 5), (wD, 3, 4, 3, 4);
  perform tests.eq((select wiix_score from public.wiix_screens where worker_id = wA), 100.00::numeric, 'WIIx score 5,5,5,5 = 100');
  perform tests.eq((select wiix_score from public.wiix_screens where worker_id = wB), 80.00::numeric, 'WIIx score 4,4,4,4 = 80');
  perform tests.eq((select wiix_score from public.wiix_screens where worker_id = wD), 70.00::numeric, 'WIIx score 3,4,3,4 = 70');

  -- Workers cannot screen themselves or clear their own DBS.
  perform tests.as_user(uB);
  update public.wiix_screens set reliability = 5, shift_fit = 5, capability = 5, commute_tolerance = 5 where worker_id = wB;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'a worker cannot rewrite their own screening');
  perform tests.throws(format('update public.workers set dbs_cleared = true where id = %L', wB), '%DBS workflow%', 'a worker cannot clear their own DBS');
  perform tests.throws(format('insert into public.workers (user_id, full_name, dbs_cleared) values (%L, %L, true)', uC, 'Sneaky'),
                       '%row-level security%', 'cannot self-register as DBS cleared');
  perform tests.throws(format('update public.workers set vendor_org_id = %L where id = %L', v_vendor_org, wB),
                       '%Only the company can add you%', 'a worker cannot attach themselves to a company');
  perform tests.as_su();

  -- Candidate ranking: eligible by commute and availability, ordered by WIIx minus distance.
  insert into public.shifts (vendor_org_id, town_id, shift_date, start_time, end_time, hourly_pay)
    values (v_vendor_org, colch, current_date + 3, '09:00', '13:00', 13.50) returning id into shift_open;
  insert into public.shifts (vendor_org_id, town_id, shift_date, start_time, end_time, hourly_pay)
    values (v_vendor_org, colch, current_date + 3, '06:00', '10:00', 13.50) returning id into shift_early;
  perform tests.as_user(v_vendor_u);
  select array_agg(worker_id order by rank_score desc) into ids from public.rank_candidates(shift_open);
  perform tests.eq(ids, array[wA, wFar, wB, wD], 'day shift: ranked A (100), Far (90 minus distance), B (80), D (70); C is too far');
  select * into r from public.rank_candidates(shift_open) where worker_id = wFar;
  perform tests.eq(r.band, 'Corridor', 'a 21 km placement is a Corridor placement');
  perform tests.eq(r.paid_minutes, 30, 'Corridor placements pay 30 minutes of travel');
  perform tests.eq(r.cross_town, true, 'a worker from another town is flagged cross-town');
  select * into r from public.rank_candidates(shift_open) where worker_id = wA;
  perform tests.eq(r.band, 'Local', 'a same-town placement is Local');
  perform tests.eq(r.paid_minutes, 0, 'Local placements pay no travel');
  select array_agg(worker_id order by rank_score desc) into ids from public.rank_candidates(shift_early);
  perform tests.eq(ids, array[wA, wFar, wB], 'early shift excludes workers who are not available early');
  perform tests.as_user(v_buyer_u);
  perform tests.throws(format('select * from public.rank_candidates(%L)', shift_open), '%Not allowed%', 'a buyer cannot rank candidates');
  perform tests.as_user(v_other_u);
  perform tests.throws(format('select * from public.rank_candidates(%L)', shift_open), '%Not allowed%', 'another vendor cannot rank candidates');

  -- Offers: only the vendor's staff, once per worker.
  perform tests.as_user(uA);
  perform tests.throws(format('select public.offer_shift(%L, %L)', shift_open, wB), '%Not allowed%', 'a worker cannot offer shifts');
  perform tests.as_user(v_other_u);
  perform tests.throws(format('select public.offer_shift(%L, %L)', shift_open, wB), '%Not allowed%', 'another vendor cannot offer this shift');
  perform tests.as_user(v_vendor_u);
  perform public.offer_shift(shift_open, wA);
  perform public.offer_shift(shift_open, wB);
  perform tests.throws(format('select public.offer_shift(%L, %L)', shift_open, wA), '%Already offered%', 'a worker is offered a shift only once');
  perform tests.as_su();
  perform tests.eq((select status::text from public.shifts where id = shift_open), 'offered', 'the first offer moves the shift to offered');

  -- Responding: only if offered; first to accept fills it.
  perform tests.as_user(uD);
  perform tests.throws(format('select public.respond_to_shift(%L, true)', shift_open), '%not offered to you%', 'a worker who was not offered cannot accept');
  perform tests.as_user(uC);
  perform tests.throws(format('select public.respond_to_shift(%L, true)', shift_open), '%Join Duly Crew%', 'a user with no worker record cannot respond');
  perform tests.as_user(uA);
  perform public.respond_to_shift(shift_open, true);
  perform tests.as_user(uB);
  perform tests.throws(format('select public.respond_to_shift(%L, true)', shift_open), '%already been filled%', 'the second worker to accept is told the shift is filled');
  perform tests.as_su();
  perform tests.eq((select status::text from public.shifts where id = shift_open), 'filled', 'the shift is filled');
  perform tests.eq((select filled_by from public.shifts where id = shift_open), wA, 'filled by the first to accept');
  perform tests.eq((select array_agg(event_type order by occurred_at, event_type) from public.shift_events where shift_id = shift_open and worker_id = wA),
                   array['accepted', 'offered'], 'offer and acceptance are recorded');

  -- A shift linked to a job puts the worker on that job.
  insert into public.shifts (vendor_org_id, job_id, town_id, shift_date, start_time, end_time, hourly_pay)
    values (v_vendor_org, (f ->> 'job')::uuid, colch, current_date + 1, '09:00', '11:00', 13.50) returning id into shift_job;
  perform tests.as_user(v_vendor_u);
  perform public.offer_shift(shift_job, wA);
  perform tests.as_user(uA);
  perform tests.eq((select count(*) from public.jobs where id = (f ->> 'job')::uuid), 0::bigint, 'before accepting, the worker cannot see the job');
  perform public.respond_to_shift(shift_job, true);
  perform tests.eq((select count(*) from public.jobs where id = (f ->> 'job')::uuid), 1::bigint, 'after accepting, the worker can see the job');
  perform tests.as_su();
  perform tests.eq((select role from public.job_assignments where job_id = (f ->> 'job')::uuid and user_id = uA), 'crew', 'the extra worker joins as crew (the lead is already assigned)');

  -- Visibility: open shifts to any registered worker; filled shifts only to those involved; never to buyers or other vendors.
  insert into public.shifts (vendor_org_id, town_id, shift_date, start_time, end_time, hourly_pay)
    values (v_vendor_org, colch, current_date + 5, '09:00', '12:00', 13.50) returning id into shift_early;
  perform tests.as_user(uD);
  perform tests.eq((select count(*) from public.shifts where id = shift_early), 1::bigint, 'a registered worker sees an open shift');
  perform tests.eq((select count(*) from public.shifts where id = shift_open), 0::bigint, 'a worker not involved cannot see a filled shift');
  perform tests.as_user(uC);
  perform tests.eq((select count(*) from public.shifts), 0::bigint, 'a user with no worker record sees no shifts');
  perform tests.as_user(v_buyer_u);
  perform tests.eq((select count(*) from public.shifts), 0::bigint, 'a buyer sees no shifts');
  perform tests.as_user(v_other_u);
  perform tests.eq((select count(*) from public.shifts), 0::bigint, 'another vendor sees no shifts');
  perform tests.eq((select count(*) from public.shift_events), 0::bigint, 'another vendor sees no shift events');
  perform tests.eq((select count(*) from public.workers where id in (wA, wB, wFar, wC, wD)), 0::bigint, 'another vendor cannot see these workers');
  perform tests.as_user(v_vendor_u);
  perform tests.eq((select count(*) from public.workers where id in (wA, wB, wFar, wC, wD)), 5::bigint, 'the vendor sees its employees and the workers it has offered shifts to');

  -- DBS: the worker applies, Duly decides, clearance follows the decision.
  perform tests.as_user(uB);
  perform tests.throws(format('insert into public.dbs_applications (worker_id, path, status) values (%L, %L, %L)', wB, 'new_check', 'cleared'),
                       '%row-level security%', 'a worker cannot submit an application as already cleared');
  perform tests.throws(format('insert into public.dbs_applications (worker_id, path, certificate_type, update_service_id) values (%L, %L, %L, %L)', wB, 'existing_certificate', 'basic', 'U1'),
                       '%check constraint%', 'an existing certificate must be Standard or Enhanced');
  perform tests.throws(format('insert into public.dbs_applications (worker_id, path, certificate_type) values (%L, %L, %L)', wB, 'existing_certificate', 'enhanced'),
                       '%check constraint%', 'an existing certificate must be on the Update Service');
  insert into public.dbs_applications (worker_id, path) values (wB, 'new_check') returning id into app;
  update public.dbs_applications set status = 'cleared' where id = app;
  get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'a worker cannot clear their own application');
  perform tests.as_user(v_other_u);
  perform tests.eq((select count(*) from public.dbs_applications), 0::bigint, 'another vendor cannot see DBS applications');
  perform tests.as_user(v_admin_u);
  update public.dbs_applications set status = 'cleared' where id = app;
  perform tests.as_su();
  perform tests.eq((select dbs_cleared from public.workers where id = wB), true, 'Duly clearing the application clears the worker');
  perform tests.as_user(v_admin_u);
  update public.dbs_applications set status = 'not_cleared' where id = app;
  perform tests.as_su();
  perform tests.eq((select dbs_cleared from public.workers where id = wB), false, 'a later not-cleared decision removes clearance');
end $$;
