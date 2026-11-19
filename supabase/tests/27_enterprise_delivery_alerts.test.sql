-- The Enterprise is told when a vendor's clean is late or missed: who, when, once, and never for anyone else.
create function pg_temp.n(p_user uuid, p_event text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and event = p_event $$;
create function pg_temp.key_any(p_key text) returns bigint language sql as $$
  select count(*) from public.notifications where dedupe_key = p_key $$;
create function pg_temp.k(p_user uuid, p_key text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and dedupe_key = p_key $$;

do $$
declare
  f jsonb; s jsonb; ent uuid; owner uuid; crew uuid; vendor_u uuid;
  approver uuid := tests.mk_user('ent-approver'); viewer uuid := tests.mk_user('ent-viewer');
  jl uuid[]; j1 uuid; j2 uuid; j3 uuid; j4 uuid; j5 uuid; j6 uuid; r record; n bigint;
begin
  f := tests.book_job('enterprise', array['mon','tue','wed','thu','fri','sat','sun'], '09:00');
  ent := (f ->> 'buyer_org')::uuid; owner := (f ->> 'buyer')::uuid; crew := (f ->> 'crew')::uuid; vendor_u := (f ->> 'vendor')::uuid;
  insert into public.memberships values (ent, approver, 'approver'), (ent, viewer, 'viewer');
  perform tests.as_user(owner); perform public.schedule_visits((f ->> 'contract')::uuid, 4); perform tests.as_su();
  select array_agg(id order by scheduled_start, id) into jl from public.jobs where buyer_org_id = ent and status <> 'cancelled';
  j1 := jl[1]; j2 := jl[2]; j3 := jl[3]; j4 := jl[4]; j5 := jl[5]; j6 := jl[6];
  update public.jobs set scheduled_start = scheduled_start + interval '40 days', scheduled_end = scheduled_end + interval '40 days' where buyer_org_id = ent and id <> all (jl[1:6]);
  delete from public.job_assignments where job_id = any (jl);
  insert into public.job_assignments (job_id, user_id, role) select x, crew, 'lead' from unnest(jl[1:6]) x;
  update public.jobs set scheduled_start = now() - interval '40 minutes', scheduled_end = now() + interval '80 minutes' where id = j1;   -- late
  update public.jobs set scheduled_start = now() - interval '3 hours',    scheduled_end = now() - interval '1 hour'    where id = j2;   -- missed
  update public.jobs set scheduled_start = now() - interval '5 minutes',  scheduled_end = now() + interval '115 minutes' where id = j3; -- inside the tolerance
  update public.jobs set scheduled_start = now() - interval '40 minutes', scheduled_end = now() + interval '80 minutes' where id = j4;   -- late, but checked in
  update public.jobs set scheduled_start = now() - interval '30 hours',   scheduled_end = now() - interval '28 hours'  where id = j5;   -- old history
  update public.jobs set scheduled_start = now() - interval '3 hours',    scheduled_end = now() - interval '1 hour', status = 'cancelled' where id = j6;
  insert into public.job_events (job_id, kind, data, at) values (j4, 'check_in', '{}', now() - interval '30 minutes');

  perform private.notify_due_items();

  -- Late.
  perform tests.eq(pg_temp.k(owner, 'ent-late:' || j1), 1::bigint, 'the Enterprise owner is told a booked clean is late');
  perform tests.eq(pg_temp.k(approver, 'ent-late:' || j1), 1::bigint, 'and so is an approver');
  perform tests.eq(pg_temp.k(viewer, 'ent-late:' || j1), 0::bigint, 'a viewer is not');
  perform tests.eq(pg_temp.k(vendor_u, 'ent-late:' || j1), 0::bigint, 'nor is the vendor (it has its own alert)');
  perform tests.eq(pg_temp.k(crew, 'ent-late:' || j1), 0::bigint, 'nor the cleaner');
  perform tests.eq(pg_temp.key_any('ent-late:' || j3), 0::bigint, 'a few minutes late is within the tolerance: nothing');
  perform tests.eq(pg_temp.key_any('ent-late:' || j4) + pg_temp.key_any('ent-missed:' || j4), 0::bigint, 'a clean that was checked into is not late or missed');
  perform tests.eq(pg_temp.n(owner, 'delivery_late'), 1::bigint, 'one late alert so far');

  -- Missed.
  perform tests.eq(pg_temp.k(owner, 'ent-missed:' || j2), 1::bigint, 'the owner is told a clean whose end has passed with nobody in was missed');
  perform tests.eq(pg_temp.k(approver, 'ent-missed:' || j2), 1::bigint, 'and the approver');
  perform tests.eq(pg_temp.k(viewer, 'ent-missed:' || j2), 0::bigint, 'not the viewer');
  perform tests.eq(pg_temp.key_any('ent-late:' || j2), 0::bigint, 'a clean already past its end is "missed", not also "late"');
  perform tests.eq(pg_temp.key_any('ent-late:' || j5) + pg_temp.key_any('ent-missed:' || j5), 0::bigint, 'history more than a day past its end is not announced');
  perform tests.eq(pg_temp.key_any('ent-late:' || j6) + pg_temp.key_any('ent-missed:' || j6), 0::bigint, 'a cancelled clean is not');

  -- What they say.
  select * into r from public.notifications where user_id = owner and dedupe_key = 'ent-late:' || j1;
  perform tests.eq(r.title, 'A clean is late', 'a plain title'); perform tests.eq(r.category, 'jobs', 'in the jobs category, so the existing email mute applies');
  perform tests.ok(r.body like '%Clean-Fit%' and r.body like '%Site%', 'it names the vendor and the site');
  perform tests.ok(r.body not like '%£%' and r.body not like '%CO1%' and r.body !~ '[0-9]+\.[0-9][0-9]', 'and carries no money or address');
  perform tests.eq(r.link, '/enterprise/delivery', 'and links to the Delivery view');
  perform tests.eq(r.org_id, ent, 'in the Enterprise''s name');
  select * into r from public.notifications where user_id = owner and dedupe_key = 'ent-missed:' || j2;
  perform tests.eq(r.title, 'A clean was missed', 'the missed one says so'); perform tests.ok(r.body like '%did not check in%', 'in plain words');

  -- Once only.
  perform private.notify_due_items();
  perform tests.eq(pg_temp.n(owner, 'delivery_late'), 1::bigint, 'running the scan again does not repeat the late alert');
  perform tests.eq(pg_temp.n(owner, 'delivery_missed'), 1::bigint, 'or the missed one');

  -- A late clean that is never attended becomes a missed one, as a second alert.
  update public.jobs set scheduled_start = now() - interval '3 hours', scheduled_end = now() - interval '1 hour' where id = j1;
  perform private.notify_due_items();
  perform tests.eq(pg_temp.k(owner, 'ent-late:' || j1), 1::bigint, 'the late alert stays');
  perform tests.eq(pg_temp.k(owner, 'ent-missed:' || j1), 1::bigint, 'and when the end passes, a missed one follows');
  perform tests.eq(pg_temp.n(owner, 'delivery_missed'), 2::bigint, 'two missed alerts for two missed cleans');

  -- Email follows each person's mute.
  select email_status into r from public.notifications where user_id = owner and dedupe_key = 'ent-late:' || j1; perform tests.eq(r.email_status, 'pending', 'an email is queued by default');
  perform tests.as_su();
  insert into public.notification_settings (user_id, email_muted) values (approver, array['jobs']);
  update public.jobs set scheduled_start = now() - interval '50 minutes', scheduled_end = now() + interval '70 minutes' where id = jl[7];
  insert into public.job_assignments (job_id, user_id, role) values (jl[7], crew, 'lead');
  perform private.notify_due_items();
  select email_status into r from public.notifications where user_id = approver and dedupe_key = 'ent-late:' || jl[7]; perform tests.eq(r.email_status, 'skipped', 'someone who muted job emails still sees it in the app but is not emailed');
  select email_status into r from public.notifications where user_id = owner and dedupe_key = 'ent-late:' || jl[7]; perform tests.eq(r.email_status, 'pending', 'while the owner is emailed');

  -- Only for an Enterprise.
  s := tests.book_job('sme');
  update public.jobs set scheduled_start = now() - interval '40 minutes', scheduled_end = now() + interval '80 minutes' where id = (s ->> 'job')::uuid;
  perform private.notify_due_items();
  perform tests.eq(pg_temp.key_any('ent-late:' || (s ->> 'job')), 0::bigint, 'another kind of buyer gets no Enterprise alert');
  perform tests.eq(pg_temp.k((s ->> 'vendor')::uuid, 'late:' || (s ->> 'job')), 1::bigint, 'and the vendor''s own late alert is untouched');
end $$;
