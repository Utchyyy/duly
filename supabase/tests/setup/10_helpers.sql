-- Test helpers, applied after the migrations. Everything lives in the `tests` schema.
create schema tests;
grant usage on schema tests to public;

-- Act as a signed-in user (RLS applies) or as the superuser (fixtures).
create function tests.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, false);
  perform set_config('request.jwt.claim.role', 'authenticated', false);
  execute 'reset role'; execute 'set role authenticated';
end $$;
create function tests.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', 'anon', false);
  execute 'reset role'; execute 'set role anon';
end $$;
create function tests.as_su() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', '', false);
  execute 'reset role';
end $$;

create function tests.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

create function tests.eq(actual anyelement, expected anyelement, msg text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL: % (expected %, got %)', msg, expected, actual;
  end if;
  raise notice 'ok - %', msg;
end $$;

-- The statement must raise an error whose message matches the (ILIKE) pattern.
create function tests.throws(stmt text, pattern text, msg text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if sqlerrm ilike pattern then raise notice 'ok - %', msg; return; end if;
    raise exception 'FAIL: % (wanted error like "%", got "%")', msg, pattern, sqlerrm;
  end;
  raise exception 'FAIL: % (no error raised)', msg;
end $$;

create function tests.mk_user(p_name text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform tests.as_su();
  insert into auth.users (email) values (p_name || '-' || gen_random_uuid() || '@test.invalid') returning id into v;
  return v;
end $$;

-- Builds a booked job: a buyer in `p_segment` briefs the sample vendor Clean-Fit, the vendor quotes
-- (priced by price_quote), the buyer accepts and the vendor assigns a crew member.
-- Brief: two areas, 60 + 30 minutes, three standards. Vendor rate 20/h, so the quote is 30.00.
-- Returns every id a test needs. Leaves the session as superuser.
create function tests.book_job(p_segment text default 'sme', p_days text[] default null, p_start time default null)
returns jsonb language plpgsql as $$
declare
  admin_u uuid := tests.mk_user('admin');
  buyer_u uuid := tests.mk_user('buyer');
  vendor_u uuid := tests.mk_user('vendor');
  crew_u uuid := tests.mk_user('crew');
  duly_org uuid; vendor_org uuid; buyer_org uuid; site uuid; brief uuid; quote uuid; job uuid; contract uuid;
begin
  select id into duly_org from public.organisations where kind = 'platform';
  select id into vendor_org from public.organisations where name = 'Clean-Fit';
  insert into public.memberships values (duly_org, admin_u, 'platform_admin'),
    (vendor_org, vendor_u, 'vendor_admin'), (vendor_org, crew_u, 'operative');
  insert into public.vendor_profiles (org_id, hourly_rate, base_lat, base_lng) values (vendor_org, 20, 51.89, 0.90)
    on conflict (org_id) do update set hourly_rate = 20;
  -- Clean-Fit is a verified vendor in these tests (Duly raises the tier, as it would in Admin).
  perform tests.as_user(admin_u);
  update public.organisations set verification_tier = 3 where id = vendor_org;
  perform tests.as_su();

  perform tests.as_user(buyer_u);
  buyer_org := public.create_buyer_org('Test buyer', p_segment);
  insert into public.sites (org_id, name, town, postcode, lat, lng, geofence_m)
    values (buyer_org, 'Site', 'Colchester', 'CO1 1AA', 51.8892, 0.9042, 150) returning id into site;
  insert into public.briefs (buyer_org_id, site_id, title) values (buyer_org, site, 'Clean') returning id into brief;
  insert into public.brief_versions (brief_id, version, visits_per_week, preferred_days, preferred_start, schedule)
  values (brief, 1, 1, p_days, p_start, '[{"name":"Clinical","areas":[
    {"id":"a1","name":"Surgery","minutes":60,"standards":[{"id":"s1","text":"Floors clean"},{"id":"s2","text":"Surfaces wiped"}]},
    {"id":"a2","name":"Reception","minutes":30,"standards":[{"id":"s3","text":"Bins empty"}]}]}]'::jsonb);
  update public.brief_versions set locked_at = now(), locked_by = auth.uid() where brief_id = brief and version = 1;
  insert into public.quotes (brief_id, brief_version, vendor_org_id) values (brief, 1, vendor_org) returning id into quote;

  perform tests.as_user(vendor_u);
  perform public.submit_quote(quote);

  perform tests.as_user(buyer_u);
  job := public.accept_quote(quote, now() + interval '1 day');
  select contract_id into contract from public.jobs where id = job;

  perform tests.as_user(vendor_u);
  insert into public.job_assignments (job_id, user_id, role) values (job, crew_u, 'lead');

  perform tests.as_su();
  return jsonb_build_object('admin', admin_u, 'buyer', buyer_u, 'vendor', vendor_u, 'crew', crew_u,
    'buyer_org', buyer_org, 'vendor_org', vendor_org, 'duly_org', duly_org, 'site', site, 'brief', brief,
    'quote', quote, 'job', job, 'contract', contract);
end $$;

-- Crew checks in on site and does the whole checklist the job has: with a work schedule (the vendor's, or the one Duly builds from the
-- brief) a tick for every planned cleaning area and an after photo for every part; with none, the brief's standards. Then completes.
create function tests.crew_completes(f jsonb) returns void language plpgsql as $$
declare
  v_job uuid := (f ->> 'job')::uuid; v_items text[]; v_groups text[]; x text;
begin
  perform tests.as_su();
  select coalesce(array_agg(item_id), '{}'), coalesce(array_agg(distinct group_id), '{}') into v_items, v_groups from private.job_planned_rows(v_job);
  perform tests.as_user((f ->> 'crew')::uuid);
  perform public.check_in(v_job, 51.8893, 0.9043);
  if cardinality(v_items) > 0 then
    foreach x in array v_items loop insert into public.plan_results (job_id, plan_item_id, done) values (v_job, x, true); end loop;
    foreach x in array v_groups loop
      insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng) values (v_job, x, 'photo_after', v_job || '/' || x || '/1.jpg', 51.8893, 0.9043);
    end loop;
  else
    insert into public.evidence (job_id, area_id, kind, storage_path, lat, lng) values
      (v_job, 'a1', 'photo_after', v_job || '/a1/1.jpg', 51.8893, 0.9043),
      (v_job, 'a2', 'photo_after', v_job || '/a2/1.jpg', 51.8893, 0.9043);
    insert into public.area_results (job_id, area_id, standard_id, done_by_operative) values
      (v_job, 'a1', 's1', true), (v_job, 'a1', 's2', true), (v_job, 'a2', 's3', true);
  end if;
  perform public.complete_job(v_job, 51.8893, 0.9043);
  perform tests.as_su();
end $$;

-- The client marks every cleaning area or standard met and approves.
create function tests.buyer_approves(f jsonb) returns void language plpgsql as $$
begin
  perform tests.as_user((f ->> 'buyer')::uuid);
  update public.plan_results set verdict = 'met' where job_id = (f ->> 'job')::uuid;
  update public.area_results set verdict = 'met' where job_id = (f ->> 'job')::uuid;
  perform public.approve_job((f ->> 'job')::uuid);
  perform tests.as_su();
end $$;

-- Takes away the schedule Duly builds from the brief when a quote is accepted, leaving a job on the older standards check. For tests of
-- that path, which still serves any job with no locked schedule.
create function tests.without_schedule(f jsonb) returns jsonb language plpgsql as $$
begin
  perform tests.as_su();
  delete from public.work_schedules where quote_id = (f ->> 'quote')::uuid;
  return f;
end $$;
