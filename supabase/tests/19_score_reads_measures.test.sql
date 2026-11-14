-- The vendor score reads the operational measures (visit_metrics), with weights from policies.
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
  a jsonb; b jsonb; ja uuid; jb uuid; vend uuid; st timestamptz; s record; w jsonb;
begin
  insert into public.organisations (kind, name, segment) values ('vendor', 'Scored Vendor', 'sme') returning id into vend;

  a := pg_temp.book_with_plan(now() - interval '3 hours'); ja := (a ->> 'job')::uuid;
  b := pg_temp.book_with_plan(now() - interval '3 hours'); jb := (b ->> 'job')::uuid;
  perform pg_temp.crew_finishes(a);
  perform pg_temp.crew_finishes(b);
  perform tests.as_su();
  update public.jobs set vendor_org_id = vend where id in (ja, jb);
  -- Visit A arrives 5 minutes after the start (on time); visit B 20 minutes after (late, tolerance 15).
  select scheduled_start into st from public.jobs where id = ja;
  update public.job_events set at = st + interval '5 minutes' where job_id = ja and kind = 'check_in';
  update public.job_events set at = st + interval '20 minutes' where job_id = jb and kind = 'check_in';

  -- The client accepts all of A, and finds one of B's three areas not met.
  perform tests.as_user((a ->> 'buyer')::uuid);
  update public.plan_results set verdict = 'met' where job_id = ja;
  perform public.approve_job(ja);
  perform tests.as_user((b ->> 'buyer')::uuid);
  update public.plan_results set verdict = 'met' where job_id = jb and plan_item_id in ('r1', 'r2');
  update public.plan_results set verdict = 'not_met' where job_id = jb and plan_item_id = 'r3';
  perform tests.as_su();
  perform private.recompute_vendor_score(vend);

  select * into s from public.vendor_scores where org_id = vend;
  perform tests.eq(s.on_time_rate, 50.00::numeric, 'on time is read from the visit measures: one of two');
  perform tests.eq(s.right_first_time_rate, 50.00::numeric, 'right first time: the visit with a not-met area is not');
  perform tests.eq(s.plan_followed_rate, 100.00::numeric, 'every planned area was ticked');
  perform tests.eq(s.standards_met_rate, 83.33::numeric, 'plan verdicts now count towards standards met: five of six met');
  perform tests.eq(s.dispute_rate, 0.00::numeric, 'no visit had a complaint');
  perform tests.eq(s.repeat_client_rate, 0.00::numeric, 'no repeat client yet');

  select ranking_weights into w from public.policies p join public.organisations o on o.market = p.market and p.segment = o.segment where o.id = vend;
  perform tests.ok(w ? 'right_first_time' and w ? 'plan_followed', 'the policy carries the new weights');
  -- 0.25 x 0.8333 + 0.15 x 0.5 + 0.2 x 0.5 + 0.05 x 1 + 0.1 x 1 + 0.1 x 0 + 0.15 x 0 = 0.5333
  perform tests.eq(s.quality_score, 53.33::numeric, 'the score is the weighted sum, weights from policies');

  -- A policy tuned by hand that lacks the new keys still scores out of 100.
  update public.policies set ranking_weights = '{"standards_met":0.4,"on_time":0.2,"dispute_free":0.15,"repeat_clients":0.1,"verification":0.15}'::jsonb
   where (market, segment) = (select market, coalesce(segment, 'sme') from public.organisations where id = vend);
  perform private.recompute_vendor_score(vend);
  -- 0.4 x 0.8333 + 0.2 x 0.5 + 0.15 x 1 = 0.5833
  perform tests.eq((select quality_score from public.vendor_scores where org_id = vend), 58.33::numeric, 'an older set of weights still works');
  update public.policies set ranking_weights = '{"standards_met":1}'::jsonb
   where (market, segment) = (select market, coalesce(segment, 'sme') from public.organisations where id = vend);
  perform private.recompute_vendor_score(vend);
  perform tests.eq((select quality_score from public.vendor_scores where org_id = vend), 83.33::numeric, 'the score divides by the weights that apply: one weight, one rate');
  update public.policies set ranking_weights = '{"standards_met":0.25,"right_first_time":0.15,"on_time":0.2,"plan_followed":0.05,"dispute_free":0.1,"repeat_clients":0.1,"verification":0.15}'::jsonb
   where (market, segment) = (select market, coalesce(segment, 'sme') from public.organisations where id = vend);

  -- A complaint lowers the complaint-free share and the score.
  perform tests.as_user((b ->> 'buyer')::uuid);
  insert into public.issues (job_id, kind, description, plan_item_id) values (jb, 'quality', 'Walls still dirty', 'r2');
  insert into public.issues (job_id, kind, description) values (jb, 'safeguarding', 'Private concern');
  perform tests.as_su();
  select * into s from public.vendor_scores where org_id = vend;
  perform tests.eq(s.dispute_rate, 50.00::numeric, 'a complaint is counted once for its visit (safeguarding is not)');
  perform tests.eq(s.quality_score, 44.17::numeric, 'the score drops: complaint-free 0.1 x 0.5, and the complained area is marked not met so standards met is four of six (0.25 x 0.6667)');

end $$;
