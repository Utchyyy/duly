-- A closed month's SLA pack, frozen: when it freezes, what it keeps, who may freeze or read it, and that it can never change.

create function pg_temp.email_of(u uuid) returns text language sql security definer as $$ select email::text from auth.users where id = u $$;

do $$
declare
  f jsonb; ent uuid; ent2 uuid; vend uuid; buyer uuid; crew uuid; admin_u uuid; vendor_u uuid; tz text;
  owner2 uuid := tests.mk_user('ent2-owner'); approver uuid := tests.mk_user('ent1-approver'); viewer uuid := tests.mk_user('ent1-viewer'); stranger uuid := tests.mk_user('stranger-x');
  jl uuid[]; j1 uuid; j2 uuid; j3 uuid; j4 uuid; j5 uuid; j6 uuid; i1 uuid; n bigint; k integer; r record; live_before jsonb; m_end timestamptz;
  m date := date_trunc('month', now() - interval '2 months')::date;
begin
  f := tests.book_job('enterprise', array['mon','tue','wed','thu','fri','sat','sun'], '09:00');
  ent := (f ->> 'buyer_org')::uuid; vend := (f ->> 'vendor_org')::uuid; buyer := (f ->> 'buyer')::uuid; crew := (f ->> 'crew')::uuid;
  admin_u := (f ->> 'admin')::uuid; vendor_u := (f ->> 'vendor')::uuid;
  insert into public.memberships values (ent, approver, 'approver'), (ent, viewer, 'viewer');
  perform tests.as_user(admin_u); ent2 := public.admin_create_enterprise('Other Enterprise', pg_temp.email_of(owner2));
  perform public.enterprise_add_vendor(ent2, vend); perform tests.as_su();
  tz := coalesce((select mk.timezone from public.organisations o join public.markets mk on mk.code = o.market where o.id = ent), 'UTC');
  perform tests.as_user(buyer); perform public.schedule_visits((f ->> 'contract')::uuid, 4); perform tests.as_su();
  select array_agg(id order by scheduled_start, id) into jl from public.jobs where buyer_org_id = ent and status <> 'cancelled';
  j1 := jl[1]; j2 := jl[2]; j3 := jl[3]; j4 := jl[4]; j5 := jl[5]; j6 := jl[6];
  update public.jobs set scheduled_start = scheduled_start + interval '70 days', scheduled_end = scheduled_end + interval '70 days' where buyer_org_id = ent and id <> all (jl[1:6]);
  delete from public.job_assignments where job_id = any (jl);
  insert into public.job_assignments (job_id, user_id, role) values (j2, crew, 'lead'), (j3, crew, 'lead');
  update public.jobs set scheduled_start = (m + 2)::timestamptz + interval '10 hours', scheduled_end = (m + 2)::timestamptz + interval '12 hours' where id = j1;  -- missed
  update public.jobs set scheduled_start = (m + 3)::timestamptz + interval '10 hours', scheduled_end = (m + 3)::timestamptz + interval '12 hours' where id = j2;  -- late
  update public.jobs set scheduled_start = (m + 4)::timestamptz + interval '10 hours', scheduled_end = (m + 4)::timestamptz + interval '12 hours' where id = j3;  -- on time
  update public.jobs set scheduled_start = (m + 5)::timestamptz + interval '10 hours', scheduled_end = (m + 5)::timestamptz + interval '12 hours', status = 'cancelled' where id = j4;
  update public.jobs set scheduled_start = (m - 20)::timestamptz + interval '10 hours', scheduled_end = (m - 20)::timestamptz + interval '12 hours' where id = j5;  -- the month before: missed
  update public.jobs set scheduled_start = date_trunc('month', now())::timestamptz + interval '1 hour', scheduled_end = date_trunc('month', now())::timestamptz + interval '3 hours' where id = j6; -- this month
  perform tests.crew_completes(jsonb_build_object('job', j2, 'crew', crew));
  perform tests.crew_completes(jsonb_build_object('job', j3, 'crew', crew));
  update public.job_events e set at = (select scheduled_start + case when e.job_id = j2 then interval '40 minutes' else interval '5 minutes' end from public.jobs where id = e.job_id) where e.kind = 'check_in' and e.job_id in (j2, j3);
  update public.job_events e set at = (select scheduled_end - interval '10 minutes' from public.jobs where id = e.job_id) where e.kind = 'check_out' and e.job_id in (j2, j3);
  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description) values (j1, 'no_show', 'Nobody came') returning id into i1;
  perform tests.as_su();
  update public.issues set sla_due_at = now() - interval '50 days' where id = i1;
  perform tests.as_user(approver); perform public.enterprise_set_sla_targets(ent, 0.9, 0.9, 5); perform tests.as_su();

  select count(*) into n from public.enterprise_sla_snapshots where enterprise_org_id = ent; perform tests.eq(n, 0::bigint, 'nothing is frozen to begin with');

  -- Freezing a closed month by hand.
  perform tests.as_user(viewer);
  perform tests.throws(format('select public.enterprise_freeze_sla_month(%L, %L)', ent, m - 20), '%owner or approvers%', 'a viewer cannot freeze a month');
  perform tests.as_user(owner2);
  perform tests.throws(format('select public.enterprise_freeze_sla_month(%L, %L)', ent, m - 20), '%owner or approvers%', 'nor another Enterprise');
  perform tests.as_user(approver);
  perform tests.throws(format('select public.enterprise_freeze_sla_month(%L, %L)', ent, current_date), '%not over yet%', 'a month still in progress cannot be frozen');
  perform tests.throws(format('select public.enterprise_freeze_sla_month(%L, %L)', ent, m - 200), '%no visits%', 'nor one with no visits');
  perform public.enterprise_freeze_sla_month(ent, m - 20);
  select * into r from public.enterprise_sla_snapshots where enterprise_org_id = ent and month = date_trunc('month', m - 20)::date;
  perform tests.eq(r.source, 'manual', 'an approver freezes the month before'); perform tests.eq(r.taken_by, approver, 'and it says who');
  perform tests.throws(format('select public.enterprise_freeze_sla_month(%L, %L)', ent, m - 20), '%already frozen%', 'a month freezes once');

  -- The daily scan waits for the complaint window.
  perform tests.as_su();
  select (m + interval '1 month')::timestamp at time zone tz into m_end;
  k := private.freeze_sla_months(m_end + interval '1 hour');
  select count(*) into n from public.enterprise_sla_snapshots where enterprise_org_id = ent and month = m; perform tests.eq(n, 0::bigint, 'an hour after the month ends it is not frozen yet');
  k := private.freeze_sla_months(m_end + interval '47 hours');
  select count(*) into n from public.enterprise_sla_snapshots where enterprise_org_id = ent and month = m; perform tests.eq(n, 0::bigint, 'nor after 47 hours: the 48-hour complaint window is still open');

  -- What the live pack says just before the freeze.
  perform tests.as_user(buyer);
  select jsonb_agg(to_jsonb(p)) into live_before from public.enterprise_sla_pack(ent, m) p;
  perform tests.as_su();
  k := private.freeze_sla_months(m_end + interval '49 hours');
  perform tests.ok(k >= 1, 'once the window has passed the scan freezes the month');
  select * into r from public.enterprise_sla_snapshots where enterprise_org_id = ent and month = m;
  perform tests.eq(r.source, 'auto', 'taken by the scan'); perform tests.ok(r.taken_by is null, 'by nobody in particular');
  perform tests.eq(jsonb_array_length(r.pack), 2, 'the vendor and its one site'); perform tests.eq(jsonb_array_length(r.exceptions), 2, 'and the two visits behind the numbers');
  perform tests.eq(r.pack, live_before, 'the snapshot is exactly what the live pack said, in the same order');
  perform tests.eq((r.pack -> 0 ->> 'is_vendor_total')::boolean, true, 'the vendor''s own row first');
  perform tests.eq((r.pack -> 0 ->> 'on_time_target')::numeric, 0.9, 'with the service levels in force at the time');
  k := private.freeze_sla_months(m_end + interval '49 hours');
  select count(*) into n from public.enterprise_sla_snapshots where enterprise_org_id = ent; perform tests.eq(n, 2::bigint, 'a second scan adds nothing: this month and the month before only');
  select count(*) into n from public.enterprise_sla_snapshots where enterprise_org_id = ent and month = date_trunc('month', now())::date; perform tests.eq(n, 0::bigint, 'and the month in progress is never frozen');
  k := private.freeze_sla_months(now());
  select count(*) into n from public.enterprise_sla_snapshots where enterprise_org_id = ent and month = date_trunc('month', now())::date; perform tests.eq(n, 0::bigint, 'even when the scan runs now');

  -- After the freeze the live figures move and the snapshot does not.
  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description) values (j3, 'quality', 'Found later') returning id into i1;
  perform tests.as_user(approver);
  perform public.enterprise_set_sla_targets(ent, 0.5, 0.5, 50);
  select complaints into r from public.enterprise_sla_pack(ent, m) where is_vendor_total; perform tests.eq(r.complaints, 2, 'a complaint raised later shows in the live pack');
  select * into r from public.enterprise_sla_snapshot(ent, m + 11);
  perform tests.eq(r.month, m, 'the frozen month is found by any date in it'); perform tests.eq(r.source, 'auto', 'and says how it was taken');
  perform tests.eq((r.pack -> 0 ->> 'complaints')::integer, 1, 'but the frozen pack still says one complaint');
  perform tests.eq((r.pack -> 0 ->> 'on_time_target')::numeric, 0.9, 'and the old service level');
  perform tests.eq(jsonb_array_length(r.exceptions), 2, 'and the same two visits');
  select count(*) into n from public.enterprise_sla_snapshot(ent, (m + interval '1 month')::date); perform tests.eq(n, 0::bigint, 'a month that is not frozen has no snapshot');

  -- It can never change.
  perform tests.as_su();
  perform tests.throws(format('update public.enterprise_sla_snapshots set pack = ''[]'' where enterprise_org_id = %L and month = %L', ent, m), '%cannot be changed%', 'a frozen month cannot be altered, even by the database owner');
  perform tests.throws(format('delete from public.enterprise_sla_snapshots where enterprise_org_id = %L and month = %L', ent, m), '%cannot be changed%', 'or removed');
  perform tests.as_user(approver);
  update public.enterprise_sla_snapshots set pack = '[]' where enterprise_org_id = ent; get diagnostics n = row_count;
  perform tests.eq(n, 0::bigint, 'an Enterprise cannot write it either (no row is touched)');
  perform tests.throws(format('insert into public.enterprise_sla_snapshots (enterprise_org_id, month, source, pack, exceptions) values (%L, %L, ''manual'', ''[1]'', ''[]'')', ent, (m - 400)::date), '%row-level security%', 'nor add one of its own');
  perform tests.as_su();
  select count(*) into n from public.audit_log where table_name = 'enterprise_sla_snapshots'; perform tests.ok(n >= 2, 'freezing a month is on the record');

  -- Who may read it.
  perform tests.as_user(viewer);
  select count(*) into n from public.enterprise_sla_snapshot(ent, m); perform tests.eq(n, 1::bigint, 'an Enterprise viewer can read a frozen month');
  select count(*) into n from public.enterprise_sla_snapshots; perform tests.ok(n >= 2, 'and list them');
  perform tests.as_user(owner2);
  perform tests.throws(format('select * from public.enterprise_sla_snapshot(%L, %L)', ent, m), '%Not allowed%', 'another Enterprise cannot read it');
  select count(*) into n from public.enterprise_sla_snapshots where enterprise_org_id = ent; perform tests.eq(n, 0::bigint, 'nor see that it exists');
  perform tests.as_user(vendor_u);
  perform tests.throws(format('select * from public.enterprise_sla_snapshot(%L, %L)', ent, m), '%Not allowed%', 'a vendor cannot');
  perform tests.as_user(stranger);
  perform tests.throws(format('select * from public.enterprise_sla_snapshot(%L, %L)', ent, m), '%Not allowed%', 'nor a stranger');
  perform tests.as_anon();
  select count(*) into n from public.enterprise_sla_snapshots; perform tests.eq(n, 0::bigint, 'nor a signed-out visitor');
  perform tests.as_su();
end $$;
