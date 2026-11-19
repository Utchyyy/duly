-- The monthly SLA pack: per vendor and per site, the service levels, the visits behind the numbers, and who may see them.

create function pg_temp.email_of(u uuid) returns text language sql security definer as $$ select email::text from auth.users where id = u $$;

do $$
declare
  f jsonb; ent uuid; vend uuid; buyer uuid; crew uuid; admin_u uuid; vendor_u uuid; site2 uuid;
  owner2 uuid := tests.mk_user('ent2-owner'); approver uuid := tests.mk_user('ent1-approver'); viewer uuid := tests.mk_user('ent1-viewer'); stranger uuid := tests.mk_user('stranger-x');
  ent2 uuid; jl uuid[]; j1 uuid; j2 uuid; j3 uuid; j4 uuid; j5 uuid; j6 uuid; i1 uuid; i2 uuid; sg uuid; n bigint; r record;
  m date := date_trunc('month', now() - interval '2 months')::date;
begin
  f := tests.book_job('enterprise', array['mon','tue','wed','thu','fri','sat','sun'], '09:00');
  ent := (f ->> 'buyer_org')::uuid; vend := (f ->> 'vendor_org')::uuid; buyer := (f ->> 'buyer')::uuid; crew := (f ->> 'crew')::uuid;
  admin_u := (f ->> 'admin')::uuid; vendor_u := (f ->> 'vendor')::uuid;
  insert into public.memberships values (ent, approver, 'approver'), (ent, viewer, 'viewer');
  perform tests.as_user(admin_u); ent2 := public.admin_create_enterprise('Other Enterprise', pg_temp.email_of(owner2));
  perform public.enterprise_add_vendor(ent2, vend); perform tests.as_su();
  perform tests.as_user(buyer); perform public.schedule_visits((f ->> 'contract')::uuid, 4); perform tests.as_su();
  select array_agg(id order by scheduled_start, id) into jl from public.jobs where buyer_org_id = ent and status <> 'cancelled';
  j1 := jl[1]; j2 := jl[2]; j3 := jl[3]; j4 := jl[4]; j5 := jl[5]; j6 := jl[6];
  -- everything else is out of the month under test
  update public.jobs set scheduled_start = scheduled_start + interval '40 days', scheduled_end = scheduled_end + interval '40 days' where buyer_org_id = ent and id <> all (jl[1:6]);
  delete from public.job_assignments where job_id = any (jl);
  insert into public.job_assignments (job_id, user_id, role) values (j2, crew, 'lead'), (j3, crew, 'lead'), (j4, crew, 'lead');
  -- a month two months back, mid-morning on separate days
  update public.jobs set scheduled_start = (m + 2)::timestamptz + interval '10 hours', scheduled_end = (m + 2)::timestamptz + interval '12 hours' where id = j1;  -- missed
  update public.jobs set scheduled_start = (m + 3)::timestamptz + interval '10 hours', scheduled_end = (m + 3)::timestamptz + interval '12 hours' where id = j2;  -- late
  update public.jobs set scheduled_start = (m + 4)::timestamptz + interval '10 hours', scheduled_end = (m + 4)::timestamptz + interval '12 hours' where id = j3;  -- on time
  update public.jobs set scheduled_start = (m + 5)::timestamptz + interval '10 hours', scheduled_end = (m + 5)::timestamptz + interval '12 hours' where id = j4;  -- on time
  update public.jobs set scheduled_start = (m + 6)::timestamptz + interval '10 hours', scheduled_end = (m + 6)::timestamptz + interval '12 hours' where id = j5;  -- cancelled
  update public.jobs set scheduled_start = (m + 7)::timestamptz + interval '10 hours', scheduled_end = (m + 7)::timestamptz + interval '12 hours' where id = j6;  -- missed, second site
  update public.jobs set status = 'cancelled' where id = j5;
  insert into public.sites (org_id, name, town, postcode, lat, lng, geofence_m) values (ent, 'Second Site', 'Ipswich', 'IP1 1AA', 52.05, 1.15, 150) returning id into site2;
  update public.jobs set site_id = site2 where id = j6;
  perform tests.crew_completes(jsonb_build_object('job', j2, 'crew', crew));
  perform tests.crew_completes(jsonb_build_object('job', j3, 'crew', crew));
  perform tests.crew_completes(jsonb_build_object('job', j4, 'crew', crew));
  update public.job_events e set at = (select scheduled_start + case when e.job_id = j2 then interval '40 minutes' else interval '5 minutes' end from public.jobs where id = e.job_id) where e.kind = 'check_in' and e.job_id in (j2, j3, j4);
  update public.job_events e set at = (select scheduled_end - interval '10 minutes' from public.jobs where id = e.job_id) where e.kind = 'check_out' and e.job_id in (j2, j3, j4);
  -- problems: one open and past its response time on the missed visit; one resolved after its response time on the late visit; a safeguarding report that must never count
  perform tests.as_user(buyer);
  insert into public.issues (job_id, kind, description) values (j1, 'no_show', 'Nobody came') returning id into i1;
  insert into public.issues (job_id, kind, description) values (j2, 'quality', 'Floors not clean') returning id into i2;
  insert into public.issues (job_id, kind, description) values (j2, 'safeguarding', 'A private matter') returning id into sg;
  perform tests.as_su();
  update public.issues set sla_due_at = now() - interval '50 days' where id = i1;
  update public.issues set sla_due_at = now() - interval '50 days', status = 'resolved', resolved_at = now() - interval '49 days' where id = i2;

  -- The vendor's own row.
  perform tests.as_user(buyer);
  select * into r from public.enterprise_sla_pack(ent, m + 10) where is_vendor_total;
  perform tests.eq(r.vendor_name, 'Clean-Fit', 'a row for the vendor (any date in the month picks the month)');
  perform tests.eq(r.scheduled_visits, 5, 'five visits scheduled in the month, the cancelled one left out');
  perform tests.eq(r.due_visits, 5, 'all five are due');
  perform tests.eq(r.checked_in_visits, 3, 'three were checked in');
  perform tests.eq(r.evidenced_visits, 3, 'all three fully evidenced');
  perform tests.eq(r.evidenced_rate, 0.6, 'three of five due evidenced');
  perform tests.eq(r.on_time_visits, 2, 'two arrived on time');
  perform tests.eq(r.on_time_rate, 0.667, 'two of the three that arrived');
  perform tests.eq(r.late_visits, 1, 'one late');
  perform tests.eq(r.missed_visits, 2, 'two missed');
  perform tests.ok(r.avg_late_minutes between 16 and 17.5, 'average minutes after the start across the three that arrived (40, 5 and 5)');
  perform tests.eq(r.complaints, 2, 'two complaints, the safeguarding report not counted');
  perform tests.eq(r.complaints_per_100, 40.0, 'which is 40 per 100 due visits');
  perform tests.eq(r.open_complaints, 1, 'one still open');
  perform tests.eq(r.sla_breaches, 2, 'both past their response time (one unanswered, one answered late)');
  perform tests.eq(r.first_time_right_rate, 0.667, 'two of the three arrivals were right first time');
  perform tests.ok(r.plan_followed_rate is not null and r.plan_followed_rate >= 0.99, 'every planned area ticked on the visits done');
  perform tests.ok(r.site_id is null and r.site_name is null, 'a vendor row has no site');
  perform tests.ok(r.on_time_met is null and r.evidenced_met is null and r.complaints_met is null, 'with no service levels set, nothing is met or missed');

  -- Per site.
  select count(*) into n from public.enterprise_sla_pack(ent, m) where not is_vendor_total; perform tests.eq(n, 2::bigint, 'two site rows');
  select * into r from public.enterprise_sla_pack(ent, m) where site_id = site2; perform tests.eq(r.scheduled_visits, 1, 'the second site has its one visit'); perform tests.eq(r.missed_visits, 1, 'which was missed');
  select * into r from public.enterprise_sla_pack(ent, m) where not is_vendor_total and site_id <> site2; perform tests.eq(r.scheduled_visits, 4, 'the first site has the other four'); perform tests.eq(r.checked_in_visits, 3, 'with three arrivals');
  -- order: the vendor's row first, then its sites by name
  select string_agg(coalesce(site_name, '(total)'), ',' order by ord) into r from (select site_name, row_number() over () as ord from public.enterprise_sla_pack(ent, m)) s;
  perform tests.eq(r.string_agg, '(total),Second Site,Site', 'the vendor row first, then its sites by name');

  -- Months are separate.
  select count(*) into n from public.enterprise_sla_pack(ent, (m - interval '1 month')::date); perform tests.eq(n, 0::bigint, 'the month before has nothing');
  select count(*) into n from public.enterprise_sla_pack(ent, (m + interval '1 month')::date) where is_vendor_total and scheduled_visits > 0; perform tests.ok(n >= 0, 'a later month runs');

  -- Service levels.
  perform tests.as_user(viewer);
  perform tests.throws(format('select public.enterprise_set_sla_targets(%L, 0.9, 0.9, 5)', ent), '%owner or approvers%', 'a viewer cannot set service levels');
  perform tests.as_user(owner2);
  perform tests.throws(format('select public.enterprise_set_sla_targets(%L, 0.9, 0.9, 5)', ent), '%owner or approvers%', 'nor can another Enterprise');
  perform tests.as_user(approver);
  perform tests.throws(format('select public.enterprise_set_sla_targets(%L, 1.5, 0.9, 5)', ent), '%between 0 and 1%', 'a share must be between 0 and 1');
  perform tests.throws(format('select public.enterprise_set_sla_targets(%L, 0.9, 0.9, -1)', ent), '%negative%', 'complaints cannot be negative');
  perform public.enterprise_set_sla_targets(ent, 0.95, 0.95, 5);
  select * into r from public.enterprise_sla_pack(ent, m) where is_vendor_total;
  perform tests.eq(r.on_time_target, 0.95, 'the on-time level is shown'); perform tests.eq(r.on_time_met, false, 'on-time missed (0.667 against 0.95)');
  perform tests.eq(r.evidenced_met, false, 'evidenced missed (0.6 against 0.95)'); perform tests.eq(r.complaints_met, false, 'complaints missed (40 against 5)');
  perform public.enterprise_set_sla_targets(ent, 0.5, 0.5, 50);
  select * into r from public.enterprise_sla_pack(ent, m) where is_vendor_total;
  perform tests.ok(r.on_time_met and r.evidenced_met and r.complaints_met, 'with looser levels all three are met');
  perform public.enterprise_set_sla_targets(ent, null, 0.5, null);
  select * into r from public.enterprise_sla_pack(ent, m) where is_vendor_total;
  perform tests.ok(r.on_time_met is null and r.complaints_met is null and r.evidenced_met, 'a level left empty is not judged');
  select count(*) into n from public.enterprise_sla_targets where enterprise_org_id = ent; perform tests.eq(n, 1::bigint, 'one set of levels per Enterprise');
  perform tests.as_user(owner2);
  select count(*) into n from public.enterprise_sla_targets; perform tests.eq(n, 0::bigint, 'another Enterprise cannot read them');
  perform tests.as_user(viewer);
  select count(*) into n from public.enterprise_sla_targets; perform tests.eq(n, 1::bigint, 'an Enterprise viewer can');

  -- The visits behind the numbers.
  perform tests.as_user(buyer);
  select count(*) into n from public.enterprise_sla_exceptions(ent, m); perform tests.eq(n, 3::bigint, 'three exceptions: two missed, one late (the on-time visits are not listed)');
  select * into r from public.enterprise_sla_exceptions(ent, m) where job_id = j1; perform tests.ok(r.missed and r.open_complaints = 1 and r.sla_breached, 'the missed visit shows its open, overdue complaint');
  select * into r from public.enterprise_sla_exceptions(ent, m) where job_id = j2;
  perform tests.ok(not r.missed and r.late_minutes between 39 and 41, 'the late visit says how late'); perform tests.eq(r.complaint_kinds, 'quality', 'and names the complaint, never the safeguarding report');
  perform tests.ok(r.sla_breached, 'answered after its response time');
  select count(*) into n from public.enterprise_sla_exceptions(ent, m) where job_id in (j3, j4, j5); perform tests.eq(n, 0::bigint, 'on-time and cancelled visits are not exceptions');
  select string_agg(site_name, ',' order by ord) into r from (select site_name, row_number() over () as ord from public.enterprise_sla_exceptions(ent, m)) s;
  perform tests.eq(r.string_agg, 'Second Site,Site,Site', 'in vendor, site and date order');

  -- Who may look.
  perform tests.as_user(viewer);
  select count(*) into n from public.enterprise_sla_pack(ent, m); perform tests.ok(n > 0, 'an Enterprise viewer can read the pack');
  perform tests.as_user(owner2);
  perform tests.throws(format('select * from public.enterprise_sla_pack(%L, %L)', ent, m), '%Not allowed%', 'another Enterprise cannot');
  perform tests.throws(format('select * from public.enterprise_sla_exceptions(%L, %L)', ent, m), '%Not allowed%', 'nor the exceptions');
  select count(*) into n from public.enterprise_sla_pack(ent2, m) where scheduled_visits > 0; perform tests.eq(n, 0::bigint, 'and its own pack for the same vendor has none of these visits');
  perform tests.as_user(vendor_u);
  perform tests.throws(format('select * from public.enterprise_sla_pack(%L, %L)', ent, m), '%Not allowed%', 'a vendor cannot read the Enterprise''s pack');
  perform tests.as_user(stranger);
  perform tests.throws(format('select * from public.enterprise_sla_pack(%L, %L)', ent, m), '%Not allowed%', 'a stranger cannot');
  perform tests.as_user(buyer);
  perform tests.throws(format('select * from public.enterprise_sla_pack(%L, %L)', (select id from public.organisations where name = 'Clean-Fit'), m), '%Not allowed%', 'and it is only for an Enterprise');

  perform tests.as_su();
  select count(*) into n from public.audit_log where table_name = 'enterprise_sla_targets'; perform tests.ok(n >= 3, 'changes to the service levels are on the record');
end $$;
