-- Operatives see only the jobs they are rostered on; vendor staff see the company's; tiers are enforced on quotes.
do $$
declare
  f jsonb; g jsonb; fj uuid; gj uuid; dispatcher uuid; vendor_org uuid; n bigint; extra uuid;
  v_admin uuid; unverified uuid; unv_org uuid; buyer uuid; org uuid; site uuid; brief uuid;
begin
  f := tests.book_job('sme');                       -- crew1 on job f
  g := tests.book_job('sme');                       -- crew2 on job g, same company
  fj := (f ->> 'job')::uuid; gj := (g ->> 'job')::uuid; vendor_org := (f ->> 'vendor_org')::uuid;
  dispatcher := tests.mk_user('dispatcher');
  insert into public.memberships values (vendor_org, dispatcher, 'dispatcher');
  perform tests.crew_completes(f);                  -- gives job f evidence, events, standards

  -- Crew 1 (on f) sees f but nothing of g, which belongs to the same company.
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.eq((select count(*) from public.jobs where id = fj), 1::bigint, 'crew sees the job they are rostered on');
  perform tests.eq((select count(*) from public.jobs where id = gj), 0::bigint, 'crew does not see a colleague''s job');
  perform tests.eq((select count(*) from public.sites where id = (g ->> 'site')::uuid), 0::bigint, 'crew does not see a colleague''s site');
  perform tests.eq((select count(*) from public.sites where id = (f ->> 'site')::uuid), 1::bigint, 'crew sees the site of their own job');
  perform tests.eq((select count(*) from public.brief_versions where brief_id = (f ->> 'brief')::uuid), 1::bigint, 'crew sees the brief of their own job');
  perform tests.eq((select count(*) from public.brief_versions where brief_id = (g ->> 'brief')::uuid), 0::bigint, 'crew does not see a colleague''s brief');
  perform tests.eq((select count(*) from public.quotes), 0::bigint, 'crew sees no quotes');
  perform tests.eq((select count(*) from public.contracts), 0::bigint, 'crew sees no contracts');
  perform tests.eq((select count(*) from public.payments), 0::bigint, 'crew sees no payments');

  -- Crew 2 (on g) sees g, nothing of f: not the job, evidence, ticks, events, files or issues.
  perform tests.as_user((g ->> 'crew')::uuid);
  perform tests.eq((select count(*) from public.jobs where id = gj), 1::bigint, 'the other crew sees their own job');
  perform tests.eq((select count(*) from public.jobs where id = fj), 0::bigint, 'the other crew does not see job f');
  perform tests.eq((select count(*) from public.evidence where job_id = fj), 0::bigint, 'no evidence rows from a colleague''s job');
  perform tests.eq((select count(*) from public.area_results where job_id = fj), 0::bigint, 'no ticks from a colleague''s job');
  perform tests.eq((select count(*) from public.job_events where job_id = fj), 0::bigint, 'no events from a colleague''s job');
  perform tests.eq((select count(*) from storage.objects where name like fj || '/%'), 0::bigint, 'no files from a colleague''s job');
  perform tests.throws(format('select public.check_in(%L, 51.8893, 0.9043)', fj), '%not on this job%', 'cannot check in to a colleague''s job');

  -- Vendor staff (admin and dispatcher) see all the company's jobs.
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.eq((select count(*) from public.jobs where id in (fj, gj)), 2::bigint, 'vendor admin sees every company job');
  perform tests.eq((select count(*) from public.quotes where id in ((f ->> 'quote')::uuid, (g ->> 'quote')::uuid)), 2::bigint, 'vendor admin sees the company''s quotes');
  perform tests.as_user(dispatcher);
  perform tests.eq((select count(*) from public.jobs where id in (fj, gj)), 2::bigint, 'dispatcher sees every company job');
  perform tests.eq((select count(*) from public.sites where id in ((f ->> 'site')::uuid, (g ->> 'site')::uuid)), 2::bigint, 'dispatcher sees the sites of company jobs');
  perform tests.eq((select count(*) from public.contracts where id in ((f ->> 'contract')::uuid, (g ->> 'contract')::uuid)), 2::bigint, 'dispatcher sees the company''s contracts');

  -- Clients still see their own job, and only that.
  perform tests.as_user((f ->> 'buyer')::uuid);
  perform tests.eq((select count(*) from public.jobs where id in (fj, gj)), 1::bigint, 'the client sees only their own job');

  -- Personal claims: an operative sees their own DBS / right-to-work claim, not colleagues'; staff see all.
  perform tests.as_su();
  insert into public.verification_claims (org_id, subject_user_id, kind) values
    (vendor_org, (f ->> 'crew')::uuid, 'dbs'), (vendor_org, (g ->> 'crew')::uuid, 'right_to_work');
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.eq((select count(*) from public.verification_claims where subject_user_id is not null), 1::bigint, 'an operative sees only their own personal claim');
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.ok((select count(*) from public.verification_claims where subject_user_id is not null) >= 2, 'vendor staff see the team''s claims');

  -- Shift pay: an operative who is a company member does not see other people's shifts.
  perform tests.as_su();
  insert into public.workers (user_id, vendor_org_id, full_name, home_town_id)
    values ((f ->> 'crew')::uuid, vendor_org, 'Crew One', (select id from public.towns where name = 'Colchester'));
  insert into public.shifts (vendor_org_id, town_id, shift_date, start_time, end_time, hourly_pay, status)
    values (vendor_org, (select id from public.towns where name = 'Colchester'), current_date + 2, '09:00', '12:00', 14.25, 'filled');
  perform tests.as_user((f ->> 'crew')::uuid);
  perform tests.eq((select count(*) from public.shifts where hourly_pay = 14.25), 0::bigint, 'an operative does not see a colleague''s filled shift or its pay');
  perform tests.as_user((f ->> 'vendor')::uuid);
  perform tests.eq((select count(*) from public.shifts where hourly_pay = 14.25), 1::bigint, 'vendor staff see shift pay');
  perform tests.as_su();
end $$;

-- Minimum verification tier is enforced on invitation and on acceptance, not only in ranking.
do $$
declare
  f jsonb; v_admin uuid; unv_org uuid; unv_user uuid; buyer uuid; site uuid; brief uuid; qid uuid; q2 uuid; job uuid;
begin
  f := tests.book_job('healthcare');                -- policy: minimum tier 2; Clean-Fit is tier 3 here
  v_admin := (f ->> 'admin')::uuid; buyer := (f ->> 'buyer')::uuid;
  site := (f ->> 'site')::uuid; brief := (f ->> 'brief')::uuid;
  insert into public.organisations (kind, name, verification_tier) values ('vendor', 'Unverified Ltd', 1) returning id into unv_org;
  insert into public.vendor_profiles (org_id, hourly_rate, base_lat, base_lng) values (unv_org, 15, 51.89, 0.90);
  unv_user := tests.mk_user('unverified');
  insert into public.memberships values (unv_org, unv_user, 'vendor_admin');

  perform tests.as_user(buyer);
  perform tests.throws(format('insert into public.quotes (brief_id, brief_version, vendor_org_id) values (%L, 1, %L)', brief, unv_org),
                       '%row-level security%', 'a healthcare client cannot invite a tier-1 vendor (minimum is 2)');
  perform tests.eq((select count(*) from public.quotes where vendor_org_id = unv_org), 0::bigint, 'no quote request was created');

  -- Raise the vendor to the required tier: the same invitation now works.
  perform tests.as_user(v_admin);
  update public.organisations set verification_tier = 2 where id = unv_org;
  perform tests.as_user(buyer);
  insert into public.quotes (brief_id, brief_version, vendor_org_id) values (brief, 1, unv_org) returning id into qid;
  perform tests.as_user(unv_user);
  perform public.submit_quote(qid);

  -- Tier drops (e.g. insurance expires) before the client accepts: acceptance is refused.
  perform tests.as_user(v_admin);
  update public.organisations set verification_tier = 1 where id = unv_org;
  perform tests.as_user(buyer);
  perform tests.throws(format('select public.accept_quote(%L, now() + interval %L)', qid, '1 day'),
                       '%not verified to the level%', 'accepting a quote from a vendor that fell below the minimum tier is refused');
  perform tests.as_su();
  perform tests.eq((select status::text from public.quotes where id = qid), 'submitted', 'the quote stays submitted');
  perform tests.eq((select count(*) from public.jobs where quote_id = qid), 0::bigint, 'no job was created');

  -- Duly can still override for a specific case.
  perform tests.as_user(v_admin);
  job := public.accept_quote(qid, now() + interval '1 day');
  perform tests.as_su();
  perform tests.ok(job is not null, 'a platform admin can override the tier check');
end $$;
